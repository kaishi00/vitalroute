#!/usr/bin/env python3
"""VitalRoute reference receiving server.

A small, dependency-free HTTPS receiver for Apple Health records exported by
the VitalRoute iOS app. Contract: API.md. Storage: SQLite. Authentication:
single Bearer token from the environment (no default credentials).

Privacy rules baked into this file:
- Health records, tokens, and headers are never logged.
- Error responses never echo request contents or credentials.
- Acknowledgments are sent only after the batch has been committed.
- The server binds to 127.0.0.1 by default and never opens outbound
  connections.

Usage:
    VITALROUTE_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')" \
        python3 receiver.py [--host 127.0.0.1] [--port 8787] [--db /path/db.sqlite]

For real deployments terminate TLS in front of the receiver (see README.md) or
pass --tls-cert/--tls-key to serve HTTPS directly.
"""

import argparse
import hmac
import json
import logging
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import storage
import validation

logger = logging.getLogger("vitalroute.receiver")

_MIN_TOKEN_LENGTH = 16

_KNOWN_PATHS = ("/v1/records", "/v1/health")


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


class InvalidContentLength(Exception):
    """Content-Length was present but malformed (non-integer or negative)."""


class ReceiverConfig:
    def __init__(self, token, db_path, max_body_bytes, max_records_per_batch):
        self.token = token
        self.db_path = db_path
        self.max_body_bytes = max_body_bytes
        self.max_records_per_batch = max_records_per_batch


