#!/usr/bin/env python3
"""VitalRoute query server — read-only MCP over streamable HTTP.

Exposes the receiver's SQLite database to agent clients through the Model
Context Protocol with three fixed tools (list metrics, daily aggregates,
recent records). Deliberate properties:

- Read-only by construction: the database is opened with SQLite's mode=ro
  URI plus PRAGMA query_only (see queries.py); this process cannot write
  health data even though the data volume is mounted read-write at the
  container level — SQLite may need to create the -wal/-shm sidecars the
  receiver removes between write batches.
- Tombstone-aware: every answer excludes ids deleted on the phone.
- No arbitrary SQL: only the bounded queries in queries.py.
- Single Bearer token from a file (VITALROUTE_QUERY_TOKEN_FILE), compared
  in constant time; never logged, never echoed. Separate from the ingest
  token so agent access can be revoked independently.
- Privacy logging identical to the receiver: method and status only —
  never tokens, headers, client-controlled strings, or record contents.

Transport: MCP streamable HTTP (JSON-RPC POST bodies, plain JSON
responses; no server-initiated messages, so no SSE stream is opened and
batch arrays are rejected — batching was removed in protocol 2025-06-18).
GET /healthz answers 200 without auth for liveness probes; every other
GET is 405 per the transport spec.

Usage:
    VITALROUTE_QUERY_TOKEN_FILE=/path/token python3 mcp_server.py \
        [--host 127.0.0.1] [--port 8787] [--db /data/records.sqlite3]
"""

import argparse
import hmac
import json
import logging
import os
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import queries

logger = logging.getLogger("vitalroute.query")

_MIN_TOKEN_LENGTH = 16
_PROTOCOL_VERSION = "2025-06-18"
_SUPPORTED_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
_SERVER_INFO = {"name": "vitalroute-query", "version": "1.0.0"}
_MAX_BODY_BYTES = 1 << 20  # JSON-RPC envelopes are tiny; 1 MiB is generous
_KNOWN_METHODS = ("initialize", "notifications/initialized", "ping",
                  "tools/list", "tools/call")


def _env_int(name, default):
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit("%s must be an integer." % name)
    if value <= 0:
        raise SystemExit("%s must be positive." % name)
    return value


class QueryState:
    """Per-process state: one read-only connection guarded by a lock.

    The lock serializes queries across worker threads: a single Python
    sqlite3 connection object must not be used concurrently, whatever the
    underlying SQLite threading mode.
    """

    connection = None
    lock = threading.Lock()


TOOLS = [
    {
        "name": "list_metrics",
        "description": "List the health metrics available in this VitalRoute receiver, "
        "with record counts, date coverage, and aggregation semantics. "
        "Start here before asking for daily stats.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "daily_stats",
        "description": "Per-day aggregates (count, sum, avg, min, max) per metric. "
        "Cumulative metrics (steps, activeEnergy, sleep) are read via 'sum'; "
        "instantaneous metrics (heartRate and friends) via 'avg'/'min'/'max'. "
        "Dates group by UTC day. Deleted samples are excluded. "
        "Pass either 'days' (recent window with data) or 'from'/'to' (ISO dates).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "metric": {"type": "string", "description": "Single metric (e.g. steps); omit for all"},
                "from": {"type": "string", "description": "ISO date YYYY-MM-DD inclusive"},
                "to": {"type": "string", "description": "ISO date YYYY-MM-DD inclusive"},
                "days": {"type": "integer", "description": "The last N days with data (1-366)"},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "recent_records",
        "description": "Most recent raw records (newest first), optionally filtered by metric. "
        "Bounded to 200 per call; use daily_stats for aggregates.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "metric": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 20},
                "offset": {"type": "integer", "minimum": 0, "default": 0},
            },
            "additionalProperties": False,
        },
    },
]


def _tool_result(name, arguments):
    with QueryState.lock:
        if name == "list_metrics":
            payload = queries.list_metrics(QueryState.connection)
        elif name == "daily_stats":
            payload = queries.daily_stats(
                QueryState.connection,
                metric=arguments.get("metric"),
                from_date=arguments.get("from"),
                to_date=arguments.get("to"),
                days=arguments.get("days"),
            )
        elif name == "recent_records":
            payload = queries.recent_records(
                QueryState.connection,
                metric=arguments.get("metric"),
                limit=arguments.get("limit", 20),
                offset=arguments.get("offset", 0),
            )
        else:
            return {"code": -32601, "message": f"Unknown tool: {name}"}, True
    return {
        "content": [{"type": "text", "text": json.dumps(payload, separators=(",", ":"))}],
    }, False


