# MCP Development Guide (Server & Client)

> By: Ventz Petkov <ventz@vpetkov.net>
> Last updated: 2026-07-31


## Purpose

Single source of truth for building MCP (Model Context Protocol) **servers** and **clients** in Python. Covers:

- **Protocol spec**: `2026-07-28` (latest finalized version)
- **Official Python SDK (`mcp`) v2** — the reference implementation, natively `2026-07-28` (stable `2.0.0`)
- **PrefectHQ FastMCP** — the batteries-included framework (stable `3.4.5`, beta `4.0.0b1`)
- Transport, MRTR, subscriptions, auth, extensions, deployment, security, and testing

> **Read this first.** `2026-07-28` is a **hard break**, not an increment. Sessions, the
> `initialize` handshake, `ping`, the HTTP `GET` stream, SSE resumability, and *all*
> server-initiated requests are gone. Roots, Sampling, and MCP-level Logging are deprecated.
> If you are maintaining a server written against `2025-11-25`, read [§2](#2-protocol-overview)
> and [Appendix A](#appendix-a--legacy-2025-11-25-era) before changing a line.

---

## Table of Contents

1. [Library Landscape](#1-library-landscape)
2. [Protocol Overview](#2-protocol-overview)
3. [Request Lifecycle & `server/discover`](#3-request-lifecycle--serverdiscover)
4. [Transport: Streamable HTTP](#4-transport-streamable-http)
5. [Transport: Stdio](#5-transport-stdio)
6. [Subscriptions & Notifications](#6-subscriptions--notifications)
7. [Multi Round-Trip Requests (MRTR)](#7-multi-round-trip-requests-mrtr)
8. [JSON-RPC Message Format & Error Codes](#8-json-rpc-message-format--error-codes)
9. [Caching (`ttlMs` / `cacheScope`)](#9-caching-ttlms--cachescope)
10. [Official SDK v2 Server (`MCPServer`)](#10-official-sdk-v2-server-mcpserver)
11. [Official SDK v2 Client](#11-official-sdk-v2-client)
12. [Low-Level Server API](#12-low-level-server-api)
13. [PrefectHQ FastMCP](#13-prefecthq-fastmcp)
14. [Server Template (Raw FastAPI)](#14-server-template-raw-fastapi)
15. [Extensions](#15-extensions)
16. [Authentication & Authorization](#16-authentication--authorization)
17. [Middleware](#17-middleware)
18. [Server Composition](#18-server-composition)
19. [HTTP Client Best Practices](#19-http-client-best-practices)
20. [Error Handling](#20-error-handling)
21. [Security](#21-security)
22. [Deployment](#22-deployment)
23. [Testing](#23-testing)
24. [CLI Tools & Inspector](#24-cli-tools--inspector)
25. [Checklist](#25-checklist)
26. [Appendix A — Legacy (2025-11-25 era)](#appendix-a--legacy-2025-11-25-era)
27. [Appendix B — Deprecated Features Registry](#appendix-b--deprecated-features-registry)
28. [Reference Links](#28-reference-links)

---

## 1. Library Landscape

Two Python implementations. **The recommendation flipped in 2026** — the official SDK's v2 rebuild
closed most of the gap that used to make FastMCP the obvious choice.

| | **Official Python SDK (`mcp`) v2** | **PrefectHQ FastMCP** |
|---|---|---|
| PyPI package | `mcp` (CLI extras: `mcp[cli]`), types in `mcp-types` | `fastmcp` |
| Latest | **`2.0.0` stable** | `3.4.5` stable / `4.0.0b1` beta |
| Protocol | `2026-07-28` native, serves legacy clients on the same app | 3.x = handshake era only; **4.0 beta** = `2026-07-28` |
| High-level class | `from mcp.server import MCPServer` | `from fastmcp import FastMCP` |
| Maintained by | Anthropic + MCP working group | Jeremiah Lowin / Prefect |
| Auth | OAuth 2.1 resource-server primitives (`TokenVerifier`, `AuthSettings`, RFC 9728 metadata) | 15+ pre-built IdP providers (Google, GitHub, Azure, Auth0, Keycloak, WorkOS, …), `OAuthProxy`, `OIDCProxy`, `MultiAuth` |
| Middleware | Yes — `async (ctx, call_next)`, marked **provisional** | Yes — full hook surface, stable |
| Composition | Not provided | `mount()`, `create_proxy()`, `from_openapi()`, `from_fastapi()` |
| Dependency injection | `Resolve()`, `Context`, `Elicit`/`Sample`/`ListRoots` | Full DI (`Depends`, `CurrentContext`, `TokenClaim`, …) |
| OpenTelemetry | Built in as a default middleware | Built in (zero-config) |
| Extensions | Tasks, MCP Apps | Native extension API, tasks extension |
| Python | ≥ 3.10 | ≥ 3.10 |

> **The `FastMCP` → `MCPServer` rename is real.** Earlier editions of this guide said it hadn't
> happened. It has: SDK v2 renamed the high-level class to `MCPServer` and moved it to
> `mcp.server`. `mcp.server.fastmcp.FastMCP` is v1-era. See [§10](#10-official-sdk-v2-server-mcpserver).

**Recommendation:**
- **Default / new work** → official **`mcp` v2** (`uv add 'mcp[cli]'`). Stable, native to the new
  protocol, dual-era serving for free, no non-Anthropic dependencies.
- **You need pre-built IdP providers, server composition/proxying, or OpenAPI→MCP** → **FastMCP**.
  Take `4.0.0b1` if you need `2026-07-28`; `3.4.5` is stable but handshake-era only.
- **Raw FastAPI** → only when neither library accommodates a custom wire/middleware requirement.
  [§14](#14-server-template-raw-fastapi) has a compliant stateless template.

### Install

```bash
# Official SDK v2 (recommended)
uv add 'mcp[cli]'                 # 2.0.0 — pulls mcp-types==2.0.0, httpx2, opentelemetry-api
uv add 'mcp>=1.28,<2'             # pin to the v1 maintenance line instead

# PrefectHQ FastMCP
uv add fastmcp                    # 3.4.5 stable (handshake era)
uv add 'fastmcp==4.0.0b1'         # 4.0 beta (2026-07-28)

# Verify
uv run mcp version
fastmcp version
```

> **Dependency footgun:** SDK v2 replaced `httpx`/`httpx-sse` with **`httpx2`**. If you pass your own
> client to a transport it must be an `httpx2.AsyncClient`. TLS certificate validation differs
> subtly between the two — re-test any custom CA / mTLS setup after upgrading.

---

## 2. Protocol Overview

MCP uses **JSON-RPC 2.0** over HTTP or stdio. All messages MUST be UTF-8.

**Protocol version**: `2026-07-28` (current finalized)
**Prior versions**: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`

**Architecture (Client-Host-Server):**
- **Hosts** are LLM applications (Claude Desktop, IDEs, LibreChat) that own client connections.
- **Clients** are connectors inside a host — one per server.
- **Servers** expose capabilities to clients.

**Server primitives**: Tools, Resources, Prompts.
**Client primitives**: Elicitation (Sampling and Roots are *deprecated*).
**Utilities**: Progress, Cancellation, Completion, Caching, Pagination, Logging *(deprecated)*.
**Extensions** (opt-in, negotiated): Tasks, MCP Apps, Skills over MCP.

### 2.1 MCP is now a stateless protocol

This is the change everything else follows from. From the spec:

> "The Model Context Protocol (MCP) is a **stateless protocol**: all the information needed to
> process a request is contained in the request itself. A server processes each request
> independently; no state should be inferred from previous requests, even those on the same
> connection or stream."

Concretely:

- Servers **MUST NOT** rely on prior requests over the same connection to establish context.
  Every request carries its own version, capabilities, and identity in `_meta`.
- Servers **SHOULD NOT** require a client to reuse the same connection for related operations.
- State spanning requests **MUST** be referenced by an explicit identifier the client passes on
  each request — a server-minted handle passed as an ordinary tool argument.
- An open stdio process is **not** a session or a conversation. Clients may interleave unrelated
  requests on one transport.

Long-lived requests like `subscriptions/listen` are still request/response — the response just
happens to be an open stream. Their state is scoped to the *request*, not the connection.

### 2.2 What changed in 2026-07-28 (vs 2025-11-25)

**Removed**

| Gone | Replacement |
|---|---|
| Protocol sessions + `Mcp-Session-Id` (SEP-2567) | Server-minted handles passed as tool arguments |
| `initialize` / `notifications/initialized` (SEP-2575) | Per-request `_meta` (§2.3) + `server/discover` |
| HTTP `GET` stream, `resources/subscribe`, `resources/unsubscribe` | `subscriptions/listen` ([§6](#6-subscriptions--notifications)) |
| `ping` | Nothing. It's gone, not deprecated. |
| `logging/setLevel` | `io.modelcontextprotocol/logLevel` in per-request `_meta` |
| `notifications/roots/list_changed` | — (Roots deprecated) |
| Server-initiated requests (`sampling/createMessage`, `elicitation/create`, `roots/list`) | **MRTR** ([§7](#7-multi-round-trip-requests-mrtr)) |
| SSE resumability (`Last-Event-ID`, event IDs) | None. Re-issue as a **new request with a new id**. |
| `notifications/elicitation/complete`, `elicitationId` | MRTR retry + server-encoded `requestState` |
| Experimental Tasks in core | `io.modelcontextprotocol/tasks` extension ([§15](#15-extensions)) |
| Client→server progress notifications | Progress is server→client only |

**Added / changed**

- **`server/discover`** — servers **MUST** implement it (§3.2).
- **`resultType`** on every result: `"complete"` or `"input_required"` (§8). Absent ⇒ treat as
  `"complete"` (older servers).
- **Required HTTP headers** `Mcp-Method` and `Mcp-Name`, validated against the body (§4.3).
- **`x-mcp-header`** — mirror tool params into `Mcp-Param-*` headers for gateway routing (§4.4).
- **`ttlMs` + `cacheScope`** are **required** on cacheable results (§9).
- `tools/list` **SHOULD** be returned in a deterministic order (client caching / prompt-cache hits).
- **Error-code allocation policy**; resource-not-found moved `-32002` → `-32602` (§8.2).
- `extensions` field on `ClientCapabilities` / `ServerCapabilities` (§15).
- OpenTelemetry `_meta` keys: `traceparent`, `tracestate`, `baggage` (SEP-414).
- `inputSchema`/`outputSchema` accept any JSON Schema 2020-12 keywords; `structuredContent` accepts
  any JSON value. `$ref` MUST NOT be auto-dereferenced over the network (§2.5).
- Auth: **CIMD preferred over DCR** (now deprecated), RFC 9207 `iss` validation, DCR
  `application_type`, credentials bound to their issuing AS (§16).

**Deprecated** (still functional; 12-month minimum window — see [Appendix B](#appendix-b--deprecated-features-registry))
Roots, Sampling, MCP-level Logging (SEP-2577); HTTP+SSE transport; `includeContext`
`"thisServer"`/`"allServers"`; OAuth Dynamic Client Registration.

**Feature landing version (cheatsheet):**

| Feature | First in |
|---|---|
| Form elicitation, structured tool output, resource links, tool annotations | `2025-06-18` |
| Streamable HTTP transport, OAuth 2.1 authorization | `2025-03-26` |
| URL elicitation, icons, sampling-with-tools, incremental scope | `2025-11-25` |
| Statelessness, `server/discover`, MRTR, `subscriptions/listen`, `resultType`, cache hints, `Mcp-Method`/`Mcp-Name` | `2026-07-28` |

For most API wrappers you still only need **Tools**.

### 2.3 The `_meta` envelope

Every client request carries protocol metadata in `params._meta`:

| Key | Type | Required | Description |
|---|---|---|---|
| `io.modelcontextprotocol/protocolVersion` | `string` | **Yes** | e.g. `"2026-07-28"` |
| `io.modelcontextprotocol/clientCapabilities` | `ClientCapabilities` | **Yes** | Capabilities relevant to this request |
| `io.modelcontextprotocol/clientInfo` | `Implementation` | No (SHOULD) | Client name/version |
| `io.modelcontextprotocol/logLevel` | `LoggingLevel` | No | Minimum log level for this request |
| `progressToken` | — | No | Opts into progress notifications |
| `traceparent` / `tracestate` / `baggage` | — | No | W3C trace context (OTel) |

Servers **SHOULD** stamp `io.modelcontextprotocol/serverInfo` into every result's `_meta`.
Notifications on a `subscriptions/listen` stream **MUST** carry
`io.modelcontextprotocol/subscriptionId`.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "get_weather",
    "arguments": {"location": "Seattle, WA"},
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {"name": "ExampleClient", "version": "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

**Enforcement:**
- Missing a required `_meta` field → `-32602`, HTTP `400`.
- Server needs a capability the client didn't declare → **`-32021`
  `MissingRequiredClientCapabilityError`** with `data.requiredCapabilities`, HTTP `400`.
- Unsupported `protocolVersion` → **`-32022` `UnsupportedProtocolVersionError`** with
  `data.supported[]`, HTTP `400`.

> `clientInfo` / `serverInfo` are **self-reported and unverified**. Display, log, and debug with
> them. Never branch behavior or make a security decision on them.

**`_meta` key naming:** optional dotted reverse-DNS prefix + `/` + name. Any prefix whose *second*
label is `modelcontextprotocol` or `mcp` is reserved (`io.modelcontextprotocol/`, `dev.mcp/`,
`com.mcp.tools/`). `com.example.mcp/` is **not** reserved — the second label is `example`.

### 2.4 Icons

`icons` is an array of `Icon` objects attachable to `Implementation`, `Tool`, `Prompt`, and
`Resource`: `src` (required — HTTPS or `data:` URI), `mimeType`, `sizes` (e.g. `["48x48"]`,
`["any"]`), `theme` (`light`/`dark`). Clients rendering icons MUST support `image/png` and
`image/jpeg`; SHOULD support `image/svg+xml` and `image/webp`.

> **Consuming icons is a security boundary.** Reject non-HTTPS/`data:` schemes and cross-origin
> redirects; fetch without credentials; cap size and dimensions; detect content type by magic bytes
> and reject mismatches; sanitize SVG (it can carry executable script).

### 2.5 JSON Schema rules

- Default dialect is **JSON Schema 2020-12** when `$schema` is absent. Implementations MUST support
  2020-12 and MUST handle unsupported dialects with an explicit error.
- **`$ref` MUST NOT be auto-dereferenced to a network URI.** An opt-in fetcher must default off,
  enforce a host allowlist (at minimum rejecting loopback/link-local/private addresses), apply
  timeouts and size limits, and log what it fetched. Schemas with unresolved external `$ref`s
  SHOULD be rejected, not treated as permissive.
- Bound composition keywords (`anyOf`/`oneOf`/`allOf`/`if`/`then`/`else`, `$defs`) — max depth,
  subschema count, or a per-validation time budget. An unbounded validator is a DoS vector.

---

## 3. Request Lifecycle & `server/discover`

### 3.1 There is no lifecycle

There is no handshake, no negotiation round, and no shutdown RPC. A client sends a request; the
server accepts or rejects it on its own merits.

```
Client                                    Server
  ├──── POST tools/call (_meta: version, caps) ──►│
  │◄─── result (resultType: "complete") ──────────┤
```

If the server doesn't implement the requested version:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32022,
    "message": "Unsupported protocol version",
    "data": {"supported": ["2026-07-28", "2025-11-25"], "requested": "1900-01-01"}
  }
}
```

The client SHOULD pick a mutually supported version from `supported` and retry.

### 3.2 `server/discover`

Optional for clients, **mandatory for servers**. One request returns versions, capabilities, and
identity — no probing with `tools/list` + `prompts/list` + `resources/list`.

```json
// →
{
  "jsonrpc": "2.0",
  "id": "discover-1",
  "method": "server/discover",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {"name": "ExampleClient", "version": "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}

// ←
{
  "jsonrpc": "2.0",
  "id": "discover-1",
  "result": {
    "resultType": "complete",
    "supportedVersions": ["2026-07-28"],
    "capabilities": {"tools": {}, "resources": {}},
    "instructions": "This server provides weather and resource utilities.",
    "ttlMs": 3600000,
    "cacheScope": "public",
    "_meta": {
      "io.modelcontextprotocol/serverInfo": {"name": "ExampleServer", "version": "1.0.0"}
    }
  }
}
```

Two reasons to call it:
1. **Presenting server info** — identity, capabilities, and versions in one round trip.
2. **stdio backward-compat probe** — stdio has no HTTP status code to drive fallback, so a dual-era
   client SHOULD probe with `server/discover` first (§5.4).

The result is cacheable (§9), so a client can persist it and skip the probe on reconnect.

### 3.3 Era interop

Terminology: **modern** = per-request metadata (`2026-07-28`+). **Legacy** = `initialize` handshake
(`2025-11-25` and earlier). **Dual-era** = supports both.

| Client | Server | Outcome |
|---|---|---|
| Modern | Modern | Works. Version mismatch → `-32022`, client retries. |
| Modern | Legacy | **Fails.** Worse: some legacy servers process an era-ambiguous `tools/call` under legacy semantics. Probe first to fail deterministically. |
| Dual-era | Modern | Works, stays modern. |
| Dual-era | Legacy | Works — falls back to `initialize` (and possibly further to HTTP+SSE). |
| Legacy | Modern | **Fails.** Legacy clients have no fall-forward. |
| Legacy | Dual-era | Works, served under the negotiated legacy revision. |

A dual-era **server** picks behavior from how the client opens: modern `_meta` ⇒ stateless
`2026-07-28`; an `initialize` request ⇒ legacy semantics. Both eras MAY be served concurrently on
one endpoint. The official SDK v2 does exactly this, automatically ([§10.11](#1011-serving-legacy-clients)).

Era detection is a property of the **server**, not the request. Clients SHOULD cache it for the
server process (stdio) or origin (HTTP) and re-probe only if the cached assumption fails.

> A modern-only server SHOULD name its supported versions in whatever error it returns to an
> `initialize` request — that message may be the only diagnostic a legacy client can show a user.

---

## 4. Transport: Streamable HTTP

> **Default to this transport.** Use stdio only when a local host (Claude Desktop, an editor) must
> launch the server as a subprocess.

### 4.1 One endpoint, POST only

```
POST   /mcp     ← every client message
GET    /health  ← health check (not MCP; good practice)
```

That's it. Compared to `2025-11-25`:

- **`GET /mcp` is gone** — no standalone SSE stream. A modern-**only** server SHOULD answer
  `405 Method Not Allowed`.
- **`DELETE /mcp` is gone** — there is no session to terminate. Also `405`.
- **`Mcp-Session-Id` is gone** — ignore it if an old client sends one; never mint or echo one.
- **`Last-Event-ID` is gone** — ignore it; streams are not resumable.

> **A dual-era server does not return `405`.** The `405` guidance applies only to a server that
> supports *this revision alone*. Because the official SDK also serves the legacy leg, its `GET` and
> `DELETE` routes still exist and answer `400 Bad Request` (missing session id) instead — verified
> against `mcp` 2.0.0. Don't write a conformance test that asserts `405` against a dual-era server.

### 4.2 Request/response rules

| Requirement | Detail |
|---|---|
| Method | `POST` only. Every JSON-RPC message is its own POST. |
| `Accept` | MUST list both `application/json` **and** `text/event-stream` |
| Body | A single JSON-RPC *request* or *notification*. Clients MUST NOT send responses. |
| Response (request) | Either `application/json` (one object) **or** `text/event-stream`. Clients MUST support both. |
| Response (notification) | `202 Accepted`, no body — or an HTTP error if unacceptable |
| SSE framing | Server MAY send request-scoped `notifications/progress` / `notifications/message` before the final response; the final response SHOULD terminate the stream |
| Server→client requests | **Never.** They are embedded in `InputRequiredResult` ([§7](#7-multi-round-trip-requests-mrtr)). |

**Cancellation is the disconnect.** Closing the SSE response stream MUST be treated by the server as
cancellation of that request; there is no `notifications/cancelled` on HTTP. The server SHOULD stop
work promptly and MUST NOT send anything further for that request.

**Keep-alives:** for long-lived streams (especially `subscriptions/listen`), servers are encouraged
to emit a periodic SSE comment line (`:\r\n`) so intermediaries and idle timeouts don't kill a quiet
stream. Also send `X-Accel-Buffering: no` so nginx-class proxies don't buffer.

### 4.3 Required headers

Selected JSON-RPC body fields are mirrored into HTTP headers so gateways and load balancers can
route and inspect without parsing the body.

| Header | Source | Required for |
|---|---|---|
| `MCP-Protocol-Version` | `_meta.io.modelcontextprotocol/protocolVersion` | **All requests** |
| `Mcp-Method` | `method` | **All requests** |
| `Mcp-Name` | `params.name` or `params.uri` | `tools/call`, `resources/read`, `prompts/get` |
| `Mcp-Param-{Name}` | annotated tool params | when `x-mcp-header` is used (§4.4) |
| `Accept` | — | `application/json, text/event-stream` |
| `Content-Type` | — | `application/json` |
| `Origin` | — | validated; invalid → **403** |
| `Authorization` | — | `Bearer <token>` only, never a query string |

```http
POST /mcp HTTP/1.1
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: tools/call
Mcp-Name: get_weather

{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
  "name":"get_weather","arguments":{"location":"Seattle, WA"},
  "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
           "io.modelcontextprotocol/clientCapabilities":{}}}}
```

**Header/body validation is mandatory.** Any server that parses the body MUST reject a mismatch —
this is the security property that stops a load balancer routing on one value while the server acts
on another:

```json
{"jsonrpc":"2.0","id":1,"error":{
  "code": -32020,
  "message": "Header mismatch: Mcp-Name header value 'foo' does not match body value 'bar'"}}
```

`400 Bad Request` + `-32020 HeaderMismatch` covers: a missing required header, a value that doesn't
match the body, or a value with invalid characters. Compare header **names** case-insensitively and
**values** case-sensitively; compare integers numerically (`42.0` == `42`).

**Status codes:**

| Situation | Status |
|---|---|
| Header/body mismatch, malformed `_meta`, unsupported version, missing capability | `400` |
| Invalid `Origin` | `403` |
| Unimplemented RPC method | `404` + JSON-RPC `-32601` (distinguishes it from a legacy HTTP+SSE 404) |
| `GET` / `DELETE` on a modern-only server | `405` (a dual-era server keeps its legacy routes — the SDK answers `400`) |
| Host not in allowlist (SDK behavior) | `421` |

### 4.4 `x-mcp-header` — tool params as headers

A server MAY annotate a tool parameter so clients mirror its value into `Mcp-Param-{Name}`.
Servers MAY use it; **clients MUST support it**.

```json
{
  "name": "execute_sql",
  "inputSchema": {
    "type": "object",
    "properties": {
      "region": {"type": "string", "x-mcp-header": "Region"},
      "query":  {"type": "string"}
    },
    "required": ["region", "query"]
  }
}
```
→ adds `Mcp-Param-Region: us-west1` to the POST.

**Constraints** (a client MUST reject the tool — excluding it from `tools/list` and logging a
warning — if any are violated):
- Non-empty, valid HTTP field-name token, no CR/LF, case-insensitively unique within the schema.
- Only `integer`, `string`, `boolean`. **`number` is not permitted.** Integers within ±(2⁵³−1).
- Only on properties **statically reachable** through a chain of `properties` keys — never through
  `items`, `oneOf`/`anyOf`/`allOf`/`not`, `if`/`then`/`else`, or `$ref`.

**Value encoding.** Convert to string (`true`/`false` lowercase; integers decimal). When the value
isn't safe as plain ASCII (non-ASCII, control chars, leading/trailing whitespace), use the
sentinel — which also applies to `Mcp-Name`:

```
Mcp-Param-Greeting: =?base64?SGVsbG8sIOS4lueVjA==?=
```

The `=?base64?` … `?=` markers are lowercase and case-sensitive. A plain-ASCII value that *looks*
like the sentinel MUST also be base64-encoded. Servers MUST decode before comparing to the body.

**Omission rules:** value present → client MUST send the header and server MUST validate it; value
`null` or absent from arguments → client MUST omit and server MUST NOT expect it. A client that
omits a header whose value is in the body is non-conforming and the server MUST reject it.

If a server rejects with `-32020` because `Mcp-Param-*` headers are missing or stale, the client
SHOULD re-fetch `tools/list` (the schema may have changed) and retry.

Intermediaries that don't recognize an `Mcp-Param-*` header MUST forward and ignore it. Any
intermediary enforcing policy on mirrored headers SHOULD verify `MCP-Protocol-Version` names a
version that requires header/body validation, and reject the request otherwise — older versions
never validated these, so the values are untrusted.

### 4.5 Security

1. Servers **MUST** validate `Origin` — invalid → **HTTP 403** (DNS-rebinding defense). The body MAY
   be a JSON-RPC error response with no `id`.
2. Running locally, bind **127.0.0.1**, not `0.0.0.0`.
3. Implement authentication for all non-local connections ([§16](#16-authentication--authorization)).

### 4.6 Backward compatibility

A dual-era client attempts a modern request first. On `400`, **inspect the body before falling
back** — modern servers also return `400` for `UnsupportedProtocolVersionError`,
`MissingRequiredClientCapabilityError`, and header-validation failures.

- Body contains a recognized **modern** JSON-RPC error → the server is modern. Retry with an
  advertised version or fix the request. **Do not fall back.**
- Body is empty or unrecognized → fall back to `initialize`.

For the deprecated HTTP+SSE transport (2024-11-05): on `400`/`404`/`405` *without* a modern error
body, issue a `GET` and look for an `endpoint` event as the first SSE frame.

---

## 5. Transport: Stdio

Subprocess transport — the client launches the server as a child process.

- **Client → Server**: newline-delimited JSON-RPC on **stdin**
- **Server → Client**: newline-delimited JSON-RPC on **stdout**
- **stderr**: UTF-8 logs of any severity. Clients MUST NOT assume stderr output means an error.
- Embedded newlines are forbidden. The server MUST NOT write non-MCP output to stdout.

The framing (one newline-delimited JSON-RPC message per line over a reliable bidirectional byte
stream) is reusable over Unix domain sockets or TCP; only the subprocess specifics (launch, stderr,
shutdown, restart) need channel-specific equivalents.

### 5.1 One channel, three message kinds

All messages share stdout. The server writes:
1. Responses, correlated by JSON-RPC `id`.
2. Request-scoped notifications (`notifications/progress`, `notifications/message`).
3. Notifications for an active `subscriptions/listen` — correlated by
   `io.modelcontextprotocol/subscriptionId` in `_meta`.

The server **MUST NOT** write JSON-RPC *requests* to stdout. Server→client interactions ride
`InputRequiredResult` ([§7](#7-multi-round-trip-requests-mrtr)).

### 5.2 Metadata

No header layer — everything is inline in `_meta` (§2.3).

### 5.3 Cancellation & shutdown

Stdio is a single shared channel, so there is no per-request stream to close: the client **MUST**
send `notifications/cancelled` referencing the request id. (This is the *only* place
`notifications/cancelled` is used; on HTTP, closing the stream is the signal.)

Shutdown: close the child's stdin → wait → escalate `SIGTERM`/`SIGKILL` (POSIX) or
`TerminateProcess`/Job Objects (Windows). **Servers SHOULD exit promptly on stdin EOF** — it's the
only portable graceful-shutdown signal.

On unexpected exit the client SHOULD restart. Because the protocol is stateless, in-flight requests
are simply lost and can be retried against the fresh process; active `subscriptions/listen` streams
must be re-established.

### 5.4 Backward compatibility (the stdio probe)

A dual-era client SHOULD send `server/discover` before anything else, naming its preferred modern
version in `_meta`:

| Probe result | Meaning |
|---|---|
| `DiscoverResult` | Modern. Pick from `supportedVersions`. |
| A recognized modern error (e.g. `-32022`) | Modern, wrong version. Use its `supported` list. **Do not fall back.** |
| Any other error, or a timeout | Legacy. Fall back to `initialize`. |

**The fallback MUST NOT key on one specific error code** — legacy servers answer unknown
pre-`initialize` requests with implementation-defined errors (commonly `-32601` or `-32602`) or
nothing at all.

Even a modern-only client SHOULD probe: some legacy servers don't check that a request arrived
after `initialize` and would happily process `tools/call` under legacy semantics. Probing turns a
silent misinterpretation into a deterministic failure.

---

## 6. Subscriptions & Notifications

`subscriptions/listen` replaces both `resources/subscribe`/`unsubscribe` and the HTTP `GET` stream.
One long-lived request whose *response is the stream*.

### 6.1 Opening a stream

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "subscriptions/listen",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities": {}
    },
    "notifications": {
      "toolsListChanged": true,
      "resourceSubscriptions": ["file:///project/config.json"]
    }
  }
}
```

| Filter field | Type | Delivers |
|---|---|---|
| `toolsListChanged` | `boolean` | `notifications/tools/list_changed` |
| `promptsListChanged` | `boolean` | `notifications/prompts/list_changed` |
| `resourcesListChanged` | `boolean` | `notifications/resources/list_changed` |
| `resourceSubscriptions` | `string[]` | `notifications/resources/updated` for those URIs |

All fields optional; omitting one means not subscribing. **The server MUST NOT send notification
types the client did not explicitly request.**

### 6.2 Acknowledgment

The server **MUST** send `notifications/subscriptions/acknowledged` as the first message on the
subscription, and MUST NOT send any notification before it. Its `notifications` field reflects the
subset the server agreed to honor — unsupported types are omitted, so clients SHOULD diff what they
got against what they asked for.

```json
{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{
  "_meta":{"io.modelcontextprotocol/subscriptionId":1},
  "notifications":{"toolsListChanged":true,
                   "resourceSubscriptions":["file:///project/config.json"]}}}
```

### 6.3 Receiving

Every frame carries `io.modelcontextprotocol/subscriptionId` in `_meta` — the JSON-RPC id of the
`subscriptions/listen` request that opened it. On stdio, where every subscription shares one
channel, clients **MUST** use it to demultiplex. Multiple concurrent subscriptions are allowed.

```json
{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{
  "_meta":{"io.modelcontextprotocol/subscriptionId":1},
  "uri":"file:///project/config.json"}}
```

> **Request-scoped notifications do not flow here.** `notifications/progress` and
> `notifications/message` ride the response stream of the request they relate to — never the listen
> stream.

**Events are cues, not payloads.** The update above doesn't carry the file. Both ends refetch.

### 6.4 Ending a stream

A subscription ends when the client closes the SSE stream (HTTP) or sends `notifications/cancelled`
(stdio); when the server tears it down; or when the transport drops.

When the *server* ends it deliberately, it SHOULD first respond to the original
`subscriptions/listen` request with an empty result — the graceful-close signal:

```json
{"jsonrpc":"2.0","id":1,"result":{
  "resultType":"complete",
  "_meta":{"io.modelcontextprotocol/subscriptionId":1}}}
```

A stream that closes *without* that response was an unexpected disconnect, and the client MAY
reconnect. **Streams are not resumable and events are not replayed** — after a reconnect the client
re-sends `subscriptions/listen` and refetches.

---

## 7. Multi Round-Trip Requests (MRTR)

The single biggest architectural change. Before `2026-07-28`, a server that needed something from
the user called *back* into the client mid-request. That back-channel no longer exists.

**Now the server returns.**

### 7.1 The pattern

1. Server answers `tools/call` with an `InputRequiredResult` (`resultType: "input_required"`)
   instead of a `CallToolResult`. Two fields matter:
   - **`inputRequests`** — a dict keyed by names the server chose. Each value is an `ElicitRequest`,
     a `CreateMessageRequest`, or a `ListRootsRequest`.
   - **`requestState`** — an opaque token the client echoes back verbatim.
2. Client fulfils each request, then calls **the same tool again** with the same `arguments`,
   carrying answers in `inputResponses` (under the **same keys**) and the token in `requestState`.
3. Server returns a normal `CallToolResult`.

```
Client                                        Server
  ├──── POST tools/call (id: 1) ─────────────────►│
  │◄─── InputRequiredResult ──────────────────────┤  (inputRequests: elicitation/create)
  │     … client gathers the input …
  ├──── POST tools/call (id: 2) ─────────────────►│  (same params + inputResponses + requestState)
  │◄─── final result ─────────────────────────────┤
```

Every leg is an ordinary client→server request. Nothing flows the other way, ever.

`tools/call` isn't special — `prompts/get` and `resources/read` may answer the same way.

**URL-mode elicitation** rides this exact mechanism: the `inputRequests` entry is an `ElicitRequest`
whose params are `ElicitRequestURLParams`. There is no separate completion notification and no
`elicitationId` any more (both removed in this revision); the client learns the outcome by retrying,
and a server that must correlate across retries encodes its own identifier in `requestState`.

### 7.2 `requestState` is client-supplied input

This is the part that bites. The client holds the token between legs — possibly persisting it and
resuming from a different process — so what comes back can be modified, expired, or lifted from a
different call. **The spec requires servers to integrity-protect `requestState` and reject the round
when verification fails**, whenever that state can influence authorization, resource access, or
business logic.

The official SDK seals it by default; see [§10.7](#107-mrtr-in-the-sdk) for the seal's bindings and
the multi-instance configuration you *must* set. The low-level `Server` does not seal until you opt
in.

### 7.3 Client-side loop

```python
result = await client.session.call_tool("provision", {"name": name}, allow_input_required=True)
while isinstance(result, InputRequiredResult):
    responses = {key: fulfil(req) for key, req in (result.input_requests or {}).items()}
    result = await client.session.call_tool(
        "provision", {"name": name},
        input_responses=responses,
        request_state=result.request_state,
        allow_input_required=True,
    )
```

Rules: same tool name and same `arguments` on every leg; one `InputResponse` per `inputRequests`
key, under the same key. Bound the loop — an unbounded retry loop against a misbehaving server never
terminates. If a round carries only `requestState` and no `inputRequests`, the server is saying "not
done yet": back off before retrying rather than busy-polling.

High-level SDK clients run this loop for you ([§11.4](#114-mrtr-handled-for-you)).

### 7.4 What this replaces

| Pre-2026 | Now |
|---|---|
| `elicitation/create` sent by the server mid-call | `ElicitRequest` inside `inputRequests` |
| `sampling/createMessage` sent by the server | `CreateMessageRequest` inside `inputRequests` |
| `roots/list` sent by the server | `ListRootsRequest` inside `inputRequests` |

The standalone **RPC methods** are gone; the **payload types** survive, embedded. On the client they
dispatch to the same `elicitation_callback` / `sampling_callback` / `list_roots_callback` they always
did — one set of callbacks serves both eras.

> Sampling and Roots as *features* are deprecated (SEP-2577). New servers that need the client's
> model should ask through this carrier if they must, or integrate with an LLM provider directly.

---

## 8. JSON-RPC Message Format & Error Codes

### 8.1 Message shapes

```json
// Request — id MUST NOT be null, MUST NOT duplicate an in-flight id
{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {}}

// Notification — no id, no response
{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1}}

// Result — resultType is REQUIRED
{"jsonrpc": "2.0", "id": 1, "result": {"resultType": "complete", "...": "..."}}

// Error
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32601, "message": "Method not found"}}
```

**`resultType`** is the new required discriminator:

- `"complete"` — final content.
- `"input_required"` — an [`InputRequiredResult`](#7-multi-round-trip-requests-mrtr).
- Extensions MAY add values (e.g. Tasks adds `"task"`), but only ones advertised via capabilities.
- **An unrecognized `resultType` MUST be treated as invalid.**
- **An absent `resultType` MUST be treated as `"complete"`** — that's how older servers look.

### 8.2 Error codes

JSON-RPC 2.0 reserves `-32000`..`-32099` for implementation-defined server errors. MCP now
partitions it:

- **`-32000`..`-32019` — legacy.** Grandfathered SDK usage. New codes MUST NOT be allocated here and
  new implementations SHOULD NOT use them. Receivers MUST NOT assume meaning.
- **`-32020`..`-32099` — reserved for the MCP spec.** Implementations MUST NOT emit an undefined
  code from this range, and MUST use defined codes only with their specified meaning.

| Code | Meaning |
|---|---|
| `-32700` | Parse error (invalid JSON) |
| `-32600` | Invalid request |
| `-32601` | Method not found |
| `-32602` | Invalid params — **also resource-not-found and invalid `requestState`** |
| `-32603` | Internal error |
| `-32020` | `HeaderMismatch` (§4.3) |
| `-32021` | `MissingRequiredClientCapability` (§2.3) |
| `-32022` | `UnsupportedProtocolVersion` (§3.1) |

**Retired, MUST NOT be emitted:** `-32002` (resource not found — replaced by `-32602`; clients
SHOULD still *accept* it from older servers) and `-32042` (URL elicitation required, 2025-11-25 only).

New application error codes SHOULD be allocated **outside** `-32768`..`-32000`.

> **Tool errors are NOT JSON-RPC errors.** A tool that ran and failed returns inside `result` with
> `isError: true` so the model can read the message and self-correct. JSON-RPC `error` is for
> protocol-level failures — unknown method, malformed request, missing capability. See
> [§20](#20-error-handling).

---

## 9. Caching (`ttlMs` / `cacheScope`)

Servers **MUST** include cache hints on `resultType: "complete"` results from:

`server/discover` · `tools/list` · `prompts/list` · `resources/list` ·
`resources/templates/list` · `resources/read`

Interim `"input_required"` results are **not** cacheable and carry no hints.

| Field | Type | Meaning |
|---|---|---|
| `ttlMs` | integer ≥ 0 | How long the client MAY consider the result fresh (like `Cache-Control: max-age`) |
| `cacheScope` | `"public"` \| `"private"` | Who may cache it |

- `ttlMs: 0` → immediately stale. Absent → assume `0` (only happens with older servers). Negative →
  ignore, treat as `0`. Servers MUST provide `>= 0`.
- Fresh while `now < t_received + ttlMs`. **TTL is a freshness hint, not a guarantee** — data may
  change sooner.
- Clients **SHOULD NOT** treat TTL as a polling interval. Check freshness on access; re-fetch only
  when stale. Anything that does poll MUST apply jitter and backoff.
- Clients MAY serve stale results when a re-fetch fails.

**Cache key** = method + the parameters that affect the result (`uri` for `resources/read`, `cursor`
for a paginated list). **Results from MRTR retries — anything carrying `inputResponses` or
`requestState` — MUST NOT be cached.**

**Scope:**

| Value | Rule |
|---|---|
| `"public"` | No user-specific data. Any client, gateway, or proxy MAY store and serve it to any user. |
| `"private"` | Reusable only within the same authorization context. Caches MUST NOT be shared across auth contexts — a different access token needs a different cache. |

> **Security:** a `"public"` result from an *authenticated* `tools/list` may still be shared across
> access tokens. Make `cacheScope` reflect real visibility, and never rely on it as an access
> control — enforce per-primitive authorization independently.

**With notifications:** the two are complementary. TTL avoids refetches between changes; a
`listChanged` notification is an immediate invalidation. A server MAY provide `ttlMs` without
`listChanged`, or both.

**With pagination:** each page is independently cacheable with its own `ttlMs` clock; pages MAY carry
different TTLs but **MUST** share one `cacheScope`. There's no cross-page consistency guarantee — a
client needing a consistent snapshot re-fetches from the start. An invalid cursor means discard all
cached pages and restart.

---
## 10. Official SDK v2 Server (`MCPServer`)

The recommended path. `mcp` `2.0.0`, natively `2026-07-28`, and it serves handshake-era clients on
the same app with no configuration.

### 10.1 Minimal server

```python
# server.py
from mcp.server import MCPServer

mcp = MCPServer("my-api-mcp", version="1.0.0")

@mcp.tool()
def hello(name: str) -> str:
    """Greet someone by name."""
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run(transport="streamable-http", port=8000)
    # Serves at http://127.0.0.1:8000/mcp
```

Run: `python server.py`, `uv run mcp run server.py`, or `uv run mcp dev server.py` (Inspector).

Keep `run()` under `if __name__ == "__main__":` — every loader (`mcp dev`, `mcp run`,
`mcp install`, your tests) **imports** the file, and without the guard an import becomes a running
server.

### 10.2 Constructor vs `run()`

**Constructor** describes what the server *is*; **`run()`** describes how it is served.

```python
MCPServer(
    "my-api-mcp",
    version="1.0.0",
    instructions="...",              # how/when an LLM should use this server
    lifespan=app_lifespan,           # §10.6
    middleware=[...],                # §17
    token_verifier=..., auth=...,    # §16 — these two always travel together
    subscriptions=bus,               # §10.9
    request_state_security=...,      # §10.7
    log_level="INFO",                # passed to logging.basicConfig()
    debug=False,                     # forwarded to the Starlette app
)
```

```python
mcp.run()                                              # stdio (default)
mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)
mcp.run(transport="sse")                               # superseded; don't build on it
```

`run()` transport kwargs: `host` (default `127.0.0.1`), `port` (default `8000`),
`streamable_http_path` (default `/mcp`), `json_response`, `stateless_http`,
`max_request_body_size` (default 4 MiB → HTTP `413` above it), `event_store`, `retry_interval`,
`transport_security`.

> **Transport kwargs are not constructor kwargs.** `MCPServer(..., port=9000)` raises before MCP is
> even involved:
> ```text
> TypeError: MCPServer.__init__() got an unexpected keyword argument 'port'
> ```

> `json_response=True` and `stateless_http=True` are **legacy-leg** concerns
> ([§10.11](#1011-serving-legacy-clients)). A `2026-07-28` connection is sessionless by construction
> and neither flag is reached on that path.

### 10.3 Tools

Type hints **are** the contract. Bad arguments are rejected against the generated schema *before*
your function runs, and the rejection comes back as a tool error the model reads and retries.

```python
from typing import Annotated, Literal
from pydantic import BaseModel, Field
from mcp.server import MCPServer
from mcp.types import ToolAnnotations

mcp = MCPServer("Bookshop")

@mcp.tool()
def search_books(
    query: Annotated[str, Field(description="Title or author to search for.")],
    limit: Annotated[int, Field(ge=1, le=50, description="Maximum results.")] = 10,
    genre: Literal["fiction", "non-fiction", "poetry"] | None = None,
) -> str:
    """Search the catalog by title or author."""
    ...

class Book(BaseModel):
    title: str
    author: str
    year: int = Field(ge=1450)

@mcp.tool(
    title="Add a book",
    annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False,
                                idempotent_hint=True, open_world_hint=False),
)
def add_book(book: Book) -> str:
    """Add a book to the catalog."""
    return f"Added {book.title!r}."
```

- Name from the function, description from the docstring, schema from the type hints.
  `name=`/`description=` override.
- A default makes a parameter optional; `Literal[...]` becomes an enum; `Field(ge=, le=)` becomes
  `minimum`/`maximum`.
- A Pydantic model parameter nests as `$defs` and arrives as a **validated instance**.
- `async def` for I/O. A plain `def` runs on a **worker thread** via `anyio.to_thread.run_sync()` —
  new in v2, and it matters if you use thread-local state or non-thread-safe clients.
- `annotations` are **hints for UX**, never a security boundary. `destructive_hint` and
  `idempotent_hint` are only defined for non-read-only tools.

**Return values** become two things: `content` (text the model reads) and `structured_content`
(typed data for the client application). A `-> str` is wrapped as `{"result": ...}`; a Pydantic
model / dataclass serializes to its JSON and gets an auto `output_schema`.

**Register at runtime** with `mcp.add_tool(fn)` — same name/description/schema derivation.

### 10.4 Resources

```python
@mcp.resource("config://app")
def get_config() -> str:
    """The active configuration."""
    return "theme=dark\nlanguage=en"

@mcp.resource("users://{user_id}/profile")
def get_user_profile(user_id: str) -> str:
    """A customer's profile."""
    return f"User {user_id}: 12 orders since 2021."

@mcp.resource("stats://catalog", mime_type="application/json")
def catalog_stats() -> dict[str, int]:
    return {"books": 1204, "authors": 391}
```

- Resources are **addressed**, not named — a client asks for `config://app`, never `get_config`.
- A `{placeholder}` makes it a **template**: it moves from `resources/list` to
  `resources/templates/list`, and one function serves every matching URI. Placeholder names must
  equal parameter names — a mismatch raises `ValueError` at **import time**.
- Your function runs on **read**, not on list. Expose a thousand; pay for the ones opened.
- `str` → text; `bytes` → base64 `BlobResourceContents`; anything else JSON-serializable → JSON text.
  `mime_type=` defaults to `text/plain` and is **never inferred** — an unlabelled `dict` resource is
  still advertised as plain text.
- Templates use RFC 6570 (`{+path}`, `{?q,lang}`). **v2 enforces strict RFC 6570** and applies
  path-safety checks to extracted values by default — a template whose values legitimately contain
  `..` or absolute paths needs explicit handling.
- Ready-made classes for the no-function case: `TextResource`, `BinaryResource`, `FileResource`,
  `HttpResource`, `DirectoryResource` in `mcp.server.mcpserver.resources`, registered with
  `mcp.add_resource(...)`.

### 10.5 Prompts & completions

```python
@mcp.prompt(title="Recommend a book")
def recommend(genre: str) -> str:
    """Ask for a recommendation in a genre."""
    return f"Recommend one {genre} book from the catalog and say why."

@mcp.completion()
async def complete_genre(ref, argument, context) -> Completion | None:
    return Completion(values=[g for g in GENRES if g.startswith(argument.value)])
```

Prompt arguments are always `str → str` on the wire. The result is `messages`, a list of
`PromptMessage` with a `role` and a content block.

### 10.6 Context, dependencies, lifespan

**`Context`** — annotate a parameter with it and the SDK injects it. The parameter is **invisible to
the model**: it never appears in the input schema.

```python
from mcp.server.mcpserver import Context

@mcp.tool()
async def describe(ctx: Context) -> str:
    [contents] = await ctx.read_resource("catalog://genres")
    await ctx.report_progress(0.5, total=1.0, message="halfway")
    return f"[{ctx.request_id}] {contents.content}"
```

| On `Context` | What it gives you |
|---|---|
| `ctx.request_id` | id of the request being served |
| `await ctx.read_resource(uri)` | read the server's own resources through the same registry |
| `await ctx.report_progress(progress, total, message)` | progress on the request's response stream |
| `await ctx.elicit(...)` / `ctx.elicit_url(...)` | ask the user — **legacy-only**; prefer `Resolve` |
| `ctx.session` | the connection back to the client (legacy `send_*` notifications) |
| `ctx.headers` | inbound HTTP headers, or `None` on stdio |
| `ctx.request_context.lifespan_context` | whatever your lifespan yielded |
| `ctx.input_responses` | MRTR answers on a retry (§10.7) |
| `await ctx.notify_tools_changed()` / `notify_prompts_changed()` / `notify_resources_changed()` / `notify_resource_updated(uri)` | publish to `subscriptions/listen` streams (§10.9) |

> **Logging is deliberately not on that list.** Use Python's `logging` module. `ctx.info()` and
> friends are deprecated ([Appendix B](#appendix-b--deprecated-features-registry)).

> There is **no ambient context**. `get_context()` was removed in v2. A helper your tool calls does
> not get its own `Context` — pass `ctx` down as an ordinary argument.

**Dependencies (`Resolve`)** — parameters filled by *your* functions, invisible to the model. This is
the API to build on, because it is **era-portable**: the framework picks the wire form from the
negotiated version.

```python
from typing import Annotated
from mcp.server.mcpserver import Resolve, Elicit, Sample, ListRoots

async def check_stock(title: str) -> Stock:            # `title` matched by name from the tool's args
    return Stock(title=title, copies=INVENTORY.get(title, 0))

async def confirm_backorder(title: str,
                            stock: Annotated[Stock, Resolve(check_stock)]) -> Backorder | Elicit[Backorder]:
    if stock.copies > 0:
        return Backorder(confirm=True)                 # in stock: no question, no round trip
    return Elicit(f"{title!r} is out of stock. Order anyway?", Backorder)

@mcp.tool()
async def order_book(
    title: str,
    stock: Annotated[Stock, Resolve(check_stock)],
    backorder: Annotated[Backorder, Resolve(confirm_backorder)],
) -> str:
    ...
```

- A resolver's parameters resolve the same way: another `Resolve(...)`, the tool's own arguments by
  name, or the `Context`. The graph runs each resolver **at most once per round**.
- Bad graphs (unclassifiable parameter, resolver cycle) raise `InvalidSignature` **at registration**,
  before a client connects.
- A resolver may return `Elicit(message, Model)` to ask the user, `Sample(...)` for an LLM
  completion through the client, or `ListRoots()`. Annotate the consumer with the plain result type
  (`CreateMessageResult`, `ListRootsResult`), or `ElicitationResult[T]` when decline/cancel is an
  outcome you want to branch on — an unwrapped `Annotated[T, Resolve(...)]` aborts the call on
  decline, which is the right default for a precondition.
- A missing client capability refuses the call with `-32021`.

**Lifespan** — an `@asynccontextmanager` yielding one object, entered once at startup:

```python
@asynccontextmanager
async def app_lifespan(server: MCPServer) -> AsyncIterator[AppContext]:
    db = await Database.connect()
    try:
        yield AppContext(db=db)
    finally:
        await db.disconnect()

mcp = MCPServer("Bookshop", lifespan=app_lifespan)

@mcp.tool()
def count_books(genre: str, ctx: Context[AppContext]) -> str:
    return f"{ctx.request_context.lifespan_context.db.query()} books in {genre!r}."
```

> `Context[AppContext]` is **tool-only**. On a resource or prompt it fails every call with
> *"Context is not available outside of a request"* — write the bare `ctx: Context` there and reach
> the object at runtime anyway. Without a `lifespan=`, `lifespan_context` is `{}`, never `None`.

### 10.7 MRTR in the SDK

Most of the time you never type `InputRequiredResult` — a `Resolve(...)` parameter *is* a
multi-round-trip tool and the SDK produces the result for you.

The manual form is a handler returning `InputRequiredResult` directly. On `MCPServer` that works for
`@mcp.prompt()` and template `@mcp.resource()` functions (which read `ctx.input_responses` on the
retry) and for `@mcp.tool()` when the dependency form doesn't fit. The two forms **do not mix**: a
call has one `input_responses`/`request_state` channel, so a tool using `Resolve(...)` cannot also
return `InputRequiredResult`. Static `@mcp.resource()` functions can't participate — no `Context`,
nothing to read on the retry.

```python
@mcp.tool()
async def refund(amount: int, ctx: Context) -> str | InputRequiredResult:
    if ctx.input_responses is None:
        return InputRequiredResult(input_requests={"ok": CONFIRM}, request_state=f"refund:{amount}")
    answer = (ctx.input_responses or {}).get("ok")
    if not isinstance(answer, ElicitResult) or answer.action != "accept":
        return "refund cancelled"
    return f"refunded ${amount}"
```

> Returning an `InputRequiredResult` on a **legacy** connection can't be serialized into the
> negotiated version — the client gets `-32603` *"Handler returned an invalid result"*. A dual-era
> server must check `ctx.protocol_version` before reaching for it. This is exactly why `Resolve` is
> the better API.

**`requestState` is sealed by default.** `MCPServer` seals every outgoing `requestState` and verifies
every echo under a key generated at process start. You write plaintext and read plaintext; the wire
carries an opaque encrypted token. The seal binds each token to:

- **A time window** — re-sealed each round; `RequestStateSecurity(ttl=...)` (default 600s) bounds
  per-round think time, not the whole flow.
- **The authenticated principal** — the validated token's client, issuer, and subject. State minted
  for one user fails under another. With auth terminated outside the SDK, supply your own signal via
  `bind_principal=`. A verifier that includes `subject` inconsistently changes the principal
  mid-flow and in-flight rounds are rejected.
- **The originating request** — method, tool/prompt name or resource URI, and a digest of arguments.
- **The exact question asked** — every resolver answer is pinned to the rendered question. Derive
  questions deterministically from arguments; a message built from a timestamp or a live rate looks
  stale every round and re-asks forever until the client's round limit ends the call.

```python
from mcp.server.mcpserver import MCPServer, RequestStateSecurity

mcp = MCPServer("billing", request_state_security=RequestStateSecurity(keys=[SHARED_KEY]))
```

> **The single most common multi-worker failure.** The default key is `os.urandom(32)` per process.
> Under `--workers 4` that's four keys. A retry that lands on a sibling worker fails with a frozen
> `-32602 "Invalid or expired requestState"` and one server-side `WARNING`. The fix has **two**
> halves: the same `keys=[...]` (≥32 bytes) on every instance **and the same server `name`**, which
> is the token's audience claim — `MCPServer(f"billing-{POD}")` reads like good hygiene and breaks
> every cross-instance retry. Use `RequestStateSecurity(keys=[...], audience="billing")` if
> per-instance names matter.
>
> Rotate in three fully-rolled-out phases: `keys=[OLD, NEW]` → `keys=[NEW, OLD]` → `keys=[NEW]`
> (one TTL later). `keys[0]` seals; every key verifies. **Never promote the minter first.**
>
> Generate one with: `python -c "import secrets; print(secrets.token_hex(32))"`

`RequestStateSecurity(codec=...)` takes anything with `seal(bytes) -> str` / `unseal(str) -> bytes`
that raises `InvalidRequestState` for a token it didn't mint (envelope encryption against a KMS is
the classic shape). TTL, principal binding, and request binding stay the SDK's job for every codec —
a codec owes only integrity and, ideally, confidentiality.

### 10.8 Errors

Two paths, and the deciding question is **"could a smarter model have avoided this?"**

```python
# YES → ordinary exception → is_error=True result the model reads and retries
raise ValueError(f"No book titled {title!r} in the catalog.")

# NO → MCPError → JSON-RPC error; the model sees nothing, the host deals with it
from mcp import MCPError
from mcp.types import INVALID_PARAMS
raise MCPError(code=INVALID_PARAMS, message="...", data={...})

# A missing resource
from mcp.server.mcpserver.exceptions import ResourceNotFoundError
raise ResourceNotFoundError(f"No book titled {title!r}.")   # → -32602 with {"uri": ...} in data
```

> **Never `return` an error message from a tool.** A returned string has `is_error=False`, so the
> model and every client UI read it as the answer. `raise` — the flag is the signal.

`MCPError` is forwarded **verbatim**, not sanitized. Don't put internals in it.

### 10.9 Subscriptions

`MCPServer` serves `subscriptions/listen` for you — acknowledgment ordering, per-stream filtering,
and subscription-id stamping are the SDK's job. Your side is one line:

```python
@mcp.tool()
async def complete_task(board: str, task: str, ctx: Context) -> str:
    BOARDS[board][task] = True
    await ctx.notify_resource_updated(f"board://{board}")
    return f"{task}: done"
```

Publishing to an idle server is a no-op — never check whether anyone is listening.

**Filtering is a contract**, and `MCPServer` matches resource URIs as **exact strings**: a stream
that named `board://sprint` hears nothing about `board://sprint/tasks/1`. (The spec permits
sub-resource reporting; this SDK never does, but clients should expect it from others.)

> **Subscription auth is not resource auth.** By default any caller may watch any URI. Nothing
> consults your read handler, so a caller your `files://{name}` handler would refuse can still learn
> *that* `files://payroll.csv` changed, and when. Narrow, but real — gate it with a middleware on
> `subscriptions/listen` before publishing per-user URIs from a multi-tenant server
> ([§17](#17-middleware)). Keep the refusal message uniform so it never confirms which URIs exist.
> The decision holds for the stream's lifetime — there is no per-event re-check, so end the
> connection when a caller's access lapses.

**Across replicas:** a listen stream is pinned to one replica for its life, so a publish elsewhere
must reach it. `SubscriptionBus` is a two-method `Protocol` (`publish`, `subscribe`) over your own
pub/sub; the SDK ships only `InMemorySubscriptionBus`, which spans server objects within **one
process**.

```python
mcp = MCPServer("Sprint Board", subscriptions=RedisSubscriptionBus(redis))
```

The bus carries four small typed `ServerEvent` dataclasses, never JSON-RPC, so a bus implementation
can't break the protocol — only move events between processes. Listeners are synchronous and must
not raise. Construct the bus yourself if you need to publish from outside a request (a lifespan
task, a webhook); `MCPServer` builds one internally and does not expose it.

### 10.10 ASGI / mounting

```python
app = mcp.streamable_http_app()          # a Starlette app with one route, /mcp
```

```console
uvicorn server:app
```

Mounting inside a bigger app **disables the built-in lifespan** — this is the line everyone forgets:

```python
@asynccontextmanager
async def lifespan(app: Starlette) -> AsyncIterator[None]:
    async with mcp.session_manager.run():
        yield

app = Starlette(routes=[Mount("/", app=mcp.streamable_http_app())], lifespan=lifespan)
```

Without it the app starts, the route resolves, and the first request fails with
`RuntimeError: Task group is not initialized. Make sure to use run().`

- `Mount("/")` matches **every** path — your own routes go *before* it.
- `mcp.session_manager` only exists **after** `streamable_http_app()` has been called.
- Several servers → several mounts, one lifespan entering every manager via `AsyncExitStack`.
- `streamable_http_path="/"` moves the endpoint to the mount prefix itself.
- `@mcp.custom_route("/health", methods=["GET"])` adds plain HTTP endpoints — **never
  authenticated**, deliberately, so health checks and OAuth callbacks work before a token exists.
  Don't put anything private behind one.

### 10.11 Serving legacy clients

**The `streamable_http_app()` you already deploy serves both eras.** The SDK routes each request by
its `MCP-Protocol-Version` header — modern requests to the modern handler, handshake-era versions
(or no header at all, which is how a pre-2026 `initialize` arrives) to the legacy transport. There
is no `legacy=` option, no version allowlist, and no way to disable an era.

Your handler code forks in **exactly one place**: change notifications, because the eras listen on
different pipes.

```python
@mcp.tool()
async def restock(title: str, copies: int, ctx: Context) -> str:
    STOCK[title] = STOCK.get(title, 0) + copies
    await ctx.notify_resource_updated(f"stock://{title}")        # → subscriptions/listen streams
    await ctx.session.send_resource_updated(f"stock://{title}")  # → legacy session streams
    return f"{STOCK[title]} in stock"
```

Two lines, no `if`, no version check. Everything else — tools, resources, prompts, structured
output, progress, errors, and asking the user for input via `Resolve` — is era-portable by
construction.

**What a legacy session costs.** The moment a pre-2026 client sends `initialize`, the SDK mints an
`Mcp-Session-Id` and keeps a record behind it in a **plain in-process `dict`**. There is no
distributed session store and no way to plug one in. On more than one worker, a request that lands
on the wrong process gets `404 Session not found`. So: **legacy clients need sticky routing.**

> `event_store=` is **not** the fix. It is resumability (replaying SSE events to a client
> reconnecting to the *same* session), never a session store.

`stateless_http=True` is the one knob, and it is **legacy-leg only** — a request is routed on the
version header *before* the flag is read. It buys free load balancing at the price of both
server→client channels on that leg: every server-initiated request raises `NoBackChannelError`
(a top-level protocol error, not an `is_error` result — including `Resolve` asking a *legacy* client
its question), and notifications are silently dropped. If your tools never call back into the
client, take it. If they do, keep the sessions sticky.

`json_response=True` takes half the same cost on *every* legacy session: no per-request stream, so a
mid-request `ctx.elicit()` raises `NoBackChannelError` and request-scoped notifications are dropped.
The session's standalone stream is untouched.

### 10.12 Silent behavior changes when upgrading from v1

These compile fine and act differently — the dangerous class:

- Sync handlers now run on **worker threads**, not the event loop.
- `MCPError` raised in a tool becomes a **protocol error the model cannot see** (v1 wrapped some of
  these into `CallToolResult`).
- Results are **validated before transmission**.
- `httpx` → **`httpx2`**: `except httpx.…` handlers still import and type-check but never match, and
  TLS validation goes through the OS trust store via `truststore` rather than a bundled CA list. In
  minimal containers set `SSL_CERT_FILE`/`SSL_CERT_DIR` or pass an explicit `verify=`.
- URI templates enforce **strict RFC 6570** plus default path-safety checks.
- Python attributes are **snake_case** (`is_error`, `input_schema`, `next_cursor`, `mime_type`); the
  JSON wire stays camelCase.
- Resource-not-found is **`-32602`**, not `-32002`.
- **Removed outright:** WebSocket transport and the `mcp[ws]` extra, the experimental Tasks API
  (`mcp.*.experimental`), `mcp.shared.version`, `mcp.shared.progress`, `mcp.shared.session`, `ping`.

---

## 11. Official SDK v2 Client

One object, one lifecycle: construct, enter `async with`, call methods.

### 11.1 Connecting

```python
from mcp import Client

async with Client(mcp) as client:                       # in-process (tests, embedding)
    ...
async with Client("http://localhost:8000/mcp") as client:   # Streamable HTTP (production)
    ...
async with Client(transport) as client:                 # any custom transport
    ...
```

`Client` resolves the transport from the argument's type: an `MCPServer` (or low-level `Server`)
connects in-process; a URL string is Streamable HTTP; anything you can
`async with ... as (read, write)` is a transport.

> Construction is free — nothing is resolved, fetched, or spawned. `async with` is the lifecycle,
> and a `Client` **cannot be reused** after the block exits. Touch it before entering and you get
> `RuntimeError: Client must be used within an async context manager`.

Four read-only properties populate on entry:

```python
client.server_info           # .name / .version, or None if the server didn't report one
client.server_capabilities   # tools, resources, prompts, completions … (None where unsupported)
client.protocol_version      # e.g. "2026-07-28"
client.instructions          # the server's instructions= string, or None
```

### 11.2 Verbs

```python
result = await client.list_tools()
for tool in result.tools:
    print(tool.name, tool.title, tool.description, tool.input_schema)

result = await client.call_tool("lookup_book", {"title": "Dune"})
for block in result.content:                       # union: Text/Image/Audio/ResourceLink/Embedded
    if isinstance(block, TextContent):
        print(block.text)
print(result.structured_content, result.is_error)

await client.list_resources()            # concrete URIs
await client.list_resource_templates()   # parameterised patterns
await client.read_resource("catalog://genres/poetry")
await client.list_prompts()
await client.get_prompt("recommend", {"genre": "poetry"})
await client.complete(ref=PromptReference(type="ref/prompt", name="recommend"),
                      argument={"name": "genre", "value": "p"})
```

- **A raising tool is a result, not an exception.** `is_error=True` with the message in `content`.
  So is calling a tool the server doesn't have. A `Client` method raises `MCPError` only when the
  server answers with a JSON-RPC **error** instead of a result. Always check `is_error` before
  trusting `structured_content`.
- Narrow `content` blocks with `isinstance` — the union is honest about what a tool may send.
- `from mcp.shared.metadata_utils import get_display_name` picks `title` or falls back to `name`.
- Every `list_*` takes `cursor=`; loop until `next_cursor is None`.
- If a server's `structured_content` doesn't satisfy its declared `output_schema`, `call_tool`
  raises `RuntimeError: Invalid structured content returned by tool …` quoting the jsonschema
  failure. This client checks; servers don't.

### 11.3 Protocol modes

| You write | Negotiation traffic | You get |
|---|---|---|
| `Client(target)` | one `server/discover`; `initialize` if that fails | newest mutually supported version, either era |
| `Client(target, mode="legacy")` | `initialize` handshake | a handshake-era version; server-initiated requests work |
| `Client(target, mode="2026-07-28")` | **none** | that version pinned, `server_info` is `None` |
| `Client(target, mode="2026-07-28", prior_discover=saved)` | **none** | pinned **and** the identity you saved |

`mode="auto"` is the default: one probe, fall back on failure. `client.protocol_version` always
answers "what did I get?".

A **pin** sends nothing at all — the connection is live the instant `async with` returns, at the
cost of `server_info` and every `server_capabilities` field being `None`. Tool calls still work;
code that reads capabilities to decide what to offer does not. Only modern versions are pinnable —
a handshake-era string is rejected at construction, before any I/O.

**`prior_discover=` pays that cost back.** Save `client.session.discover_result` (a Pydantic model —
`model_dump_json()` to a cache, `DiscoverResult.model_validate_json(...)` back) and reconnect with
zero negotiation round trips *and* full identity. It only does anything when `mode` is a version pin.

> Reach for `mode="legacy"` whenever you pass a `sampling_callback`, an `elicitation_callback` you
> want driven as a *request*, or a `message_handler` — that push channel exists only on a
> handshake-era session.

### 11.4 MRTR handled for you

Register the callbacks and call the tool. When an `InputRequiredResult` arrives, `Client` dispatches
each `input_requests` entry to the matching callback, retries with the answers and the echoed
`request_state`, and keeps going until a `CallToolResult` comes back. The intermediate rounds are
invisible.

```python
async def handle_elicitation(context: ClientRequestContext, params: ElicitRequestParams) -> ElicitResult:
    return ElicitResult(action="accept", content={"region": "eu-west-1"})

async with Client("http://127.0.0.1:8000/mcp", elicitation_callback=handle_elicitation) as client:
    result = await client.call_tool("provision", {"name": "orders"})
```

`get_prompt` and `read_resource` drive the same loop. Omit the callback and the SDK's stand-in
answers every elicitation with an error, so `call_tool` raises `MCPError: Elicitation not supported`.

The loop is bounded by `input_required_max_rounds` (default 10); past it, `call_tool` raises. A round
carrying only `request_state` and no `input_requests` triggers a short backoff (50 ms doubling to a
250 ms ceiling) rather than a busy poll.

**Drive it yourself** — with `client.session.call_tool(..., allow_input_required=True)` — when your
client is **distributed** (a different worker issues the retry; `request_state` is the persistable
token you carry across that boundary), when you need to **inspect or audit** each round, or when you
want a **wall-clock** bound (`anyio.fail_after(...)`) instead of a round count. See
[§7.3](#73-client-side-loop).

### 11.5 Transports

```python
import httpx2
from mcp.client.streamable_http import streamable_http_client

async with httpx2.AsyncClient(
    headers={"Authorization": "Bearer ..."},
    timeout=httpx2.Timeout(30.0, read=300.0),
    follow_redirects=True,
) as http_client:
    transport = streamable_http_client("http://localhost:8000/mcp", http_client=http_client)
    async with Client(transport) as client:
        ...
```

The default URL form builds an `httpx2.AsyncClient` configured the way MCP needs:
`follow_redirects=True`, 30s connect/write/pool, **300s read** (the server may hold a response
stream open).

> `streamable_http_client` no longer takes `headers=` or `timeout=` — its only parameters are `url`,
> `http_client`, and `terminate_on_close`. Everything HTTP-shaped lives on the one `httpx2` client
> you pass in, **and you own its lifecycle** — the SDK never closes a client it didn't create.
> OAuth plugs in the same way: `httpx2.AsyncClient(auth=OAuthClientProvider(...))`.

### 11.6 Listening

```python
from mcp.client.subscriptions import ResourceUpdated, ToolsListChanged

async with client.listen(tools_list_changed=True, resource_subscriptions=[BOARD]) as sub:
    async for event in sub:
        match event:
            case ResourceUpdated(uri=uri):
                print(await read_board(client, uri))
            case ToolsListChanged():
                print([t.name for t in (await client.list_tools()).tools])
```

Entering `client.listen(...)` sends the request and waits for the acknowledgment, so the stream is
live when the block starts. Each typed event is a **cue to refetch**, never a payload.

> `subscribe_resource()` / `unsubscribe_resource()` are the 2025-era pair. `MCPServer` doesn't
> implement them, and on the `2026-07-28` wire those verbs don't exist — the request answers
> `-32601`.

---

## 12. Low-Level Server API

`MCPServer` is built on `Server`. Drop down when you need an **exact** schema (loaded from a file or
generated from a database), full control of the result envelope (`_meta`, `is_error`, every key of
`structured_content`), or a method MCP doesn't define. For everything else, stay on `MCPServer`.

```python
from mcp.server import Server, ServerRequestContext
from mcp.types import (CallToolRequestParams, CallToolResult, ListToolsResult,
                       PaginatedRequestParams, TextContent, Tool)

SEARCH_BOOKS = Tool(
    name="search_books",
    description="Search the catalog by title or author.",
    input_schema={"type": "object",
                  "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}},
                  "required": ["query", "limit"]},
)

async def list_tools(ctx: ServerRequestContext, params: PaginatedRequestParams | None) -> ListToolsResult:
    return ListToolsResult(tools=[SEARCH_BOOKS])

async def call_tool(ctx: ServerRequestContext, params: CallToolRequestParams) -> CallToolResult:
    args = params.arguments or {}
    if params.name != "search_books":
        raise ValueError(f"Unknown tool: {params.name}")
    return CallToolResult(content=[TextContent(type="text", text=f"Found 3 matching {args['query']!r}.")])

server = Server("Bookshop", on_list_tools=list_tools, on_call_tool=call_tool)
```

The whole API in three bullets:

- **Handlers are constructor parameters** (`on_list_tools=`, `on_call_tool=`, `on_read_resource=`,
  `on_list_resources=`, `on_list_prompts=`, `on_get_prompt=`, `on_completion=`,
  `on_subscriptions_listen=`). No decorators. Every handler is `async (ctx, params) -> result`.
- **You write the schema.** `Tool.input_schema` is a plain dict — advertised to the client, **never
  applied** to `params.arguments`.
- **You build the result.** Nothing is wrapped, converted, or inferred.

> **Nothing is checked for you.** A missing argument is a `KeyError` your client sees as a generic
> `-32603 Internal server error` — the model never learns what it did wrong and can't retry. An
> exception from a low-level handler is **always** a protocol error. For a model-readable failure,
> validate yourself and return `CallToolResult(..., is_error=True)`.
>
> `Server` will also forward a `tools/call` for a name you never listed straight into your handler.
> The `else: raise` branch is load-bearing.

Other notes:

- `ctx` is a `ServerRequestContext`: `ctx.session`, `ctx.lifespan_context`, `ctx.request_id`,
  `ctx.meta` (the inbound `_meta`).
- **Capabilities follow your handlers** — a `Server` advertises exactly the method families you
  registered. (`MCPServer` always advertises tools, resources, and prompts.)
- `Server[T]` is generic in what its lifespan yields, so `ctx.lifespan_context` is a typed `T`.
- `_meta=` on a result is the third channel — for the client **application**, not the model. Namespace
  your keys (`bookshop/record_ids`); `io.modelcontextprotocol/*` is reserved. The SDK stamps
  `serverInfo` into every 2026-era result. **Never put a secret in any part of a tool result** — the
  host decides what it renders.
- `add_request_handler(method, params_type, handler)` serves any custom method (subclass
  `RequestParams` so `_meta` parses); `add_notification_handler` is the twin. **`initialize` is
  reserved** — use middleware to observe it.
- **MRTR here has no batteries**: `request_state` crosses the wire exactly as written until you opt
  in with
  `server.middleware.append(RequestStateBoundary(RequestStateSecurity(keys=[...]), default_audience=server.name))`
  (both from `mcp.server.request_state`).
- `server.streamable_http_app()` is the same Starlette app. There is no `server.run(transport=...)`;
  `server.run(read_stream, write_stream, server.create_initialization_options())` drives one
  connection. `mcp dev` and `mcp run` only understand `MCPServer` — but `Client(server)` takes a
  low-level `Server` exactly like it takes an `MCPServer`.

---

## 13. PrefectHQ FastMCP

Reach for FastMCP when you want the batteries: 15+ pre-built IdP providers, `mount()`/`create_proxy()`
composition, `from_openapi()` / `from_fastapi()`, a stable middleware system, and a full DI container.

| Line | Version | Protocol | Status |
|---|---|---|---|
| **3.x** | `3.4.5` | handshake era only | stable |
| **4.0** | `4.0.0b1` | `2026-07-28` + dual-era | **beta** |

### 13.1 FastMCP 4

FastMCP 4 is built on MCP Python SDK v2 and makes stateful applications work on the sessionless
protocol while one deployment keeps serving handshake-era clients. What it adds:

- **Stateless session state** — `UserSession` / `SessionId` survive session churn without sticky
  routing.
- **Guard-mode multi-round-trip tools** (SEP-2322).
- **Background tasks** via the `io.modelcontextprotocol/tasks` extension (SEP-2663).
- **Native server extension API** (SEP-2133).
- **Server-side identity assertion** (SEP-990 ID-JAG), machine-to-machine client auth.
- Server-level cache hints (SEP-2549), routable transport headers (SEP-2243), scope step-up
  challenges (SEP-2350), OAuth `application_type` in DCR (SEP-837), RFC 9207 issuer responses.

Most FastMCP 3 servers upgrade unchanged: field access is bridged (camelCase reads still work but
warn), and the imports have a stable home in FastMCP itself.

### 13.2 Upgrading 3 → 4: what actually breaks

**Environment floors:** `pydantic >= 2.12`; FastAPI `>= 0.133.0` (the first release admitting
Starlette 1.x) or no direct Starlette pin below `1.0.1`.

```toml
[project]
dependencies = ["fastmcp==4.0.0b1"]

[tool.uv]
constraint-dependencies = ["fastmcp-slim==4.0.0b1"]   # uv only allows prereleases for named packages
```

**Removed from the server API — server-initiated sampling and roots:**
`ctx.sample()`, `ctx.sample_step()`, `ctx.list_roots()` are gone, along with
`FastMCP(sampling_handler=...)` / `sampling_handler_behavior=`. *If borrowing the caller's model is
the entire point of your server, the official guidance is to stay on 3.x rather than migrate.* The
**client** side is unaffected — `Client(sampling_handler=...)` and `Client(roots=...)` still mean
what they meant.

**The single most likely runtime failure:** `ctx.elicit(...)` is era-gated in 4.0 and **raises on
modern connections** — which is what `Client` now negotiates by default. Compiles fine, fails in
production. Migrate to the dependency form.

**Other breaks that still compile:**
- `except httpx.…` around any FastMCP call — FastMCP raises **httpx2** exceptions now, but `httpx` is
  usually still installed transitively, so the handler imports, type-checks, and silently never
  matches. Same for a custom `httpx.AsyncClient`, `httpx_client_factory=`, or `httpx.Auth`.
- `Middleware.on_initialize` hooks, and `ctx.set_state` values read back in a later call — neither
  survives a modern connection.
- Clients matching on the resource-not-found code `-32002`.
- Templated resources whose parameters legitimately carry `..` or absolute paths.
- An OAuth server with `issuer_url` set to anything other than `base_url` — forces a one-time
  re-authorization of every client.
- camelCase field reads (`inputSchema`, `isError`, `mimeType`, `nextCursor`, `structuredContent`,
  `serverInfo`) — still work, but warn, and are scheduled for removal.

**Removed methods/keywords:** `FastMCP.as_proxy()`, `import_server()` (→ `mount()`, but **not**
equivalent: `import_server` took a static snapshot and skipped the child's lifespan and middleware,
`mount()` is a live composition that runs both), `mount(prefix=)`, `mount(as_proxy=)`,
`add_tool_transformation()` / `remove_tool_transformation()`, `remove_tool()` (its replacement raises
`KeyError` where this raised `NotFoundError`), tool `serializer=` / `exclude_args=`,
`StreamableHttpTransport(sse_read_timeout=)`, `FASTMCP_DECORATOR_MODE`.

**Imports that no longer resolve:** `fastmcp.server.proxy`, `fastmcp.server.openapi`,
`FastMCPOpenAPI`, `fastmcp.experimental.*`, `fastmcp.server.apps` / `fastmcp.server.app`,
`fastmcp.tools.tool`, `fastmcp.resources.resource`, `fastmcp.prompts.prompt`,
`fastmcp.server.tasks`, `fastmcp.server.sampling`, `fastmcp.server.auth.authorization`,
`CurrentDocket`/`CurrentWorker`, `SkillsProvider`, `Cachable*Result` (the misspelling was corrected
with no alias), `PromptToolMiddleware` / `ResourceToolMiddleware`.

**Background tasks moved to the extension:** `@mcp.tool(task=True)` and `TaskConfig` now require
`mcp.add_extension(TasksExtension())`. `task=` is **tools only** — not on `@mcp.resource` or
`@mcp.prompt`. Client-side `call_tool(..., task=True)` / `read_resource(task=True)` /
`get_prompt(task=True)` are gone.

**Errors:** `McpError(ErrorData(...))` positional construction moved. Catching and `err.error.code`
are unchanged.

### 13.3 FastMCP 3 essentials (still valid on 3.4.5)

```python
from fastmcp import FastMCP

mcp = FastMCP(name="my-api-mcp", version="1.0.0", instructions="...")

@mcp.tool                                  # parens optional in 3.x
def add(a: int, b: int) -> int:
    """Add two numbers."""
    return a + b

if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
```

- Transport kwargs live on `run()` / `http_app()`, not the constructor (3.x breaking change).
- Decorators return the **original function**, not a wrapper — inspect via `mcp.list_tools()`;
  enable/disable via `mcp.disable(names={...}, components={"tool"})`.
- Errors: `fastmcp.exceptions.ToolError` / `ResourceError` / `PromptError`; `mask_error_details=True`
  hides tracebacks.
- Middleware: `LoggingMiddleware`, `TimingMiddleware`, `ResponseCachingMiddleware`,
  `RateLimitingMiddleware`, `ErrorHandlingMiddleware`, `RetryMiddleware`, `PingMiddleware`,
  `ResponseLimitingMiddleware` — hooks `on_message` / `on_request` / `on_notification` /
  `on_call_tool` / `on_read_resource` / `on_get_prompt` / `on_list_*`. Ingress in registration
  order, egress reversed.
- Composition: `mount()`, `create_proxy()`, `FastMCP.from_openapi()`, `FastMCP.from_fastapi()`
  ([§18](#18-server-composition)).
- Auth providers: [§16.6](#166-fastmcp-auth-providers).
- Storage backends via `py-key-value-aio` (in-memory, `FileTreeStore`, `RedisStore`, DynamoDB,
  MongoDB, …). **Production OAuth storage MUST be encrypted** — wrap with `FernetEncryptionWrapper`
  or tokens persist in plaintext.
- Zero-config OpenTelemetry: spans are no-ops without an SDK, active with one. Span names follow MCP
  semantic conventions (`tools/call {name}`, `resources/read {uri}`, `prompts/get {name}`,
  `delegate {name}`).

---
## 14. Server Template (Raw FastAPI)

Only when you need browser CORS, custom middleware, or non-standard wire behavior neither library
accommodates. This template is `2026-07-28`-compliant: no `initialize`, no sessions,
`server/discover`, header/body validation, `resultType`, and cache hints.

```python
"""
{API_NAME} MCP Server — Raw FastAPI, protocol 2026-07-28
"""
import base64, hmac, json, logging, os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SERVER_NAME = "{api-name}-mcp"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = "2026-07-28"
SUPPORTED_VERSIONS = [PROTOCOL_VERSION]

API_BASE_URL = os.getenv("API_BASE_URL", "https://api.example.com/v1")
API_KEY = os.getenv("API_KEY", "")
MCP_AUTH_TOKEN = os.getenv("MCP_AUTH_TOKEN", "")
ALLOWED_ORIGINS = {o for o in os.getenv("ALLOWED_ORIGINS", "").split(",") if o}

# MCP error codes (§8.2)
PARSE_ERROR, INVALID_REQUEST, METHOD_NOT_FOUND = -32700, -32600, -32601
INVALID_PARAMS, INTERNAL_ERROR = -32602, -32603
HEADER_MISMATCH, MISSING_CAPABILITY, UNSUPPORTED_VERSION = -32020, -32021, -32022

META = "io.modelcontextprotocol/"


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with httpx.AsyncClient(timeout=30.0) as client:
        app.state.http_client = client
        yield


app = FastAPI(title=SERVER_NAME, lifespan=lifespan)

TOOLS = [{
    "name": "search_items",
    "description": "Search for items by keyword. Returns up to `limit` matches ordered by "
                   "relevance. Use this before any tool that needs an item id.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Search keywords"},
            "limit": {"type": "integer", "default": 10, "minimum": 1, "maximum": 50},
        },
        "required": ["query"],
    },
    "annotations": {"title": "Search items", "readOnlyHint": True, "openWorldHint": True},
}]
# Deterministic order improves client caching and LLM prompt-cache hit rates.
TOOLS.sort(key=lambda t: t["name"])


def err(rid, code, message, data=None, status=200):
    body = {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}
    if data is not None:
        body["error"]["data"] = data
    return JSONResponse(body, status_code=status)


def ok(rid, result):
    result.setdefault("resultType", "complete")
    result.setdefault("_meta", {})[META + "serverInfo"] = {
        "name": SERVER_NAME, "version": SERVER_VERSION,
    }
    return JSONResponse({"jsonrpc": "2.0", "id": rid, "result": result})


def decode_header(value: str) -> str:
    """Undo the =?base64?…?= sentinel encoding (§4.4)."""
    if value.startswith("=?base64?") and value.endswith("?="):
        return base64.b64decode(value[9:-2]).decode("utf-8")
    return value


@app.get("/mcp")
@app.delete("/mcp")
async def mcp_gone() -> Response:
    # No GET stream, no session to DELETE, in this revision (§4.1).
    return Response(status_code=405)


@app.post("/mcp")
async def mcp_endpoint(request: Request):
    # 1. Origin validation → 403 (§4.5)
    origin = request.headers.get("Origin")
    if origin is not None and ALLOWED_ORIGINS and origin not in ALLOWED_ORIGINS:
        return err(None, INVALID_REQUEST, "Invalid Origin", status=403)

    # 2. Bearer auth (constant-time)
    if MCP_AUTH_TOKEN:
        token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        if not hmac.compare_digest(token, MCP_AUTH_TOKEN):
            return JSONResponse({"error": "unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except json.JSONDecodeError:
        return err(None, PARSE_ERROR, "Parse error")

    rid = body.get("id")
    method = body.get("method", "")
    params = body.get("params") or {}
    meta = params.get("_meta") or {}

    # 3. Notifications → 202, no body
    if rid is None:
        return Response(status_code=202)

    # 4. Required per-request _meta (§2.3)
    version = meta.get(META + "protocolVersion")
    if version is None or meta.get(META + "clientCapabilities") is None:
        return err(rid, INVALID_PARAMS,
                   "Missing required _meta protocol fields", status=400)
    if version not in SUPPORTED_VERSIONS:
        return err(rid, UNSUPPORTED_VERSION, "Unsupported protocol version",
                   {"supported": SUPPORTED_VERSIONS, "requested": version}, status=400)

    # 5. Header/body validation → 400 + -32020 (§4.3)
    h_version = request.headers.get("MCP-Protocol-Version")
    h_method = request.headers.get("Mcp-Method")
    if h_version != version:
        return err(rid, HEADER_MISMATCH,
                   "Header mismatch: MCP-Protocol-Version does not match body", status=400)
    if h_method != method:
        return err(rid, HEADER_MISMATCH,
                   "Header mismatch: Mcp-Method does not match body", status=400)
    if method in ("tools/call", "resources/read", "prompts/get"):
        expected = params.get("name") or params.get("uri")
        h_name = request.headers.get("Mcp-Name")
        if h_name is None or decode_header(h_name) != expected:
            return err(rid, HEADER_MISMATCH,
                       "Header mismatch: Mcp-Name does not match body", status=400)

    # 6. Dispatch
    if method == "server/discover":
        return ok(rid, {
            "supportedVersions": SUPPORTED_VERSIONS,
            "capabilities": {"tools": {}},
            "instructions": "Use search_items to find resources.",
            "ttlMs": 3_600_000,
            "cacheScope": "public",
        })

    if method == "tools/list":
        return ok(rid, {"tools": TOOLS, "ttlMs": 300_000, "cacheScope": "public"})

    if method == "tools/call":
        name = params.get("name", "")
        args = params.get("arguments") or {}
        if name not in {t["name"] for t in TOOLS}:
            # Unknown tool: a tool error the model can correct, not a protocol error.
            return ok(rid, {"content": [{"type": "text", "text": f"Unknown tool: {name}"}],
                            "isError": True})
        try:
            result = await dispatch_tool(name, args, request.app.state.http_client)
            return ok(rid, {"content": [{"type": "text", "text": json.dumps(result, indent=2)}],
                            "structuredContent": result, "isError": False})
        except ValueError as e:
            return ok(rid, {"content": [{"type": "text", "text": f"Validation error: {e}"}],
                            "isError": True})
        except Exception:
            logger.exception("Tool failed: %s", name)
            return ok(rid, {"content": [{"type": "text", "text": "Internal tool error."}],
                            "isError": True})

    return err(rid, METHOD_NOT_FOUND, f"Method not found: {method}", status=404)


async def dispatch_tool(name, args, http):
    if name == "search_items":
        query = args.get("query", "").strip()
        if not query:
            raise ValueError("query is required")
        limit = max(1, min(int(args.get("limit", 10)), 50))
        r = await http.get(f"{API_BASE_URL}/search",
                           params={"q": query, "limit": limit},
                           headers={"Authorization": f"Bearer {API_KEY}"} if API_KEY else {})
        r.raise_for_status()
        return r.json()
    raise ValueError(f"Unknown tool: {name}")


@app.get("/health")
async def health():
    return {"status": "healthy"}
```

**Deliberately not implemented here**, and what you owe if you need them: `subscriptions/listen`
(§6 — acknowledge first, stamp every frame with the subscription id, honor the filter exactly),
MRTR (§7 — and you must integrity-protect `requestState` yourself), `x-mcp-header` /
`Mcp-Param-*` validation (§4.4), pagination cursors, and legacy-client support (Appendix A).
Every one of those is free on the official SDK, which is the argument for using it.

---

## 15. Extensions

Extensions are optional, opt-in additions negotiated through capabilities. Identifier format is
`{vendor-prefix}/{extension-name}` following the `_meta` key rules with a **mandatory** prefix.
Official extensions use `io.modelcontextprotocol/`; third parties use a reversed domain they own
(`com.example/my-extension`).

```json
{
  "capabilities": {
    "tools": {},
    "extensions": {
      "io.modelcontextprotocol/tasks": {},
      "io.modelcontextprotocol/ui": {"mimeTypes": ["text/html;profile=mcp-app"]}
    }
  }
}
```

Each extension defines its settings schema; `{}` means "supported, no settings". If one party
supports an extension and the other doesn't, the supporting party **MUST** either fall back to core
behavior or reject with an appropriate error. Extensions **SHOULD** document their fallback.

### 15.1 Tasks (`io.modelcontextprotocol/tasks`)

Tasks moved **out of the core protocol** in this revision (SEP-2663). The redesigned extension:

- Replaces the blocking `tasks/result` with polling via **`tasks/get`**.
- Adds **`tasks/update`** for client→server input mid-flight.
- **Removes `tasks/list`.**
- Lets servers return task handles **unsolicited** — no per-request opt-in.

Flow: the client advertises `io.modelcontextprotocol/tasks` in its per-request capabilities and the
server advertises it in `server/discover`. When the server decides a request is long-running it
returns a **`CreateTaskResult`** (`resultType: "task"`) with a `taskId`, initial status, TTL, and a
suggested polling interval — created durably *before* the response is sent. The client polls
`tasks/get`; terminal states carry the final result or error.

Statuses: `working`, `input_required`, `completed`, `failed`, `cancelled`. A task needing input moves
to `input_required` and surfaces the request; the client answers with `tasks/update` — no second
connection and no unsolicited server→client message.

Why not just block: connection and intermediary timeouts, crash resilience (a task id is a durable
handle you can resume polling with after a restart), progress visibility, and mid-flight interaction.

On FastMCP 4 this is `mcp.add_extension(TasksExtension())` plus `@mcp.tool(task=True)` — **tools
only** now ([§13.2](#132-upgrading-3--4-what-actually-breaks)).

### 15.2 MCP Apps (`io.modelcontextprotocol/ui`)

Servers return interactive HTML (charts, forms, dashboards) rendered inline in the conversation.
A tool declares `_meta.ui.resourceUri` pointing at a `ui://` resource; the host can preload it
before the tool is even called, then renders it in place of plain text.

Why not a standalone web app: context preservation (it lives in the conversation), bidirectional
data flow (the app calls the server's tools; the host pushes fresh results) without building your
own API/auth/state, delegation to the host's already-connected capabilities, and — the load-bearing
one — **sandboxing**: apps run in a host-controlled iframe that cannot reach the parent page, steal
cookies, or escape its container, which is what makes it safe for a host to render a third-party
app at all.

### 15.3 Others

- **Skills over MCP** — rich, structured instructions for agent workflows, discovered and consumed
  through MCP.
- **Auth extensions** (`ext-auth`): OAuth Client Credentials (machine-to-machine),
  Enterprise-Managed Authorization (centralized access control).

Official extensions live in `modelcontextprotocol/ext-*` repositories; experimental ones in
`experimental-ext-*`, each tied to a Working or Interest Group. Promotion goes through the SEP
Extensions Track and requires at least one reference implementation in an official SDK.

---

## 16. Authentication & Authorization

### 16.1 The spec (OAuth 2.1)

HTTP transports only — stdio **SHOULD NOT** follow this spec and retrieves credentials from the
environment instead.

Base specs: OAuth 2.1 draft, RFC 8414 (AS metadata), **RFC 9728 (Protected Resource Metadata)**,
**OAuth Client ID Metadata Documents** (CIMD), RFC 9207 (`iss`), RFC 8707 (Resource Indicators),
RFC 7591 (DCR — now deprecated).

**Hard requirements:**
- MCP servers **MUST** implement RFC 9728 Protected Resource Metadata; clients **MUST** use it for
  AS discovery.
- AS **MUST** provide at least one metadata discovery mechanism
  (`.well-known/oauth-authorization-server` or `.well-known/openid-configuration`); clients **MUST**
  support both.
- **PKCE required** (`S256`). Clients MUST verify `code_challenge_methods_supported`.
- **Resource Indicators (RFC 8707)**: clients **MUST** include `resource=<canonical-mcp-uri>` in
  **both** authorization and token requests, identifying the MCP server the token is for — and MUST
  send it whether or not the AS supports it. Prefer the form **without** a trailing slash.
- Tokens go in `Authorization: Bearer <token>` on **every** request, **never** in a query string.
- Servers **MUST** validate that a token was issued for them as the **audience**. Servers **MUST
  NOT** accept or transit any other token; clients **MUST NOT** send tokens issued by anyone but the
  server's AS. **Token passthrough to upstream APIs is forbidden.**

**Discovery flow:**
1. Client hits server → `401` + `WWW-Authenticate: Bearer resource_metadata="…"`.
2. Client fetches Protected Resource Metadata.
3. PRM → `authorization_servers[]`.
4. Client discovers AS metadata.
5. OAuth 2.1 auth-code + PKCE with `resource=`.

### 16.2 Client registration — CIMD first, DCR deprecated

Priority order: **CIMD** → **pre-registration** → **DCR** (deprecated, retained only for AS that
don't support CIMD) → prompt the user.

**CIMD requirements:** host the metadata document at an HTTPS URL; the `client_id` URL **MUST** use
`https` and contain a path component (`https://example.com/client.json`); the document **MUST**
include at least `client_id`, `client_name`, `redirect_uris`; and the `client_id` **MUST** match the
document URL **exactly**. Authorization servers SHOULD fetch metadata for URL-formatted client ids,
MUST validate the match and the document structure, MUST validate presented redirect URIs against
the document, and SHOULD cache respecting HTTP cache headers. AS advertise support with
`client_id_metadata_document_supported: true`.

**DCR `application_type` (SEP-837)** — clients **MUST** specify one, to avoid OIDC redirect-URI
conflicts: `"native"` for a local/desktop client with a loopback redirect, `"web"` for one served
from a non-local host. Clients MUST handle registration failure and surface a meaningful error.

**Authorization Server Binding (SEP-2352)** — credentials are bound to the AS that issued them.
Clients **MUST** key persisted credentials by the issuer identifier, **MUST NOT** reuse them with a
different AS, and **MUST** re-register when the AS changes.

### 16.3 RFC 9207 `iss` validation (SEP-2468)

Before redirecting the user agent, the client **MUST** record the `issuer` from the selected AS's
*validated* metadata document, alongside the PKCE verifier and `state`. (The check is worthless if
the expected issuer came from an unvalidated source.)

AS **SHOULD** include `iss` in authorization responses **including error responses**, and if they do
MUST advertise `authorization_response_iss_parameter_supported: true`.

On receipt, clients **MUST** validate before transmitting the code to any token endpoint:

| `…iss_parameter_supported` | `iss` present | Client action |
|---|---|---|
| `true` | yes | Compare to the recorded issuer; reject on mismatch |
| `true` | no | Reject |
| `false`/absent | yes | Compare anyway (local policy — some AS emit `iss` before updating metadata) |
| `false`/absent | no | Proceed |

After form-decoding, clients **MUST NOT** normalize before comparing — no scheme/host case folding,
no default-port elision, no trailing-slash or percent-encoding normalization. On mismatch the client
**MUST NOT** act on or display `error`, `error_description`, or `error_uri`.

> A future revision is expected to upgrade AS inclusion of `iss` from SHOULD to MUST. Emit and
> validate it now.

### 16.4 Scopes, step-up, and HTTP codes

| Code | Meaning |
|---|---|
| `401` | Invalid, expired, or missing token |
| `403` | Insufficient scope / forbidden |
| `400` | Malformed request |

Servers **SHOULD** include a `scope` parameter in `WWW-Authenticate` naming what the operation needs:

```
HTTP/1.1 403 Forbidden
WWW-Authenticate: Bearer error="insufficient_scope",
                         scope="files:read files:write",
                         resource_metadata="https://.../.well-known/oauth-protected-resource"
```

Clients **MUST** treat the challenged scopes as what's needed now, **MUST NOT** assume any set
relationship with `scopes_supported`, and SHOULD include them when re-authorizing. Clients acting for
a user SHOULD attempt the step-up flow; `client_credentials` clients should handle it otherwise.
Clients **SHOULD** implement retry limits and track upgrade attempts. Servers **MUST** account for
scope hierarchies (a broader scope implies narrower ones) and **SHOULD** be consistent about which
scopes they name. Clients SHOULD follow least privilege.

Refresh tokens: clients MUST keep them confidential in transit and storage and SHOULD include
`refresh_token` in `grant_types`, but **MUST NOT** assume they will be issued. MCP servers
**SHOULD NOT** include `offline_access` in advertised scopes.

### 16.5 Official SDK v2 auth

Your server is a **resource server**: it verifies tokens; it never issues one.

```python
from pydantic import AnyHttpUrl
from mcp.server import MCPServer
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings

class MyTokenVerifier(TokenVerifier):
    async def verify_token(self, token: str) -> AccessToken | None:
        ...   # verify a JWT signature, or call the AS's RFC 7662 introspection endpoint

mcp = MCPServer(
    "Notes",
    token_verifier=MyTokenVerifier(),
    auth=AuthSettings(
        issuer_url=AnyHttpUrl("https://auth.example.com"),
        resource_server_url=AnyHttpUrl("https://mcp.example.com/mcp"),
        required_scopes=["notes:read"],
    ),
)
```

`TokenVerifier` is the whole integration surface: one async method, token in, `AccessToken | None`
out. **`token_verifier=` and `auth=` always travel together** — one without the other raises
`ValueError` at construction.

You get two routes: `/mcp` and `/.well-known/oauth-protected-resource/mcp`, the latter serving RFC
9728 metadata built from your `AuthSettings`. Unauthenticated requests get:

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="invalid_token", error_description="Authentication required",
                  resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
```

That pointer is what makes discovery automatic. Nothing was parsed; no tool ran.

Inside any handler, `get_access_token()` (from `mcp.server.auth.middleware.auth_context`) returns the
`AccessToken` your verifier built — `client_id`, `scopes`, `subject`, `expires_at`, `claims` — or
`None`. That's the hook for per-tool rules.

> **None of this protects stdio.** A pipe has no `Authorization` header, so `token_verifier` is never
> consulted. A stdio server's security boundary is the process that launched it. The in-memory
> `Client(mcp)` skips the HTTP layer too, authorization included.

> `auth_server_provider=` embeds a full authorization server. It predates the AS/RS separation the
> MCP authorization spec is built around. New servers should not reach for it.

### 16.6 FastMCP auth providers

FastMCP's advantage. Choose by what your IdP supports:

| Pattern | When | Class |
|---|---|---|
| **TokenVerifier** | You control JWT issuance, or have existing JWT infra | `JWTVerifier` / `StaticTokenVerifier` / `IntrospectionTokenVerifier` / `DebugTokenVerifier` |
| **RemoteAuthProvider** | IdP supports DCR (Descope, WorkOS AuthKit, modern OIDC) | `RemoteAuthProvider` |
| **OAuthProxy** | Traditional providers without DCR (GitHub, Google, Azure, AWS, Discord) — FastMCP presents DCR to clients while using fixed upstream credentials | `OAuthProxy` |
| **OIDCProxy** | OIDC providers without DCR; simpler config | `OIDCProxy` |
| **MultiAuth** | Hybrid: interactive OAuth + JWT for backend services | `MultiAuth` |
| **Full OAuthProvider** | Air-gapped / specialized compliance. **Avoid.** | `OAuthProvider` (abstract) |

```python
# JWT (production)
from fastmcp.server.auth.providers.jwt import JWTVerifier
verifier = JWTVerifier(
    jwks_uri="https://issuer/.well-known/jwks.json",   # auto key rotation
    issuer="https://issuer", audience="mcp-production-api",
    algorithm="RS256", required_scopes=["read"],
)

# RFC 7662 introspection (opaque tokens)
from fastmcp.server.auth.providers.introspection import IntrospectionTokenVerifier
verifier = IntrospectionTokenVerifier(
    introspection_url="https://as/oauth/introspect",
    client_id="resource-server", client_secret="...",
    client_auth_method="client_secret_basic", required_scopes=["read"],
)

# Static — DEV ONLY, plaintext tokens
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier
verifier = StaticTokenVerifier(tokens={"dev-token": {"client_id": "alice", "scopes": ["read"]}})

# OAuthProxy — non-DCR upstreams
from fastmcp.server.auth import OAuthProxy
auth = OAuthProxy(
    upstream_authorization_endpoint="https://provider.com/oauth/authorize",
    upstream_token_endpoint="https://provider.com/oauth/token",
    upstream_client_id="...", upstream_client_secret="...",
    token_verifier=JWTVerifier(...),
    base_url="https://your-server.com", redirect_path="/auth/callback",
    jwt_signing_key=os.environ["JWT_SIGNING_KEY"],
    client_storage=encrypted_store,             # see §13.3 — MUST be encrypted
    require_authorization_consent=True,         # confused-deputy protection
)

# MultiAuth — OAuth for humans + raw JWTs for services
from fastmcp.server.auth import MultiAuth
auth = MultiAuth(server=OAuthProxy(...), verifiers=[JWTVerifier(...), JWTVerifier(...)],
                 base_url="https://my-server.com")
```

`OAuthProxy` built-ins: mandatory consent screens with session binding, upstream tokens never reach
clients (FastMCP issues its own JWTs), PKCE end-to-end, and CIMD support.
`MultiAuth` verification order is `server` first, then `verifiers` in list order; first valid
`AccessToken` wins; all-`None` → 401. Verifiers-only mode serves **no** OAuth routes or metadata.

**Pre-built providers** (all take `base_url=`, your server's public URL):

| Provider | Class | Module (`fastmcp.server.auth.providers.…`) | Pattern |
|---|---|---|---|
| WorkOS AuthKit | `AuthKitProvider` | `workos` | Remote |
| Descope | `DescopeProvider` | `descope` | Remote |
| Keycloak (26.6.0+) | `KeycloakAuthProvider` | `keycloak` | Remote |
| Scalekit | `scalekit` | `scalekit` | Remote |
| Google | `GoogleProvider` | `google` | OAuthProxy |
| GitHub | `GitHubProvider` | `github` | OAuthProxy |
| Azure / Entra | `AzureProvider`, `AzureJWTVerifier`, `EntraOBOToken` | `azure` | OAuthProxy |
| AWS Cognito | `aws` | `aws` | OAuthProxy |
| Clerk / Discord / OCI | `clerk` / `discord` / `oci` | resp. | OAuthProxy |
| Auth0 | `Auth0Provider` | `auth0` | OIDCProxy |
| PropelAuth | `PropelAuthProvider` | `propelauth` | Remote + introspection |
| Supabase | `supabase` | `supabase` | JWT |
| Hugging Face | — | `huggingface` | (forward-ported in 4.0) |

```python
from fastmcp.server.auth.providers.github import GitHubProvider
auth = GitHubProvider(client_id="...", client_secret="...", base_url="https://my-server.com")

# Azure — tenant_id is REQUIRED ("common" is no longer allowed)
from fastmcp.server.auth.providers.azure import AzureProvider
auth = AzureProvider(client_id="...", client_secret="...", tenant_id="...",
                     base_url="https://my-server.com",
                     required_scopes=["api://.../access_as_user"])   # at least one required

# Keycloak — class is KeycloakAuthProvider (not KeycloakProvider); kwargs-only
from fastmcp.server.auth.providers.keycloak import KeycloakAuthProvider
auth = KeycloakAuthProvider(realm_url="https://kc.example.com/realms/myrealm",
                            base_url="https://my-mcp-server.example.com",
                            required_scopes=["openid"], audience="mcp-api")
```

FastMCP also has a **server-side authorization** layer that filters list responses and blocks
unauthorized direct calls: `require_scopes(...)`, `require_roles(...)` (new in 4.0),
`restrict_tag(...)`, or any sync/async callable taking `AuthContext` → `bool`. Multiple checks
combine with **AND**.

```python
@mcp.tool(auth=require_scopes(["write:data"]))
async def write_record(...): ...
```

### 16.7 Simple API-key auth (server-to-server)

```python
import hmac, os

async def verify_token(token: str) -> bool:
    expected = os.getenv("MCP_AUTH_TOKEN", "")
    return bool(expected) and hmac.compare_digest(token, expected)
```

> **Always use `hmac.compare_digest()`.** `==` and `!=` short-circuit on the first differing byte —
> a timing side channel.

---

## 17. Middleware

### 17.1 Official SDK v2

One async function wrapping every inbound message:

```python
from mcp.server.context import CallNext, HandlerResult, ServerRequestContext

async def log_timing(ctx: ServerRequestContext, call_next: CallNext) -> HandlerResult:
    start = time.perf_counter()
    try:
        return await call_next(ctx)
    finally:
        logger.info("%s took %.1f ms", ctx.method, (time.perf_counter() - start) * 1000)

mcp = MCPServer("Bookshop", middleware=[log_timing])   # or server.middleware.append(...)
```

> **Provisional.** The signature and semantics may change in a 2.x minor release. Use it to
> *observe* (timing, logging, tracing) and to *refuse* messages. Don't make it your foundation.

- `ctx.method` is the raw method string; `ctx.params` are the raw params **before** validation.
- It wraps **everything**: `server/discover`, `initialize`, requests, notifications, and methods
  with no handler (`call_next` raises `-32601` *through* your middleware).
- `ctx.request_id is None` distinguishes a notification; whatever you return for one is discarded.
- The list runs **outermost-first** — `middleware[0]` is closest to the wire.
- The `try/finally` matters: a handler that raises still reaches you as an exception out of
  `call_next`.

**What you can do**, in increasing order of hesitation:
1. **Observe.**
2. **Refuse** — raise `MCPError` *instead of* calling `call_next`. That one message gets an error;
   the connection survives. This is how you gate `subscriptions/listen` per caller
   ([§10.9](#109-subscriptions)).
3. **Rewrite** — `await call_next(dataclasses.replace(ctx, params=...))`. **Never on `initialize`**:
   the client's result is built from your rewritten params while the server commits connection state
   from the original wire params, so both sides finish the handshake disagreeing.
4. **Answer** — return a result without calling `call_next`. The pipeline never patches what you
   return, so the whole envelope is yours — including the `serverInfo` `_meta` stamp the SDK adds to
   *handler* results but not to yours.

> `initialize` is handled **inline** — the server reads no further inbound messages until your chain
> returns. Awaiting a server→client request while handling it **deadlocks the connection**.
> Fire-and-forget notifications are fine. You also can't claim it with `add_request_handler`;
> middleware is the only hook.

The SDK ships exactly one middleware, already on your list: the OpenTelemetry span emitter. It's a
no-op until you install an exporter.

### 17.2 FastMCP

```python
from fastmcp.server.middleware.logging import LoggingMiddleware
from fastmcp.server.middleware.rate_limiting import RateLimitingMiddleware
from fastmcp.server.middleware.error_handling import ErrorHandlingMiddleware

mcp.add_middleware(LoggingMiddleware(include_payloads=True, max_payload_length=1000))
mcp.add_middleware(RateLimitingMiddleware(max_requests_per_second=10.0, burst_capacity=20))
mcp.add_middleware(ErrorHandlingMiddleware(include_traceback=True))

class Guard(Middleware):
    async def on_call_tool(self, ctx: MiddlewareContext, call_next):
        if ctx.message.name == "danger":
            raise ToolError("denied")
        return await call_next(ctx)
```

Hooks: `on_message`, `on_request`, `on_notification`, `on_call_tool`, `on_read_resource`,
`on_get_prompt`, `on_list_tools`, `on_list_resources`, `on_list_prompts`,
`on_list_resource_templates`. **`on_initialize` does not survive a modern connection** in 4.0, and
`on_message` now sees every inbound message, not only routable requests.

---

## 18. Server Composition

FastMCP only — the official SDK doesn't provide composition. (Its answer to "several servers in one
process" is several ASGI mounts, [§10.10](#1010-asgi--mounting).)

```python
# Mount — in-process and live: tools added to `weather` later show up on `main`
main = FastMCP("Main")
main.mount(weather)
main.mount(calendar, namespace="cal")

# Proxy a remote or stdio server
from fastmcp.server import create_proxy
proxy = create_proxy("http://example.com/mcp", name="P")
proxy = create_proxy("local_server.py")
proxy = create_proxy({"mcpServers": {
    "weather": {"url": "https://...", "transport": "http"},
    "fs": {"command": "uvx", "args": ["mcp-server-filesystem", "/data"]},
}})

# OpenAPI → MCP  (GET routes become resources by default; other methods become tools)
mcp = FastMCP.from_openapi(openapi_spec=spec,
                           client=httpx.AsyncClient(base_url="https://api.example.com"),
                           route_maps=[RouteMap(methods=["GET"], pattern=r"^/users/.*",
                                                mcp_type=MCPType.RESOURCE)])

# FastAPI → MCP
mcp = FastMCP.from_fastapi(app=app, name="MyAPI")
```

> **`import_server()` and `as_proxy()` are removed in 4.0.** `mount()` is the replacement for
> `import_server()` but **not** an equivalent: `import_server` took a static snapshot and skipped
> the child's lifespan and middleware; `mount()` is a live composition that runs both. `mount()` no
> longer accepts `prefix=` or `as_proxy=`. In 4.0 a proxy mirrors the frontend's protocol era on its
> backend connection.

---

## 19. HTTP Client Best Practices

### 19.1 Shared async client via lifespan

```python
@asynccontextmanager
async def lifespan(server):
    async with httpx.AsyncClient(timeout=30.0) as client:
        yield {"http_client": client}
```

A module-level `httpx.AsyncClient()` leaks connections. Don't.

> On SDK v2 the *client* side is `httpx2`. Your own outbound calls can use whichever you like — just
> don't confuse the two in `except` clauses ([§10.12](#1012-silent-behavior-changes-when-upgrading-from-v1)).

### 19.2 Rate limiting

```python
import asyncio, time

_last, _lock, INTERVAL = 0.0, asyncio.Lock(), 0.2   # 5 req/s

async def rate_limit():
    global _last
    async with _lock:
        elapsed = time.time() - _last
        if elapsed < INTERVAL:
            await asyncio.sleep(INTERVAL - elapsed)
        _last = time.time()
```

### 19.3 Retry with exponential backoff

```python
MAX_RETRIES = 3

async def api_request_with_retry(http, method, url, **kw):
    for attempt in range(MAX_RETRIES + 1):
        try:
            r = await http.request(method, url, **kw)
            if r.status_code == 429:
                await asyncio.sleep(min(int(r.headers.get("Retry-After", 2 ** attempt)), 30))
                continue
            r.raise_for_status()
            return r.json()
        except httpx.TimeoutException:
            if attempt == MAX_RETRIES:
                return {"error": "timeout"}
            await asyncio.sleep(2 ** attempt)
        except httpx.HTTPStatusError as e:
            return {"error": f"HTTP {e.response.status_code}",
                    "status_code": e.response.status_code}
    return {"error": "max retries"}
```

### 19.4 Pagination helper

```python
async def fetch_all(http, endpoint, params=None, max_pages=10):
    out = []
    for page in range(1, max_pages + 1):
        data = (await http.get(endpoint,
                params={**(params or {}), "page": page, "per_page": 100})).json()
        items = data.get("items") or data.get("results") or []
        if not items:
            break
        out.extend(items)
        if len(items) < 100:
            break
    return out
```

---

## 20. Error Handling

### 20.1 Two levels

**Protocol error** (JSON-RPC `error`) — bad JSON, unknown method, unsupported version, missing
capability, header mismatch, invalid `requestState`:

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
```

**Tool execution error** (the tool ran and failed) — API errors, validation, business logic:

```json
{"jsonrpc":"2.0","id":1,"result":{
  "resultType":"complete",
  "content":[{"type":"text","text":"Error: API returned 503"}],
  "isError":true}}
```

Tool **input-validation** failures belong in the second bucket so the model can self-correct — a
rule introduced in `2025-11-25` and unchanged here.

### 20.2 Choosing

**Could a smarter model have avoided this?**
- **Yes** → ordinary exception → `isError: true`. A misspelled title, an upstream timeout, a missing
  row. The model reads the message and retries.
- **No** → protocol error. A capability the client didn't declare, a server not in a state to serve
  anyone, a skipped required step. No retry fixes it, so there's nothing to gain from telling the
  model.

> **Never `return` an error string.** `isError=False` makes it look like the answer.

### 20.3 Client side

```python
result = await client.call_tool("search", {"query": "test"})
if result.is_error:
    print(result.content[0].text)     # the model-readable message
else:
    print(result.structured_content)
```

`is_error=True` covers more than your own `raise` — an unknown tool name lands here too. A `Client`
method raises `MCPError` only when the server answered with a JSON-RPC **error** instead of a result.

---

## 21. Security

### 21.1 Spec requirements (2026-07-28)

1. **HTTPS** for all production endpoints and non-localhost OAuth redirects.
2. **Origin validation** on Streamable HTTP — invalid → **HTTP 403**.
3. **Bind localhost** (`127.0.0.1`) locally; `0.0.0.0` only behind a trusted proxy.
4. **Authentication** for all non-stdio connections.
5. **Validate all tool inputs.** Never trust client params — or headers.
6. **Validate headers against the body** — `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*`,
   `MCP-Protocol-Version`. Mismatch → `400` + `-32020`. This exists precisely because an
   intermediary may route on the header while the server acts on the body.
7. **Rate limit** inbound MCP and outbound upstream calls.
8. **Sanitize error output.** Log details server-side, return generic messages. `MCPError` is
   forwarded verbatim — put nothing internal in it.
9. **Constant-time token compare** — `hmac.compare_digest()`.
10. **No token passthrough.** A server MUST NOT forward client-issued tokens to upstream APIs, and
    MUST validate the audience of every token it accepts.
11. **Integrity-protect `requestState`** and reject the round on failure ([§7.2](#72-requeststate-is-client-supplied-input)).
12. **URL elicitation**: never auto-open or pre-fetch; display the full URL; open in an isolated
    context (`SFSafariViewController`, not an embedded WebView); highlight the domain; warn on
    Punycode.
13. **Icons and `$ref`s are untrusted input** (§2.4, §2.5).
14. **`cacheScope` is not an access control.** A `"public"` result from an authenticated endpoint may
    be shared across access tokens — enforce per-primitive authorization independently (§9).

### 21.2 What statelessness changed

- **There is no session to bind to a user.** The old advice ("bind sessions to user info to prevent
  hijacking", "use non-deterministic session IDs") no longer applies on the modern wire — there are
  no sessions. It still applies to the legacy leg (Appendix A).
- The replacement surface is **`requestState`**, and it is the thing an attacker now targets: it is
  client-supplied, persistable, and replayable. Seal it, bind it to the principal and the originating
  request, and give it a TTL.
- **Any handle you mint** and pass back as a tool argument is now security-relevant. It is
  indistinguishable, to the server, from something the model made up. Treat every handle as
  untrusted input and re-authorize on use.
- **Subscription filters are a separate authorization decision** from resource reads
  ([§10.9](#109-subscriptions)).

### 21.3 Confused deputy

Servers MUST require per-client consent before forwarding requests to third parties. Proxy servers
with static upstream client IDs MUST obtain user consent per dynamic client — this is what
`OAuthProxy(require_authorization_consent=True)` implements.

### 21.4 Input validation

```python
limit = max(1, min(args.get("limit", 10), 50))       # clamp numerics

valid = {"relevance", "date_desc", "date_asc"}        # validate enums
sort = args.get("sort", "relevance")
if sort not in valid:
    sort = "relevance"

q = args.get("query", "").strip()                     # reject empty required
if not q:
    raise ValueError("query is required")
```

> **HTTP headers are client-supplied input**, exactly like a tool argument. Fine for a locale or a
> feature flag. **Never an identity** — that comes from your authorization layer.

### 21.5 Human in the loop

Clients SHOULD show tool inputs before calling, prompt for confirmation on destructive operations,
display tool-invocation indicators, and log usage. Tool **annotations are untrusted** unless the
server itself is trusted — they're UX hints, not a security boundary.

---

## 22. Deployment

### 22.1 The go-live gate: the Host allowlist

With no `transport_security=`, the SDK's app arms DNS-rebinding protection with a localhost-only
allowlist. Behind a real hostname that rejects **every request** before anything MCP-shaped runs:

```text
421 Misdirected Request    Invalid Host header
403 Forbidden              Invalid Origin header
```

```python
from mcp.server.transport_security import TransportSecuritySettings

security = TransportSecuritySettings(
    allowed_hosts=["mcp.example.com", "mcp.example.com:*"],   # list BOTH forms
    allowed_origins=["https://app.example.com"],
)
app = mcp.streamable_http_app(transport_security=security)
```

- `allowed_hosts` entries are exact strings; `"host"` matches a bare `Host`, `"host:*"` any port.
- `allowed_origins` only matters for browsers — nothing else sends `Origin`.
- Behind a proxy that already controls `Host`, turning the check off is the honest configuration:
  `TransportSecuritySettings(enable_dns_rebinding_protection=False)`.
- **Passing a non-localhost `host=` does not allowlist it.** It only stops the localhost default from
  arming the protection, leaving every Host and Origin accepted. Say what you mean with
  `transport_security=`.

> A `421` is plain-text HTTP, not a JSON-RPC error, so the client raises a generic transport error
> and the hostname appears only in **your** log as one warning. *A freshly deployed server that
> refuses every connection is a Host allowlist until proven otherwise.*

### 22.2 Scaling

```console
uvicorn server:app --workers 4
```

| Client's protocol version | Session | What the load balancer must do |
|---|---|---|
| **2026-07-28** | none | **Nothing.** Any worker serves any request. |
| **2025-11-25 and earlier** (default) | in-process `Mcp-Session-Id` | **Sticky sessions**, or `404 Session not found` |
| **2025-11-25 and earlier**, `stateless_http=True` | none | Nothing — at the cost of both back-channels |

Two things statelessness does **not** buy you:

1. **`requestState` across workers** — see [§10.7](#107-mrtr-in-the-sdk). *Same keys, same name.*
   This is the number-one cause of a multi-round-trip tool that worked on one worker and fails
   intermittently on four.
2. **Change notifications across replicas** — a listen stream is pinned to its replica; a publish
   elsewhere needs a shared `SubscriptionBus` ([§10.9](#109-subscriptions)).

**What the SDK deliberately does not give you:** no `workers=` (hand `streamable_http_app()` to
uvicorn/gunicorn), no health route (`@mcp.custom_route("/health", …)` — unauthenticated by design),
no production settings object (timeouts, TLS, graceful shutdown belong to your ASGI server), and no
shipped `EventStore` — on `2026-07-28` there's nothing to resume.

### 22.3 CORS for browser clients

```python
app = Starlette(
    routes=[Mount("/", app=mcp.streamable_http_app(transport_security=security))],
    middleware=[Middleware(
        CORSMiddleware,
        allow_origins=["https://app.example.com"],
        allow_methods=["GET", "POST", "DELETE"],
        allow_headers=["Authorization", "Content-Type",
                       "Mcp-Method", "Mcp-Name", "Mcp-Protocol-Version",
                       "Mcp-Session-Id", "Last-Event-ID"],   # last two: legacy leg only
        expose_headers=["Mcp-Session-Id"],
    )],
    lifespan=lifespan,
)
```

- **`allow_headers` is the half everyone forgets.** Browsers preflight every MCP request (JSON
  content type + `Mcp-*` headers aren't on the CORS safelist), and a header the preflight doesn't
  grant is a request the browser never sends. Add `Mcp-Param-*` names too if you use
  `x-mcp-header`.
- `expose_headers` matters only for the legacy leg; a modern connection has no session header to read.
- **Mirror `allow_origins` in `allowed_origins=`.** The browser enforces CORS, but the server checks
  `Origin` itself — an origin the transport doesn't trust gets a `403` after a perfectly clean
  preflight.

### 22.4 Dockerfile

```dockerfile
FROM python:3.12-slim

RUN groupadd -r mcp && useradd -r -g mcp -s /sbin/nologin mcp
WORKDIR /app

COPY pyproject.toml .
RUN pip install --no-cache-dir .
COPY . .

USER mcp
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]
```

`.dockerignore`:

```
.env
.env.*
.git
__pycache__
*.pyc
.venv
node_modules
*.md
.mypy_cache
.pytest_cache
```

`docker-compose.yml`:

```yaml
services:
  my-api-mcp:
    build: ./my-api-mcp
    ports:
      - "127.0.0.1:8000:8000"     # localhost-bound; expose via reverse proxy
    environment:
      REQUEST_STATE_KEY: ${REQUEST_STATE_KEY}   # same value across every replica (§10.7)
    env_file: [.env]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 30s
      timeout: 3s
      retries: 3
```

---

## 23. Testing

### 23.1 In-memory (preferred)

```python
import pytest
from mcp import Client
from server import mcp

@pytest.fixture
def anyio_backend():
    return "asyncio"

@pytest.fixture
async def client():
    async with Client(mcp, raise_exceptions=True) as c:
        yield c

@pytest.mark.anyio
async def test_search(client: Client):
    result = await client.call_tool("search_items", {"query": "test"})
    assert not result.is_error
    assert result.structured_content == {"result": ...}

@pytest.mark.anyio
async def test_unknown(client: Client):
    result = await client.call_tool("nope", {})
    assert result.is_error
```

No subprocess, no port — but the call still goes through the real protocol layer: listed, validated,
invoked exactly as over HTTP. `Client(server)` takes a low-level `Server` the same way.

Results carry the `serverInfo` `_meta` stamp; set `result.meta = None` before a whole-object
snapshot assertion.

> `raise_exceptions=True` only affects in-memory connections, and **does not** turn a tool error back
> into a traceback — by the time it could act, your exception is already the `is_error=True` result.
> Assert on the result. It surfaces *handler* exceptions on the low-level `Server`, where a `KeyError`
> would otherwise be an opaque `-32603`.

Turn deprecation into a regression test — add to your pytest config:

```ini
filterwarnings = error::mcp.MCPDeprecationWarning
```

Now any call to a deprecated API fails a test instead of quietly warning.

### 23.2 curl

```bash
# server/discover
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: server/discover" \
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{
        "io.modelcontextprotocol/protocolVersion":"2026-07-28",
        "io.modelcontextprotocol/clientInfo":{"name":"curl","version":"1.0"},
        "io.modelcontextprotocol/clientCapabilities":{}}}}' | jq .

# tools/call — note Mcp-Name MUST match params.name
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: search_items" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
        "name":"search_items","arguments":{"query":"test"},
        "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
                 "io.modelcontextprotocol/clientCapabilities":{}}}}'
```

A `mcp` 2.0.0 server answers a modern request with plain `Content-Type: application/json`:

```json
{"jsonrpc":"2.0","id":3,"result":{
  "content":[{"text":"Hello, Ventz!","type":"text"}],
  "isError":false,
  "resultType":"complete",
  "structuredContent":{"result":"Hello, Ventz!"},
  "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"my-api-mcp","version":"1.0.0"}}}}
```

The spec lets a server answer either way (§4.2), so a client MUST handle `text/event-stream`
framing (`event: message\ndata: {...}`) too — a server switches to it whenever it wants to stream
progress before the response.

**Negative tests worth having in CI** (expected values verified against `mcp` 2.0.0):

```bash
# Header/body mismatch → 400 + -32020
#   "mcp-name header does not match the request body's 'name' parameter"
# Unsupported version → 400 + -32022 with data.supported[]
# Unknown method (e.g. ping) → 404 + -32601
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8000/mcp \
     -H 'Origin: https://evil.example' ...          # 403 "Invalid Origin header"

# GET/DELETE: 405 only on a modern-ONLY server. The dual-era SDK answers 400
# (its legacy routes still exist and find no session id).
curl -s -o /dev/null -w '%{http_code}\n' -X GET http://localhost:8000/mcp
```

### 23.3 MCP Inspector

```bash
uv run mcp dev server.py                     # official SDK — launches the Inspector
npx @modelcontextprotocol/inspector uv run my-server     # stdio
npx @modelcontextprotocol/inspector          # HTTP: launch the UI, paste the URL
fastmcp dev inspector server.py              # FastMCP
```

`mcp dev` and `mcp run` only understand `MCPServer` — a low-level `Server` you run yourself.

### 23.4 LibreChat config

```yaml
mcpServers:
  my-api:
    type: streamableHttp
    url: http://my-api-mcp:8000/mcp
    allowedDomains:
      - my-api-mcp
    serverInstructions: |
      Use the search_items tool to search for resources.
```

> Check which protocol era your host speaks before assuming. Hosts that still send `initialize` are
> served by the legacy leg ([§10.11](#1011-serving-legacy-clients)) — which means sticky routing if
> you run more than one worker.

---

## 24. CLI Tools & Inspector

### Official SDK (`mcp[cli]`)

```bash
uv run mcp dev server.py                  # run under the MCP Inspector
uv run mcp dev server.py --with pandas    # add packages to the built environment
uv run mcp dev server.py --with-editable .
uv run mcp run server.py                  # import the file, find mcp/server/app, call run()
uv run mcp run server.py:bookshop         # name the object explicitly
uv run mcp install server.py --name "Bookshop" -v API_KEY=abc -f .env
uv run mcp version
```

`mcp dev` needs `npx` on `PATH` (the Inspector is a Node app). `mcp run` calls `run()` itself, so
your `if __name__ == "__main__":` block never executes and only `--transport` is forwarded.
`mcp install` knows **only** Claude Desktop; every other host takes the same launch command in its
own config file.

### FastMCP

```bash
fastmcp run <server>             # local file, factory, URL, or config
fastmcp dev inspector <server>   # MCP Inspector
fastmcp install <server>         # Claude Code, Claude Desktop, Cursor, Gemini CLI, Goose
fastmcp inspect <server>         # tools/resources/prompts summary
fastmcp list <server>
fastmcp call <server> <tool> ...
fastmcp discover                 # find configured MCP servers in editors
fastmcp generate-cli <server>    # scaffold a typed CLI from tool schemas
fastmcp project prepare
fastmcp auth cimd ...            # create/validate CIMD OAuth documents
fastmcp version
```

---
## 25. Checklist

### Protocol compliance (server)

- [ ] `protocolVersion` is `2026-07-28`
- [ ] **`server/discover` is implemented** (MUST)
- [ ] Every result carries **`resultType`** (`"complete"` unless it's MRTR)
- [ ] Every result's `_meta` carries `io.modelcontextprotocol/serverInfo` (SHOULD)
- [ ] Required `_meta` fields validated → missing = `-32602` + HTTP `400`
- [ ] Unsupported version → **`-32022`** with `data.supported[]` + `400`
- [ ] Undeclared client capability → **`-32021`** with `data.requiredCapabilities` + `400`
- [ ] `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` validated against the body →
      **`-32020`** + `400`; base64 sentinel decoded before comparing
- [ ] `x-mcp-header` params mirrored & validated, if used
- [ ] Single `POST /mcp`; `GET`/`DELETE` → **`405`** *if you serve only this revision* (a dual-era
      server keeps its legacy routes)
- [ ] No `Mcp-Session-Id` minted or echoed; `Last-Event-ID` ignored
- [ ] Invalid `Origin` → **`403`**
- [ ] Notifications → `202` with empty body
- [ ] Unknown method → `404` + `-32601`
- [ ] Cacheable results carry **`ttlMs` and `cacheScope`** (`server/discover`, `tools/list`,
      `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read`)
- [ ] MRTR-retry results (`inputResponses`/`requestState` present) are **not** cached
- [ ] `tools/list` returned in a **deterministic order**
- [ ] Unknown tool → `isError: true`, not a protocol error
- [ ] Tool input-validation failures → `isError: true`
- [ ] Invalid JSON → `-32700`; resource-not-found → `-32602` (**never** `-32002`)
- [ ] `subscriptions/listen`: acknowledgment first, `subscriptionId` on every frame, filter honored
      exactly, keep-alive comments on quiet streams, graceful-close response on server teardown
- [ ] `requestState` is integrity-protected and rejected on failure
- [ ] Server→client requests are **never** sent — MRTR only
- [ ] `ping` is not implemented

### Tool quality

- [ ] Every tool has a 50–150 word description
- [ ] Every parameter has a description
- [ ] Required params in `required`; optional params have defaults; enums use `enum`/`Literal`
- [ ] Input validation before upstream calls
- [ ] Annotations set where applicable (`readOnlyHint`, `destructiveHint`, `idempotentHint`,
      `openWorldHint`) — and treated as UX hints, never a security boundary
- [ ] `outputSchema` declared where structured output is promised — and actually satisfied
- [ ] Icons set where useful, from HTTPS or `data:` URIs

### Server features

- [ ] `/health` endpoint (unauthenticated by design — nothing private behind it)
- [ ] Rate limiting (inbound MCP + outbound upstream)
- [ ] 30s default HTTP timeout for upstream calls
- [ ] Structured errors, no raw tracebacks outside dev
- [ ] Logging via `logging` to stderr / OpenTelemetry — **not** MCP protocol logging
- [ ] Env-based config, no hardcoded secrets
- [ ] Dockerfile with healthcheck, non-root user
- [ ] CORS configured if serving browser clients (incl. `Mcp-Method`, `Mcp-Name`,
      `Mcp-Protocol-Version` in `allow_headers`)
- [ ] `transport_security=` allowlist set before go-live (else every request is a `421`)

### Multi-worker / multi-instance

- [ ] `RequestStateSecurity(keys=[...])` shared across every instance (≥32 bytes)
- [ ] **Same server `name`** on every instance, or an explicit `audience=`
- [ ] Key rotation plan (`[OLD,NEW]` → `[NEW,OLD]` → `[NEW]`, one TTL apart)
- [ ] A shared `SubscriptionBus` if you publish change notifications
- [ ] Sticky routing **if** you serve legacy clients without `stateless_http=True`

### Client features

- [ ] Per-request `_meta`: `protocolVersion` + `clientCapabilities` (+ `clientInfo`)
- [ ] `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` headers matching the body
- [ ] `x-mcp-header` support (MUST) — including rejecting tools with invalid annotations
- [ ] Handles `resultType`; absent ⇒ `"complete"`; unknown ⇒ invalid
- [ ] MRTR loop implemented and **bounded**, with backoff on empty `inputRequests`
- [ ] Elicitation callback (form **and** URL modes); URL mode: display the full URL, isolated open,
      **no** pre-fetch, warn on Punycode
- [ ] Era detection cached per server, with `initialize` fallback — body-inspected, not
      status-code-keyed
- [ ] Tool-error handling (`isError: true`) distinct from JSON-RPC errors
- [ ] Cache honoring `ttlMs`/`cacheScope`; never cache MRTR-retry results; never share a `"private"`
      result across authorization contexts
- [ ] `subscriptions/listen` demultiplexed by `subscriptionId`; re-listen and refetch after a drop
- [ ] Configurable timeouts (remember: the read timeout must tolerate a long-held response stream)
- [ ] OAuth: PKCE `S256`, `resource=` on **both** authorization and token requests, `iss` validated
      per RFC 9207 without normalization, credentials keyed by issuer, `application_type` on DCR

---

## Appendix A — Legacy (2025-11-25 era)

Everything here is **removed from `2026-07-28`**. You need it only to interoperate with hosts that
haven't migrated. On the official SDK v2 this leg is served automatically
([§10.11](#1011-serving-legacy-clients)) and you write none of it.

### A.1 The initialize handshake

```
Client                              Server
  ├──── POST initialize ─────────────►│
  │◄─── InitializeResult ─────────────┤   (server MAY set the Mcp-Session-Id header)
  ├──── POST notifications/initialized ─►│
  │◄─── 202 Accepted ─────────────────┤
```

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
  "protocolVersion":"2025-11-25",
  "capabilities":{"roots":{"listChanged":true},"sampling":{},
                  "elicitation":{"form":{},"url":{}}},
  "clientInfo":{"name":"ExampleClient","title":"Example Client","version":"1.0.0"}}}
```

```json
{"jsonrpc":"2.0","id":1,"result":{
  "protocolVersion":"2025-11-25",
  "capabilities":{"logging":{},"prompts":{"listChanged":true},
                  "resources":{"subscribe":true,"listChanged":true},
                  "tools":{"listChanged":true}},
  "serverInfo":{"name":"my-api-mcp","title":"My API","version":"1.0.0"},
  "instructions":"Optional: how/when to use this server"}}
```

Shutdown is transport-level — close stdin or the HTTP connection. There is no shutdown RPC.

### A.2 Sessions

- The server assigns `Mcp-Session-Id` on the `InitializeResult` response header.
- IDs MUST be cryptographically secure and visible-ASCII (0x21–0x7E) — UUID, JWT, or hash.
- Missing on a post-init request → **HTTP 400**. Invalid/expired → **HTTP 404** ("Session not
  found"), and the client must re-initialize.
- `DELETE /mcp` with the session id terminates it → `200` empty body, or `405` if unsupported.
- **Bind sessions to user info** to prevent hijacking. (This advice has no modern equivalent —
  there are no sessions.)

### A.3 The GET stream

`GET /mcp` opens a long-lived SSE stream for server-initiated messages.
`Accept: text/event-stream` required → `406` otherwise. `Mcp-Session-Id` required → `400` missing,
`404` invalid. Resumable via `Last-Event-ID`, which the server answers by replaying missed events.
Polling SSE (2025-11-25): the server MAY close at will and the client reconnects with
`Last-Event-ID`.

### A.4 Server-initiated requests

On a legacy session the server may open its own request to the client mid-call:

```python
result = await ctx.elicit("Delete {target}?", response_type=ConfirmAction)  # elicitation/create
sampled = await ctx.sample("Summarize this", temperature=0.7)              # sampling/createMessage
roots   = await ctx.session.list_roots()                                   # roots/list
```

Actions on an elicitation result: `"accept"`, `"decline"`, `"cancel"`. URL-mode elicitation used
`elicitation_id` plus a `notifications/elicitation/complete` notification and the `-32042`
`URLElicitationRequiredError` — **all three are gone** in 2026-07-28.

This channel needs a stream to push down. It does not exist on a modern connection, and it does not
exist on a legacy connection served with `stateless_http=True` or `json_response=True` — those raise
`NoBackChannelError`.

### A.5 Other legacy-only behavior

- `ping` → `{}`.
- `logging/setLevel` and `notifications/message` as a protocol-level logging channel.
- `resources/subscribe` / `resources/unsubscribe` per URI, delivered on the session's standalone
  stream via `ctx.session.send_resource_updated(uri)` and `send_*_list_changed()`.
- Resource-not-found is `-32002`.
- Results have **no** `resultType` and **no** cache hints.
- The HTTP+SSE transport (2024-11-05) — deprecated since `2025-03-26`; the old `endpoint` SSE event
  identifies such a server.

### A.6 Interop rules of thumb

- A **modern-only server** meeting old traffic: `405` on GET/DELETE, ignore `Mcp-Session-Id`, ignore
  `Last-Event-ID`, and name your supported versions in the error you return to `initialize`.
- A **dual-era client**: probe (stdio: `server/discover`; HTTP: attempt a modern request), inspect the
  body of a `400` before falling back, and cache the era per server.
- A **dual-era server**: modern `_meta` ⇒ stateless; `initialize` ⇒ legacy. Both may run concurrently
  on one endpoint.
- **Publish change notifications twice** — `ctx.notify_*` for modern listeners, `ctx.session.send_*`
  for legacy sessions ([§10.11](#1011-serving-legacy-clients)).

---

## Appendix B — Deprecated Features Registry

Under the [feature lifecycle policy](https://modelcontextprotocol.io/community/feature-lifecycle)
(SEP-2596): a Deprecated feature stays in the spec but is scheduled for removal, with a **minimum
twelve-month** window. New implementations **SHOULD NOT** adopt it; existing ones **SHOULD** migrate
before the earliest removal date. "Earliest removal" is when it becomes *eligible*; actual removal is
a Core Maintainer decision at release time.

| Feature | SEP | Deprecated in | Migration | Earliest removal |
|---|---|---|---|---|
| **Roots** | SEP-2577 | `2026-07-28` | Pass directories/files as tool parameters, resource URIs, or server config | First revision on/after 2027-07-28 |
| **Sampling** | SEP-2577 | `2026-07-28` | Integrate directly with LLM provider APIs | First revision on/after 2027-07-28 |
| **Logging** (MCP-level) | SEP-2577 | `2026-07-28` | `stderr` on stdio; OpenTelemetry for observability | First revision on/after 2027-07-28 |
| **Dynamic Client Registration** | PR #2858 | `2026-07-28` | Client ID Metadata Documents | First revision on/after 2027-07-28 |
| `includeContext: "thisServer"` / `"allServers"` | SEP-2596 | `2025-11-25` | Omit the field or use `"none"` | Follows Sampling |
| **HTTP+SSE transport** | SEP-2596 | `2025-03-26` | Streamable HTTP | Three months after SEP-2596 reaches Final |

Nothing has been **Removed** under this policy yet.

### B.1 In the official SDK

Every deprecated feature still works, and each now emits **`MCPDeprecationWarning`** — which
subclasses `UserWarning`, **not** `DeprecationWarning`, deliberately: Python's default filter hides
`DeprecationWarning` outside `__main__`, which is how libraries deprecate things and nobody notices
for two years. This one shows up everywhere with no `-W` flag.

| Deprecated API | Replacement |
|---|---|
| `ctx.session.list_roots()`, `client.send_roots_list_changed()`, `list_roots_callback=` | Tool arguments / resource URIs, or a `ListRootsRequest` in an `InputRequiredResult` |
| `ctx.session.create_message()`, `sampling_callback=` | `InputRequiredResult` + client retry (MRTR) |
| `ctx.log()` / `debug()` / `info()` / `warning()` / `error()`, `ctx.session.send_log_message()`, `client.set_logging_level()` | `import logging` to stderr |
| `client.send_ping()` | Nothing — **removed** from the protocol, not deprecated |
| `client.send_progress_notification()` | Nothing — progress is server→client only. Servers use `ctx.report_progress()` |

> **"Advisory" stops at the wire.** Sampling and roots are server→client *requests* and a
> `2026-07-28` session has no channel to carry one. On a modern connection you get the warning **and
> then** the failure:
> ```text
> Cannot send 'sampling/createMessage': this transport context has no back-channel
> for server-initiated requests.
> ```
> They work end-to-end only on a `mode="legacy"` connection whose client registered the callback.

Silence the category in a server that genuinely serves pre-2026 clients:

```python
import warnings
from mcp import MCPDeprecationWarning
warnings.filterwarnings("ignore", category=MCPDeprecationWarning)
```

Or invert it in tests — see [§23.1](#231-in-memory-preferred).

---

## 28. Reference Links

### Spec (2026-07-28)

- [Specification](https://modelcontextprotocol.io/specification/2026-07-28) ·
  [**Changelog**](https://modelcontextprotocol.io/specification/2026-07-28/changelog) ·
  [Schema reference](https://modelcontextprotocol.io/specification/2026-07-28/schema)
- Base: [Overview & error codes](https://modelcontextprotocol.io/specification/2026-07-28/basic/index) ·
  [Versioning & Compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
- Transports: [Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http) ·
  [stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
- Patterns: [MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr) ·
  [Subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions) ·
  [Cancellation](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation) ·
  [Progress](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/progress)
- Authorization: [Overview](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/index) ·
  [AS discovery](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery) ·
  [Client registration (CIMD)](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration) ·
  [Security considerations](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations)
- Server: [Discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover) ·
  [Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools) ·
  [Resources](https://modelcontextprotocol.io/specification/2026-07-28/server/resources) ·
  [Prompts](https://modelcontextprotocol.io/specification/2026-07-28/server/prompts) ·
  [Caching](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching) ·
  [Pagination](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/pagination) ·
  [Completion](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/completion)
- Client: [Elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation) ·
  [Roots *(deprecated)*](https://modelcontextprotocol.io/specification/2026-07-28/client/roots) ·
  [Sampling *(deprecated)*](https://modelcontextprotocol.io/specification/2026-07-28/client/sampling)
- [**Deprecated features registry**](https://modelcontextprotocol.io/specification/2026-07-28/deprecated) ·
  [Feature lifecycle policy](https://modelcontextprotocol.io/community/feature-lifecycle)
- Extensions: [Overview](https://modelcontextprotocol.io/extensions/overview) ·
  [Tasks](https://modelcontextprotocol.io/extensions/tasks/overview) ·
  [MCP Apps](https://modelcontextprotocol.io/extensions/apps/overview)
- Guides: [Intro](https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro) ·
  [Architecture](https://modelcontextprotocol.io/docs/2026-07-28/learn/architecture) ·
  [Security best practices](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices) ·
  [Client best practices](https://modelcontextprotocol.io/docs/2026-07-28/develop/clients/client-best-practices)
- [Prior revision: 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25)

> Every `modelcontextprotocol.io` page serves plain markdown at the same URL with a `.md` suffix.
> The full index is [`llms.txt`](https://modelcontextprotocol.io/llms.txt).

### Normative sources

Prose can lag. When a detail matters, go to the source — clone the two repos and read them.

| Source | What's authoritative in it |
|---|---|
| `modelcontextprotocol/schema/2026-07-28/schema.ts` | **The source of truth** for every message shape and error code. `schema.json` is generated from it. |
| `modelcontextprotocol/seps/` | The design rationale: `2243` (HTTP headers), `2322` (MRTR), `2549` (cache TTL), `2567` (sessionless), `2575` (stateless), `2577` (deprecations), `2596` (feature lifecycle), `2663` (tasks extension) |
| `python-sdk/src/mcp/server/mcpserver/` | `MCPServer` itself. `src/mcp/server/lowlevel/` is the low-level `Server`. There is **no** `fastmcp/` directory in v2. |

```bash
git clone https://github.com/modelcontextprotocol/modelcontextprotocol
git clone https://github.com/modelcontextprotocol/python-sdk
rg 'export const.*= -320' modelcontextprotocol/schema/2026-07-28/schema.ts   # error codes
rg -A20 'interface CacheableResult' modelcontextprotocol/schema/2026-07-28/schema.ts
```

- [Spec repo](https://github.com/modelcontextprotocol/modelcontextprotocol) ·
  [`schema.ts` (2026-07-28)](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2026-07-28/schema.ts)

### Official Python SDK v2

- [Docs home](https://py.sdk.modelcontextprotocol.io/) ·
  [`llms.txt` index](https://py.sdk.modelcontextprotocol.io/llms.txt) ·
  [GitHub](https://github.com/modelcontextprotocol/python-sdk) ·
  [PyPI](https://pypi.org/project/mcp/)
- [**What's new in v2**](https://py.sdk.modelcontextprotocol.io/whats-new/) ·
  [**Migration guide**](https://py.sdk.modelcontextprotocol.io/migration/) ·
  [Protocol versions](https://py.sdk.modelcontextprotocol.io/protocol-versions/) ·
  [Deprecated](https://py.sdk.modelcontextprotocol.io/deprecated/) ·
  [Troubleshooting](https://py.sdk.modelcontextprotocol.io/troubleshooting/)
- Servers: [Tools](https://py.sdk.modelcontextprotocol.io/servers/tools/) ·
  [Structured output](https://py.sdk.modelcontextprotocol.io/servers/structured-output/) ·
  [Resources](https://py.sdk.modelcontextprotocol.io/servers/resources/) ·
  [URI templates](https://py.sdk.modelcontextprotocol.io/servers/uri-templates/) ·
  [Prompts](https://py.sdk.modelcontextprotocol.io/servers/prompts/) ·
  [Completions](https://py.sdk.modelcontextprotocol.io/servers/completions/) ·
  [Media & icons](https://py.sdk.modelcontextprotocol.io/servers/media/) ·
  [Handling errors](https://py.sdk.modelcontextprotocol.io/servers/handling-errors/)
- Handlers: [Context](https://py.sdk.modelcontextprotocol.io/handlers/context/) ·
  [Dependencies](https://py.sdk.modelcontextprotocol.io/handlers/dependencies/) ·
  [Lifespan](https://py.sdk.modelcontextprotocol.io/handlers/lifespan/) ·
  [Elicitation](https://py.sdk.modelcontextprotocol.io/handlers/elicitation/) ·
  [**Multi-round-trip requests**](https://py.sdk.modelcontextprotocol.io/handlers/multi-round-trip/) ·
  [Sampling & roots](https://py.sdk.modelcontextprotocol.io/handlers/sampling-and-roots/) ·
  [Progress](https://py.sdk.modelcontextprotocol.io/handlers/progress/) ·
  [Logging](https://py.sdk.modelcontextprotocol.io/handlers/logging/) ·
  [Subscriptions](https://py.sdk.modelcontextprotocol.io/handlers/subscriptions/)
- Running: [Overview](https://py.sdk.modelcontextprotocol.io/run/) ·
  [ASGI](https://py.sdk.modelcontextprotocol.io/run/asgi/) ·
  [**Deploy & scale**](https://py.sdk.modelcontextprotocol.io/run/deploy/) ·
  [Authorization](https://py.sdk.modelcontextprotocol.io/run/authorization/) ·
  [OpenTelemetry](https://py.sdk.modelcontextprotocol.io/run/opentelemetry/) ·
  [**Serving legacy clients**](https://py.sdk.modelcontextprotocol.io/run/legacy-clients/)
- Clients: [The Client](https://py.sdk.modelcontextprotocol.io/client/) ·
  [Callbacks](https://py.sdk.modelcontextprotocol.io/client/callbacks/) ·
  [Transports](https://py.sdk.modelcontextprotocol.io/client/transports/) ·
  [OAuth](https://py.sdk.modelcontextprotocol.io/client/oauth-clients/) ·
  [Identity assertion](https://py.sdk.modelcontextprotocol.io/client/identity-assertion/) ·
  [Multiple servers](https://py.sdk.modelcontextprotocol.io/client/session-groups/) ·
  [Subscriptions](https://py.sdk.modelcontextprotocol.io/client/subscriptions/) ·
  [Caching](https://py.sdk.modelcontextprotocol.io/client/caching/)
- Advanced: [Low-level Server](https://py.sdk.modelcontextprotocol.io/advanced/low-level-server/) ·
  [Pagination](https://py.sdk.modelcontextprotocol.io/advanced/pagination/) ·
  [Middleware](https://py.sdk.modelcontextprotocol.io/advanced/middleware/) ·
  [Extensions](https://py.sdk.modelcontextprotocol.io/advanced/extensions/) ·
  [MCP Apps](https://py.sdk.modelcontextprotocol.io/advanced/apps/)
- API reference: [`mcp`](https://py.sdk.modelcontextprotocol.io/api/mcp/) ·
  [`mcp-types`](https://py.sdk.modelcontextprotocol.io/api/mcp_types/)

> Every `py.sdk.modelcontextprotocol.io` page also serves markdown — append `/index.md`.

### PrefectHQ FastMCP

- [Docs](https://gofastmcp.com) · [LLM-friendly full docs](https://gofastmcp.com/llms-full.txt) ·
  [Changelog](https://gofastmcp.com/changelog.md) · [GitHub](https://github.com/PrefectHQ/fastmcp)
- Upgrading: [**from FastMCP 3**](https://gofastmcp.com/getting-started/upgrading/from-fastmcp-3) ·
  [from FastMCP 2](https://gofastmcp.com/getting-started/upgrading/from-fastmcp-2) ·
  [from MCP SDK v2](https://gofastmcp.com/getting-started/upgrading/from-mcp-sdk-v2) ·
  [from MCP SDK v1](https://gofastmcp.com/getting-started/upgrading/from-mcp-sdk-v1)
- Servers: [Overview](https://gofastmcp.com/servers/server.md) · [Tools](https://gofastmcp.com/servers/tools.md) ·
  [Resources](https://gofastmcp.com/servers/resources.md) · [Prompts](https://gofastmcp.com/servers/prompts.md) ·
  [Context](https://gofastmcp.com/servers/context.md) · [Middleware](https://gofastmcp.com/servers/middleware.md) ·
  [Composition](https://gofastmcp.com/servers/composition.md) · [Proxy](https://gofastmcp.com/servers/proxy.md) ·
  [Storage backends](https://gofastmcp.com/servers/storage-backends.md) ·
  [Telemetry](https://gofastmcp.com/servers/telemetry.md)
- Auth: [Authentication](https://gofastmcp.com/servers/auth/authentication.md) ·
  [Token verification](https://gofastmcp.com/servers/auth/token-verification.md) ·
  [Remote OAuth](https://gofastmcp.com/servers/auth/remote-oauth.md) ·
  [OAuth Proxy](https://gofastmcp.com/servers/auth/oauth-proxy.md) ·
  [OIDC Proxy](https://gofastmcp.com/servers/auth/oidc-proxy.md) ·
  [Multi-auth](https://gofastmcp.com/servers/auth/multi-auth.md)
- Integrations under `/integrations/`: IdPs (`auth0`, `authkit`, `aws-cognito`, `azure`, `descope`,
  `discord`, `github`, `google`, `keycloak`, `propelauth`, `scalekit`, `supabase`), hosts
  (`claude-code`, `claude-desktop`, `cursor`, `chatgpt`, `gemini`, `gemini-cli`, `goose`),
  frameworks (`fastapi`, `openapi`, `anthropic`, `openai`, `pydantic-ai`).

### Other official SDKs

[TypeScript](https://github.com/modelcontextprotocol/typescript-sdk) ·
[Kotlin](https://github.com/modelcontextprotocol/kotlin-sdk) ·
[Java](https://github.com/modelcontextprotocol/java-sdk) ·
[C#](https://github.com/modelcontextprotocol/csharp-sdk) ·
[Swift](https://github.com/modelcontextprotocol/swift-sdk) ·
[Rust](https://github.com/modelcontextprotocol/rust-sdk) ·
[Go](https://github.com/modelcontextprotocol/go-sdk) ·
[Ruby](https://github.com/modelcontextprotocol/ruby-sdk)

### Tools

- [MCP Inspector](https://github.com/modelcontextprotocol/inspector) — `npx @modelcontextprotocol/inspector`
- [Debugging guide](https://modelcontextprotocol.io/docs/2026-07-28/tools/debugging)