class ReceiverHandler(BaseHTTPRequestHandler):
    # Don't advertise the Python version.
    server_version = "VitalRouteReceiver/1.0"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    # Bound every socket read: a client that stalls mid-request cannot pin a
    # worker thread indefinitely (slowloris).
    timeout = _env_int("VITALROUTE_SOCKET_TIMEOUT", 30)

    # Configuration lives on the server instance (see make_server), so no
    # request handler ever holds mutable state.
    @property
    def receiver_config(self):
        return self.server.receiver_config

    @property
    def record_store(self):
        return self.server.record_store

    # ---- plumbing -------------------------------------------------------

    def _send_json(self, status, body, extra_headers=None, close=False):
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=UTF-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        if close:
            # Sending the header also flips close_connection, so the socket
            # is closed after this response.
            self.send_header("Connection", "close")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        # HEAD responses keep the declared framing but carry no body.
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _send_error_json(self, status, code, message, extra_headers=None, close=False):
        # Log the machine-readable code with the status line: codes are
        # contract identifiers, not sensitive data.
        logger.info(
            "%s %s -> %d error_code=%s",
            self.command,
            self.path.split("?", 1)[0],
            status,
            code,
        )
        self._send_json(
            status,
            {"error": {"code": code, "message": message}},
            extra_headers,
            close=close,
        )

    def _is_authorized(self):
        header = self.headers.get("Authorization")
        if header is None:
            return False
        parts = header.split(" ", 1)
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return False
        # Constant-time comparison; the token itself is never logged or echoed.
        return hmac.compare_digest(
            parts[1].strip().encode("utf-8"),
            self.receiver_config.token.encode("utf-8"),
        )

    def _reject_unauthorized(self):
        # The request body (if any) was never consumed; reusing this
        # connection could parse leftover body bytes as the next request.
        self._send_error_json(
            close=True,
            status=401,
            code="unauthorized",
            message="A valid bearer token is required.",
            extra_headers={"WWW-Authenticate": "Bearer"},
        )

    def _has_transfer_encoding(self):
        return "transfer-encoding" in {name.lower() for name in self.headers.keys()}

    def _reject_transfer_encoding(self):
        # Chunked (or any) transfer encoding is outside the contract; with a
        # framing we do not consume, the connection cannot be reused.
        self._send_error_json(
            close=True,
            status=400,
            code="invalid_transfer_encoding",
            message="Content-Length framed bodies are required.",
        )

    def _content_length(self):
        raw = self.headers.get("Content-Length")
        if raw is None:
            return None
        try:
            value = int(raw)
        except ValueError:
            raise InvalidContentLength(raw)
        if value < 0:
            raise InvalidContentLength(raw)
        return value

    def _reject_invalid_content_length(self):
        self._send_error_json(
            close=True,
            status=400,
            code="invalid_content_length",
            message="Content-Length must be a non-negative integer.",
        )

    def _reject_unknown_path(self):
        # A POST body on an unknown path is never drained; close so leftover
        # bytes cannot be parsed as a new request on this connection.
        self._send_error_json(close=True, status=404, code="not_found", message="Unknown path.")

    def _reject_method_not_allowed(self):
        if self.path in _KNOWN_PATHS:
            # The request body (if any) was not consumed.
            allow = "GET, POST" if self.path == "/v1/records" else "GET"
            self._send_error_json(
                close=True,
                status=405,
                code="method_not_allowed",
                message="Method not allowed for this operation.",
                extra_headers={"Allow": allow},
            )
        else:
            self._reject_unknown_path()

    # ---- request routing -------------------------------------------------

    def do_GET(self):
        if self.path in _KNOWN_PATHS:
            self._handle_connection_test()
        else:
            self._reject_unknown_path()

    def do_POST(self):
        if self.path == "/v1/records":
            self._handle_ingestion()
        elif self.path == "/v1/health":
            self._reject_method_not_allowed()
        else:
            self._reject_unknown_path()

    def do_PUT(self):
        self._reject_method_not_allowed()

    def do_DELETE(self):
        self._reject_method_not_allowed()

    def do_PATCH(self):
        self._reject_method_not_allowed()

    def do_HEAD(self):
        self._reject_method_not_allowed()

    def do_OPTIONS(self):
        self._reject_method_not_allowed()

    def do_TRACE(self):
        self._reject_method_not_allowed()

    def do_CONNECT(self):
        self._reject_method_not_allowed()

    # ---- operations -------------------------------------------------------

    def _handle_connection_test(self):
        if not self._is_authorized():
            self._reject_unauthorized()
            return
        if self._has_transfer_encoding():
            self._reject_transfer_encoding()
            return
        try:
            content_length = self._content_length()
        except InvalidContentLength:
            self._reject_invalid_content_length()
            return
        # A connection test must never carry a body: reject rather than
        # ignore, so a client bug cannot smuggle records into a test op.
        if content_length is None:
            body_length = 0
        else:
            body_length = content_length
        if body_length > 0:
            self._drain_body(body_length)
            self._send_error_json(
                status=400,
                code="connection_test_body_not_allowed",
                message="The connection test accepts no request body.",
                close=True,
            )
            return
        self._send_json(
            200,
            {
                "status": "ok",
                "service": validation.SERVICE_NAME,
                "apiVersion": validation.SUPPORTED_API_VERSION,
            },
        )
        self._log_request(200)

    def _handle_ingestion(self):
        if not self._is_authorized():
            self._reject_unauthorized()
            return
        if self._has_transfer_encoding():
            self._reject_transfer_encoding()
            return
        try:
            content_length = self._content_length()
        except InvalidContentLength:
            self._reject_invalid_content_length()
            return

        content_type = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            # The body was not read; the connection cannot be reused safely.
            self._send_error_json(
                close=True,
                status=400,
                code="invalid_content_type",
                message="Content-Type must be application/json.",
            )
            return

        if content_length is None:
            # The request body (if any) was sent with a framing we do not
            # consume, so the connection can no longer be reused safely.
            self._send_error_json(
                close=True,
                status=411,
                code="length_required",
                message="Content-Length is required.",
            )
            return

        config = self.receiver_config
        if content_length > config.max_body_bytes:
            self._send_error_json(
                close=True,
                status=413,
                code="payload_too_large",
                message="The request body exceeds the size limit.",
            )
            return

        body = self.rfile.read(content_length) if content_length > 0 else b""
        try:
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._send_error_json(400, "invalid_json", "The request body is not valid JSON.")
            return

        try:
            batch_created_at, prepared = validation.validate_payload(
                payload, config.max_records_per_batch
            )
        except validation.ValidationError as error:
            self._send_error_json(400, error.code, error.message)
            return

        try:
            accepted, duplicates = self.record_store.ingest(prepared, batch_created_at)
        except Exception:  # noqa: BLE001 - never leak internals to the client
            logger.exception("Ingestion failed with an internal error.")
            self._send_error_json(500, "internal_error", "Ingestion failed.")
            return

        self._send_json(
            200,
            {
                "status": "accepted",
                "accepted": accepted,
                "duplicates": duplicates,
                "schemaVersion": validation.SUPPORTED_SCHEMA_VERSION,
            },
        )
        self._log_request(200, records=accepted + duplicates)

    def _drain_body(self, length):
        remaining = min(length, self.receiver_config.max_body_bytes + 1)
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 64 * 1024))
            if not chunk:
                break
            remaining -= len(chunk)

    # ---- logging ----------------------------------------------------------

    def _log_request(self, status, records=None):
        # Minimal operational logging: method, path (never the query string),
        # status, counts. Never headers, tokens, or record data.
        suffix = " records=%d" % records if records is not None else ""
        try:
            content_length = self._content_length() or 0
        except InvalidContentLength:
            content_length = 0
        logger.info(
            "%s %s -> %d (%d bytes in%s)",
            self.command,
            self.path.split("?", 1)[0],
            status,
            content_length,
            suffix,
        )

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        # Suppress the base class's request-line logging entirely: it can
        # include query strings, which this server deliberately never logs.
        pass