def handle_jsonrpc(message):
    """Returns the response dict, or None for a notification (202, no body).

    Never raises for malformed input; unexpected failures are converted
    into JSON-RPC internal errors so a client always gets an answer.
    """
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return {"jsonrpc": "2.0", "id": None,
                "error": {"code": -32600, "message": "Invalid Request: not a JSON-RPC 2.0 message."}}
    method = message.get("method")
    msg_id = message.get("id")
    # A notification is a request WITHOUT an "id" member; an explicit
    # id: null is still a request and must be answered.
    is_notification = "id" not in message
    params = message.get("params")
    if params is None:
        params = {}
    if not isinstance(method, str):
        return {"id": msg_id, "jsonrpc": "2.0",
                "error": {"code": -32602, "message": "Invalid params: method must be a string."}}
    if not isinstance(params, dict):
        return {"id": msg_id, "jsonrpc": "2.0",
                "error": {"code": -32602, "message": "Invalid params: params must be an object."}}

    # Notifications never receive a response — not even errors.
    if is_notification and method != "initialize":
        return None

    if method == "initialize":
        requested = params.get("protocolVersion")
        version = requested if requested in _SUPPORTED_VERSIONS else _PROTOCOL_VERSION
        result = {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": _SERVER_INFO,
        }
        return {"id": msg_id, "jsonrpc": "2.0", "result": result}

    if method == "ping":
        return {"id": msg_id, "jsonrpc": "2.0", "result": {}}

    if method == "tools/list":
        return {"id": msg_id, "jsonrpc": "2.0", "result": {"tools": TOOLS}}

    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if not isinstance(name, str) or not isinstance(arguments, dict):
            return {"id": msg_id, "jsonrpc": "2.0",
                    "error": {"code": -32602, "message": "Invalid params for tools/call."}}
        try:
            result, is_app_error = _tool_result(name, arguments)
        except queries.QueryError as error:
            # Bad arguments: report inside the tool result so the agent can
            # correct the call, per MCP conventions.
            return {"id": msg_id, "jsonrpc": "2.0", "result": {
                "content": [{"type": "text", "text": f"Invalid query: {error}"}],
                "isError": True,
            }}
        except Exception:  # noqa: BLE001 - never leak internals or drop the connection
            logger.exception("tools/call failed")
            return {"id": msg_id, "jsonrpc": "2.0", "result": {
                "content": [{"type": "text", "text": "Query failed."}], "isError": True,
            }}
        if is_app_error:
            return {"id": msg_id, "jsonrpc": "2.0", "result": {
                "content": [{"type": "text", "text": result["message"]}], "isError": True,
            }}
        return {"id": msg_id, "jsonrpc": "2.0", "result": result}

    return {"id": msg_id, "jsonrpc": "2.0",
            "error": {"code": -32601, "message": f"Method not found: {method}"}}


