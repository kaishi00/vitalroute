# VitalRoute Agent Guide — connecting to and querying health stats

This document is for **AI agents (and their operators)** that want to query
the health data a VitalRoute iOS app syncs to a self-hosted receiver. Hand
this file (or the "system prompt" block at the bottom) to any agent that
should be able to answer questions about the owner's stats.

## What exists

- A **receiver** (write-only) at `https://<host>/v1/records` — the iPhone
  app uploads there. Agents do not use it.
- A **read-only MCP query service** at `https://<host>/mcp` — this is the
  agent surface. It speaks the Model Context Protocol over streamable
  HTTP (JSON-RPC POST), authenticates with a single Bearer token, and
  answers from the receiver's SQLite database.

In this deployment the host is a tailscale machine, so the URL looks like
`https://<machine>.<tailnet>.ts.net/mcp` and is reachable only from the
owner's tailnet. Everything below assumes the operator gives you that URL
and a token.

## Connecting

The query token is **not** in this repository. The operator provides it —
on the reference deployment it lives at `/srv/vitalroute/query-token` on
the receiver host (mode 0400, so: `sudo cat /srv/vitalroute/query-token`).
Treat it like a password: never echo it, never commit it, never put it in
a URL.

Most MCP clients accept a remote HTTP server with custom headers, e.g.
(ZCode / Claude-style config):

```json
{
  "mcpServers": {
    "vitalroute": {
      "type": "http",
      "url": "https://<machine>.<tailnet>.ts.net/mcp",
      "headers": { "Authorization": "Bearer <query token>" }
    }
  }
}
```

Claude Desktop (stdio-only) can bridge it via `mcp-remote`:

```json
{
  "mcpServers": {
    "vitalroute": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://<machine>.<tailnet>.ts.net/mcp",
               "--header", "Authorization: Bearer <query token>"]
    }
  }
}
```

After connecting you should see the server `vitalroute-query` with three
tools. If a request returns **401**, the token is wrong or rotated — ask
the operator, do not retry blindly.

## The tools

| Tool | What it returns | Notes |
|---|---|---|
| `list_metrics` | Every metric present with its record kind, record counts, earliest/latest coverage, and the unit quantity rows were stored in | Call this first; it tells you which metrics exist and how to read them |
| `daily_stats` | Per-UTC-day aggregates per metric AND kind (`count` always; `sum`/`avg`/`min`/`max` for quantity rows only) | Requires a window: `days` (recent days with data) or `from`/`to` (ISO dates). Range ≤ 366 days. Numeric aggregates are meaningful only for `quantity` rows (scalar samples); other kinds (workouts, sleep stages, ECGs, series, clinical documents) are counted, never averaged |
| `recent_records` | Raw record envelopes with their typed `data` payload, newest first, ≤ 200 per call | Use for detail on a specific day or sample; use `daily_stats` for anything aggregate. Paginate with `offset` (e.g. `{"metric":"steps","limit":200,"offset":200}` for the next page) |

Semantics worth knowing:

- **Deleted samples never appear.** If the owner deletes a sample on the
  phone, every tool excludes it — a stat never resurrects deleted data.
- **The service is read-only by construction.** There is no tool that
  writes, deletes, or modifies anything, and no arbitrary-SQL tool exists.
- Days group by **UTC date**; watch/app timezones can shift a day boundary
  for late-evening samples.
- **There is no metric catalog here.** Metric identifiers are owned by the
  phone's app; new ones can appear without a receiver update. Read a
  metric's structure from its `kind` and `data` payload (`quantity` rows
  carry `value` + `unit`; other kinds carry their own fields).

Example calls:

```json
{"name": "list_metrics", "arguments": {}}
{"name": "daily_stats", "arguments": {"metric": "steps", "days": 7}}
{"name": "daily_stats", "arguments": {"metric": "heartRate", "from": "2026-09-01", "to": "2026-09-07"}}
{"name": "recent_records", "arguments": {"metric": "restingHeartRate", "limit": 5}}
```

Good questions to answer with these: daily/weekly step totals, average and
range of heart rate over a period, resting-heart-rate trend, HRV averages,
sleep totals, active-energy sums, weekday-vs-weekend comparisons.

## System-prompt block (copy-paste for any agent)

```text
You have access to the "vitalroute" MCP server (read-only) with tools
list_metrics, daily_stats, and recent_records, which query the owner's
Apple Health data synced from their iPhone.

Rules:
- Start with list_metrics to see what data exists and its coverage before
  answering questions about specific metrics.
- daily_stats needs a window: use "days" for recent history or explicit
  "from"/"to" ISO dates. Numeric aggregates apply only to rows whose kind
  is "quantity" (respect the reported unit); for other kinds use "count".
  Prefer recent_records to inspect any non-quantity payload.
- Days are UTC. Deleted samples are excluded everywhere — never present
  data that includes them as if it were complete for a period before you
  checked coverage (earliest/latest from list_metrics).
- The service is read-only: there is nothing you can do that modifies the
  owner's data. Do not attempt to find one.
- Health data is sensitive: present it factually to the owner, and do not
  send it to third-party services.
```

## Operator notes

- Rotate the query token: same ownership rules as the receiver token, then
  recreate the mcp service (`docker compose ... up -d --force-recreate mcp`)
  and update each agent's config. See DEPLOYMENT.md.
- Disable agent access without touching the app: stop the `mcp` service
  and/or remove the serve mount. See DEPLOYMENT.md.
- There is deliberately no per-user access, no write path, and no raw SQL.