class ReceiverServer(ThreadingHTTPServer):
    """Threading HTTP server with quiet handling of client-side resets."""

    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def handle_error(self, request, client_address):
        # Client disconnects, resets, and read timeouts are routine; log one
        # line, no traceback, and never any request content.
        logger.warning("Connection error with a client; request rejected.")


def make_server(
    host,
    port,
    db_path,
    token,
    max_body_bytes=validation.DEFAULT_MAX_BODY_BYTES,
    max_records_per_batch=validation.DEFAULT_MAX_RECORDS_PER_BATCH,
    tls_cert=None,
    tls_key=None,
):
    """Builds a ThreadingHTTPServer. Raises ValueError on unsafe config."""
    if not token or len(token) < _MIN_TOKEN_LENGTH:
        raise ValueError(
            "VITALROUTE_TOKEN must be set to a random token of at least %d characters "
            "(generate one with: python3 -c \"import secrets; print(secrets.token_urlsafe(32))\")"
            % _MIN_TOKEN_LENGTH
        )

    record_store = storage.RecordStore(db_path)

    server = ReceiverServer((host, port), ReceiverHandler)
    server.receiver_config = ReceiverConfig(
        token, db_path, max_body_bytes, max_records_per_batch
    )
    server.record_store = record_store

    if tls_cert or tls_key:
        if not (tls_cert and tls_key):
            server.server_close()
            raise ValueError("TLS requires both a certificate and a key file.")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(tls_cert, tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)

    return server



def _load_token(args):
    token = os.environ.get("VITALROUTE_TOKEN")
    token_file = os.environ.get("VITALROUTE_TOKEN_FILE") or args.token_file
    if token and token_file:
        raise SystemExit("Set either VITALROUTE_TOKEN or VITALROUTE_TOKEN_FILE, not both.")
    if token_file:
        with open(token_file, "r", encoding="utf-8") as handle:
            token = handle.read().strip()
    return token


def main(argv=None):
    parser = argparse.ArgumentParser(description="VitalRoute reference receiver")
    parser.add_argument("--host", default=os.environ.get("VITALROUTE_HOST", "127.0.0.1"))
    parser.add_argument(
        "--port", type=int, default=_env_int("VITALROUTE_PORT", 8787)
    )
    parser.add_argument(
        "--db", default=os.environ.get("VITALROUTE_DB", "vitalroute.sqlite3")
    )
    parser.add_argument("--token-file", default=None, help="File containing the bearer token")
    parser.add_argument("--tls-cert", default=os.environ.get("VITALROUTE_TLS_CERT"))
    parser.add_argument("--tls-key", default=os.environ.get("VITALROUTE_TLS_KEY"))
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    token = _load_token(args)
    try:
        server = make_server(
            args.host,
            args.port,
            args.db,
            token,
            max_body_bytes=_env_int("VITALROUTE_MAX_BODY_BYTES", validation.DEFAULT_MAX_BODY_BYTES),
            max_records_per_batch=_env_int(
                "VITALROUTE_MAX_RECORDS_PER_BATCH", validation.DEFAULT_MAX_RECORDS_PER_BATCH
            ),
            tls_cert=args.tls_cert,
            tls_key=args.tls_key,
        )
    except ValueError as error:
        raise SystemExit(str(error))

    scheme = "https" if (args.tls_cert and args.tls_key) else "http"
    logger.info(
        "Listening on %s://%s:%d (db: %s)", scheme, args.host, args.port, args.db
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