class QueryHandler(BaseHTTPRequestHandler):
    server_version = "VitalRouteQuery/1.0"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = _env_int("VITALROUTE_SOCKET_TIMEOUT", 30)

    def _send_json(self, status, body, extra_headers=None, close=False):
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        if close:
            # Sending the header also flips close_connection, so the socket
            # is closed after this response.
            self.send_header("Connection", "close")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _send_error_json(self, status, code, message, close=False):
        self._send_json(status, {"error": {"code": code, "message": message}}, close=close)

    def _is_authorized(self):
        header = self.headers.get("Authorization")
        if header is None:
            return False
        parts = header.split(" ", 1)
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return False
        return hmac.compare_digest(
            parts[1].strip().encode("utf-8"),
            self.server.query_token.encode("utf-8"),
        )

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._send_json(200, {"status": "ok"})
            return
        # The streamable-HTTP transport opens server-initiated streams with
        # GET; this server sends none, so the spec answer is 405.
        self._send_error_json(405, "method_not_allowed", "POST JSON-RPC messages only.")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ("/", "/mcp"):
            # The body (if any) is not drained; close so leftover bytes
            # cannot be parsed as a new request on this connection.
            self._send_error_json(404, "not_found", "Unknown path.", close=True)
            return
        if not self._is_authorized():
            # The body was never consumed; the connection cannot be reused.
            self._send_json(
                401,
                {"error": {"code": "unauthorized", "message": "A valid bearer token is required."}},
                extra_headers={"WWW-Authenticate": "Bearer"},
                close=True,
            )
            return
        if "transfer-encoding" in {name.lower() for name in self.headers.keys()}:
            self._send_error_json(400, "invalid_transfer_encoding",
                                  "Content-Length framed bodies are required.", close=True)
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length < 0:
                raise ValueError("negative")
        except ValueError:
            self._send_error_json(400, "invalid_content_length",
                                  "Content-Length must be a non-negative integer.", close=True)
            return
        if length > _MAX_BODY_BYTES:
            self._send_error_json(413, "payload_too_large", "The request body exceeds the size limit.",
                                  close=True)
            return
        body = self.rfile.read(length) if length > 0 else b""
        try:
            message = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._send_json(400, {"jsonrpc": "2.0", "id": None,
                                  "error": {"code": -32700, "message": "Parse error."}})
            return
        if isinstance(message, list):
            self._send_json(400, {"jsonrpc": "2.0", "id": None,
                                  "error": {"code": -32600,
                                            "message": "Batch requests are not supported."}})
            return
        response = handle_jsonrpc(message)
        if response is None:
            # Notification: accepted, no body.
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send_json(200, response)
        # The body may be any JSON value; only dicts have a method.
        method = message.get("method") if isinstance(message, dict) else None
        logger.info("POST -> 200 method=%s",
                    method if method in _KNOWN_METHODS else "other")

    def do_PUT(self):
        self._send_error_json(405, "method_not_allowed", "Not allowed.", close=True)

    do_DELETE = do_PUT
    do_PATCH = do_PUT
    do_HEAD = do_PUT
    do_OPTIONS = do_PUT
    do_TRACE = do_PUT
    do_CONNECT = do_PUT

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        # Never log the request line: query strings have no place in logs.
        pass


class QueryServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def handle_error(self, request, client_address):
        logger.warning("Client connection ended early; response not delivered.")


def make_server(host, port, db_path, token):
    if not token or len(token) < _MIN_TOKEN_LENGTH:
        raise ValueError(
            "VITALROUTE_QUERY_TOKEN (or the file named by VITALROUTE_QUERY_TOKEN_FILE) "
            f"must hold a random token of at least {_MIN_TOKEN_LENGTH} characters."
        )
    try:
        QueryState.connection = queries.connect(db_path)
        QueryState.connection.execute("SELECT COUNT(*) FROM records").fetchone()
    except sqlite3.Error as error:
        raise ValueError(
            "The receiver database at %s is not readable yet (%s). "
            "Is the receiver running and has it started at least once?" % (db_path, error.__class__.__name__)
        )
    server = QueryServer((host, port), QueryHandler)
    server.query_token = token
    return server


def _load_token(args):
    token = os.environ.get("VITALROUTE_QUERY_TOKEN")
    token_file = os.environ.get("VITALROUTE_QUERY_TOKEN_FILE") or args.token_file
    if token and token_file:
        raise SystemExit("Set either VITALROUTE_QUERY_TOKEN or VITALROUTE_QUERY_TOKEN_FILE, not both.")
    if token_file:
        try:
            with open(token_file, "r", encoding="utf-8") as handle:
                token = handle.read().strip()
        except OSError as error:
            raise SystemExit(
                "Cannot read the query token file %s (%s). "
                "Was the secret mounted?" % (token_file, error.__class__.__name__)
            )
    return token


def main(argv=None):
    parser = argparse.ArgumentParser(description="VitalRoute read-only MCP query server")
    parser.add_argument("--host", default=os.environ.get("VITALROUTE_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=_env_int("VITALROUTE_PORT", 8787))
    parser.add_argument("--db", default=os.environ.get("VITALROUTE_DB", "/data/records.sqlite3"))
    parser.add_argument("--token-file", default=None)
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    token = _load_token(args)
    try:
        server = make_server(args.host, args.port, args.db, token)
    except ValueError as error:
        raise SystemExit(str(error))

    logger.info("Query server listening on http://%s:%d (db: %s, read-only)",
                args.host, args.port, args.db)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
