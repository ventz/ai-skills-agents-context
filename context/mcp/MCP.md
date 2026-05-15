# MCP Development Guide (Server & Client)

> By: Ventz Petkov <ventz@vpetkov.net>
> Last updated: 2026-05-13


## Purpose

Single source of truth for building MCP (Model Context Protocol) **servers** and **clients** in Python. Covers:

- **Protocol spec**: `2025-11-25` (latest finalized version)
- **PrefectHQ FastMCP 3.x** — the production-grade Python framework (stable `3.2.4`, beta `3.3.0`)
- **Official Python SDK (`mcp`)** — the reference implementation (latest `1.27.x`)
- Auth, middleware, composition, deployment, security, and testing

---

## Table of Contents

1. [Library Landscape](#1-library-landscape)
2. [Protocol Overview](#2-protocol-overview)
3. [Transport: Streamable HTTP](#3-transport-streamable-http)
4. [Transport: Stdio](#4-transport-stdio)
5. [Lifecycle & Session Management](#5-lifecycle--session-management)
6. [JSON-RPC 2.0 Message Format](#6-json-rpc-20-message-format)
7. [FastMCP Server (PrefectHQ FastMCP 3.x)](#7-fastmcp-server-prefecthq-fastmcp-3x)
8. [Official MCP SDK Server](#8-official-mcp-sdk-server)
9. [Server Template (Raw FastAPI)](#9-server-template-raw-fastapi)
10. [Clients](#10-clients)
11. [Elicitation](#11-elicitation)
12. [Authentication & Authorization](#12-authentication--authorization)
13. [Middleware](#13-middleware)
14. [Server Composition (mount, proxy, OpenAPI)](#14-server-composition-mount-proxy-openapi)
15. [HTTP Client Best Practices](#15-http-client-best-practices)
16. [Error Handling](#16-error-handling)
17. [Security](#17-security)
18. [Dockerfile & Deployment](#18-dockerfile--deployment)
19. [Testing](#19-testing)
20. [CLI Tools & Inspector](#20-cli-tools--inspector)
21. [Checklist](#21-checklist)
22. [Reference Links](#22-reference-links)

---

## 1. Library Landscape

There are **two Python implementations** worth knowing. Pick deliberately — they're related but not the same.

| | **PrefectHQ FastMCP 3.x** | **Official Python SDK (`mcp`)** |
|---|---|---|
| PyPI package | `fastmcp` | `mcp` (CLI extras: `mcp[cli]`) |
| Latest | `3.2.4` stable / `3.3.0b2` beta | `1.27.x` |
| High-level class | `from fastmcp import FastMCP` | `from mcp.server.fastmcp import FastMCP` |
| Spec maintained by | Jeremiah Lowin / Prefect | Anthropic + MCP working group |
| Surface area | Server, Client, OAuth providers, middleware, composition, OpenAPI/FastAPI conversion, CLI, Inspector launcher | Server, Client, low-level `Server` API, transport security |
| Auth providers built in | JWT, Google, GitHub, Azure, Auth0, WorkOS AuthKit, Descope, Keycloak (`KeycloakAuthProvider`), PropelAuth, `OAuthProxy`, `RemoteAuthProvider`, `MultiAuth` | OAuth 2.1 resource-server primitives (`AuthSettings`, `token_verifier`, `TransportSecuritySettings`) |
| Middleware | Built-in system (logging, timing, caching, rate limiting, error handling, ping, response limiting) | None — ASGI middleware if mounted |
| Composition | `mount()`, `create_proxy()`, `FastMCP.from_openapi()` | Not provided |

> **No rename happened.** Earlier rumors of `FastMCP → MCPServer` in the official SDK are unfounded — `mcp.server.fastmcp.FastMCP` is still the high-level class. The class named `MCPServer` does not exist in the released `mcp` package.

**Recommendation:**
- **Production / non-trivial servers** → PrefectHQ **FastMCP 3.x** (`pip install fastmcp`).
- **Minimal servers, reference implementations, or when you want zero non-Anthropic dependencies** → official **`mcp` SDK**.
- **Raw FastAPI** → only when neither library accommodates a custom middleware / CORS / auth requirement.

### Install

```bash
# PrefectHQ FastMCP (recommended)
uv add fastmcp                            # 3.2.4 stable
uv add 'fastmcp==3.3.0b2'                 # 3.3 beta
uv add 'fastmcp-slim[client]'             # 3.3 client-only distribution

# Official Python SDK
uv add 'mcp[cli]'

# Verify
fastmcp version
```

Python ≥ 3.10 for both.

---

## 2. Protocol Overview

MCP uses **JSON-RPC 2.0** over HTTP or stdio. All messages MUST be UTF-8.

**Protocol version**: `2025-11-25` (current finalized)
**Prior versions**: `2025-06-18`, `2025-03-26`, `2024-11-05`

**Architecture (Client-Host-Server):**
- **Hosts** are LLM applications (Claude Desktop, IDEs, LibreChat) that own client connections.
- **Clients** are connectors inside a host — one per server.
- **Servers** expose capabilities to clients.

**Server primitives** (offered to client): Tools, Resources, Prompts.
**Client primitives** (offered to server): Sampling, Roots, Elicitation.
**Utilities**: Logging, Progress, Cancellation, Completion, Ping, Tasks (experimental).

### What's new in 2025-11-25 (vs 2025-06-18)

- **URL elicitation** (SEP-1036) — out-of-band user input via redirect.
- **Tool calling in sampling** — servers can pass `tools`/`toolChoice` when asking the client to run inference (SEP-1577).
- **Icons** as metadata on tools/resources/prompts (SEP-973).
- **Incremental scope consent** via `WWW-Authenticate` (SEP-835).
- **OIDC Discovery 1.0** supported for AS discovery (SEP-797).
- **OAuth Client ID Metadata Documents (CIMD)** as recommended registration mechanism (SEP-991).
- **Experimental Tasks** — durable async requests with polling (SEP-1686).
- **JSON Schema 2020-12** is now the default dialect.
- Servers MUST return **HTTP 403** for invalid `Origin` on Streamable HTTP.
- Tool input validation errors → return as Tool Execution Errors (`isError: true`), **not** Protocol Errors, so the model can self-correct.
- `stderr` on stdio explicitly allowed for **all** log severities.

**Feature landing version (cheatsheet):**

| Feature | First in |
|---|---|
| Form elicitation, structured tool output, resource links, tool annotations | `2025-06-18` |
| Streamable HTTP transport, OAuth 2.1 authorization | `2025-03-26` |
| URL elicitation, icons, sampling-with-tools, incremental scope, Tasks | `2025-11-25` |

For most API wrappers you only need **Tools**.

---

## 3. Transport: Streamable HTTP

### Single Endpoint

```
POST   /mcp     ← All client messages (requests, notifications, responses)
GET    /mcp     ← SSE stream for server-initiated messages
DELETE /mcp     ← Session termination (SHOULD; server MAY return 405)
GET    /health  ← Health check (not part of MCP spec, but good practice)
```

### POST /mcp

| Requirement | Detail |
|-------------|--------|
| `Accept` header | `application/json, text/event-stream` — both required |
| Body | Single JSON-RPC request, notification, or response |
| Response (request input) | Either `application/json` (one object) OR `text/event-stream` (SSE) — server's choice |
| Response (notification/response input) | HTTP 202 Accepted, empty body |
| Response (error) | HTTP 4xx/5xx with JSON-RPC error body (or empty) |

> **SDK behavior note:** The official Python SDK's `FastMCP` and PrefectHQ FastMCP both default to **SSE** responses (`text/event-stream`) wrapping the JSON-RPC reply in `event: message\ndata: {...}\n\n`. The spec permits plain `application/json`; raw FastAPI servers may do that directly.

### GET /mcp (SSE stream)

Long-lived SSE for server-initiated messages.
- `Accept: text/event-stream` required → 406 otherwise.
- `Mcp-Session-Id` required → 400 missing, 404 invalid.
- Resumable via `Last-Event-ID` header — server replays missed events.
- **Polling SSE** (new in 2025-11-25): server MAY close the connection at will; client polls by reconnecting GET + `Last-Event-ID`.

### DELETE /mcp

Client SHOULD send `DELETE` with `Mcp-Session-Id` to terminate. Server MAY return 405 (not all servers implement it).

### Headers

| Header | Direction | Required | Description |
|--------|-----------|----------|-------------|
| `Accept` | C → S | MUST | `application/json, text/event-stream` |
| `Content-Type` | C → S | MUST | `application/json` |
| `Content-Type` | S → C | MUST | `text/event-stream` or `application/json` |
| `MCP-Protocol-Version` | C → S | MUST after init | e.g. `2025-11-25` — missing → server assumes `2025-03-26`; invalid → 400 |
| `Mcp-Session-Id` | both | MUST after init | Cryptographically secure, visible-ASCII (0x21–0x7E) |
| `Origin` | C → S | validated | Invalid → **403** (new in 2025-11-25) |
| `Last-Event-ID` | C → S | for resumes | Resume SSE on GET |
| `Authorization` | C → S | when auth | `Bearer <token>` only — never in query string |
| `Cache-Control` | S → C | auto | `no-cache, no-transform` on SSE |
| `X-Accel-Buffering` | S → C | auto | `no` — prevents proxy buffering |

### Legacy HTTP+SSE transport

**Deprecated** since `2025-03-26`. Bidirectional compatibility section in the spec covers fallback by probing both endpoints. The old `endpoint` SSE event signals a legacy server.

---

## 4. Transport: Stdio

Subprocess transport — client launches server as a child process.

- **Client → Server**: newline-delimited JSON-RPC on **stdin**
- **Server → Client**: newline-delimited JSON-RPC on **stdout**
- **stderr**: UTF-8 logs of any severity (client MUST NOT assume stderr means error)
- No HTTP overhead, no session IDs
- Embedded newlines in messages are forbidden

**When to use:** Local integrations (Claude Desktop, editor plugins) where the client launches the server.

**When to use Streamable HTTP instead:** Remote/production, multi-user, web-accessible services.

---

## 5. Lifecycle & Session Management

### Initialization Flow

```
Client                            Server
  ├──── POST initialize ──────────►│
  │◄─── InitializeResult ──────────┤   (server MAY set Mcp-Session-Id header)
  ├──── POST notifications/initialized ─►│
  │◄─── 202 Accepted ──────────────┤
  │           ── Normal Operations ──        │
  ├──── POST tools/list ───────────►│
  │◄─── tools list ────────────────┤
```

### Initialize Request (2025-11-25)

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {
      "roots": {"listChanged": true},
      "sampling": {},
      "elicitation": {"form": {}, "url": {}},
      "tasks": {
        "requests": {
          "elicitation": {"create": {}},
          "sampling": {"createMessage": {}}
        }
      }
    },
    "clientInfo": {
      "name": "ExampleClient",
      "title": "Example Client",
      "version": "1.0.0",
      "description": "...",
      "icons": [{"src": "https://.../icon.png", "mimeType": "image/png", "sizes": ["48x48"]}],
      "websiteUrl": "https://example.com"
    }
  }
}
```

### InitializeResult

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-11-25",
    "capabilities": {
      "logging": {},
      "prompts": {"listChanged": true},
      "resources": {"subscribe": true, "listChanged": true},
      "tools": {"listChanged": true},
      "tasks": {
        "list": {}, "cancel": {},
        "requests": {"tools": {"call": {}}}
      }
    },
    "serverInfo": {
      "name": "my-api-mcp",
      "title": "My API",
      "version": "1.0.0",
      "icons": [...],
      "websiteUrl": "https://..."
    },
    "instructions": "Optional: how/when to use this server"
  }
}
```

Then client sends `notifications/initialized` (no params). Shutdown is transport-level (close stdin / close HTTP connection); no explicit RPC.

### Session Management

- Server assigns `Mcp-Session-Id` via response header on `InitializeResult`.
- Session IDs MUST be cryptographically secure and visible-ASCII (0x21–0x7E) — e.g. UUID, JWT, or hash.
- Missing on non-init requests → **HTTP 400**.
- Invalid/expired → **HTTP 404** ("Session not found") — client must reinitialize.
- DELETE terminates → 200 empty body (or 405 if unsupported).

FastMCP and the official SDK handle sessions automatically.

---

## 6. JSON-RPC 2.0 Message Format

### Request
```json
{"jsonrpc": "2.0", "id": 1, "method": "method_name", "params": {}}
```

### Notification (no `id`, no response)
```json
{"jsonrpc": "2.0", "method": "notifications/initialized"}
```

### Success
```json
{"jsonrpc": "2.0", "id": 1, "result": { ... }}
```

### Error
```json
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32601, "message": "Method not found"}}
```

### Standard & MCP Error Codes

| Code | Meaning |
|------|---------|
| `-32700` | Parse error (invalid JSON) |
| `-32600` | Invalid request |
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32603` | Internal error |
| `-32002` | Resource not found |
| `-32042` | `URLElicitationRequiredError` (2025-11-25) — `data.elicitations[]` lists required URL elicitations |

> **Tool errors are NOT JSON-RPC errors.** Tool execution failures return inside `result` with `isError: true`. JSON-RPC `error` is reserved for protocol-level failures (parse, unknown method, etc.).

---

## 7. FastMCP Server (PrefectHQ FastMCP 3.x)

The recommended path. Stable line is `3.2.4`; `3.3.0` is in beta as of 2026-05-13 (mainly adds a client-only `fastmcp-slim` distribution).

### 7.1 Minimal server

```python
# server.py
from fastmcp import FastMCP

mcp = FastMCP(name="my-api-mcp", version="1.0.0")

@mcp.tool
def hello(name: str) -> str:
    """Greet someone by name.

    Args:
        name: The person's name to greet
    """
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
    # Serves at http://localhost:8000/mcp
```

Run: `python server.py` or `fastmcp run server.py`.

### 7.2 Constructor

```python
FastMCP(
    name="...",
    instructions="...",                  # Tells the LLM how/when to use this server
    version="1.0.0",
    website_url="https://...",
    icons=None,                          # list[Icon]
    tools=None,                          # Pre-built tools
    auth=None,                           # Auth provider (see §12)
    middleware=None,                     # list[Middleware] (see §13)
    providers=None,                      # Composition (see §14)
    transforms=None,
    lifespan=None,                       # async context manager
    on_duplicate="warn",                 # "warn"|"error"|"replace"|"ignore"
    strict_input_validation=False,
    mask_error_details=None,             # Hide tracebacks from client
    list_page_size=None,
    tasks=False,                         # Enable experimental Tasks primitive
    client_log_level=None,
    dereference_schemas=True,
    sampling_handler=None,               # Fallback if client doesn't sample
    sampling_handler_behavior="fallback",
    session_state_store=None,
)
```

> **3.x breaking change:** transport kwargs (`host`, `port`, `log_level`, `debug`, `sse_path`, `streamable_http_path`, `json_response`, `stateless_http`, `message_path`) were **removed from the constructor**. Pass them to `run()` / `http_app()` instead.

### 7.3 Transport options

```python
# Stdio (default — for local clients like Claude Desktop)
mcp.run(transport="stdio")

# Streamable HTTP (production)
mcp.run(transport="http", host="0.0.0.0", port=8000)

# SSE (legacy — deprecated, kept for backwards compat)
mcp.run(transport="sse", host="0.0.0.0", port=8000)
```

### 7.4 ASGI mount in FastAPI/Starlette

```python
from fastapi import FastAPI
from fastmcp import FastMCP

mcp = FastMCP("my-api-mcp")
# register tools ...

mcp_app = mcp.http_app(path="/mcp")         # streamable-HTTP ASGI app
app = FastAPI(lifespan=mcp_app.lifespan)    # MUST forward lifespan
app.mount("/analytics", mcp_app)            # MCP at /analytics/mcp
```

Stateless mode (required behind LBs without session affinity):
```python
mcp.http_app(stateless_http=True)
# or set env var FASTMCP_STATELESS_HTTP=true
```

### 7.5 Tools

```python
from fastmcp import FastMCP
mcp = FastMCP("S")

@mcp.tool                       # no parens — both styles work in 3.x
def add(a: int, b: int) -> int:
    """Add two numbers."""
    return a + b

@mcp.tool(
    name="multiply",
    description="Multiply two ints.",
    tags={"math"},
    meta={"author": "x"},
    annotations={
        "title": "Multiply",
        "readOnlyHint": True,
        "idempotentHint": True,
        "destructiveHint": False,
        "openWorldHint": False,
    },
    icons=None,
    output_schema=None,
    timeout=30.0,
    version="1.0",
)
def mul(x: int, y: int) -> int:
    return x * y
```

**Return types:**

| Return | Behavior |
|---|---|
| `str` | Text content |
| `int`/`float`/`bool`/`dict`/`list` | Wrapped as structured content `{"result": ...}` |
| Pydantic `BaseModel` / `@dataclass` | Structured content + auto JSON Schema |
| `Image(path=...)`, `Audio(path=...)`, `File(path=...)` from `fastmcp.utilities.types` | Media |
| `ToolResult` from `fastmcp.tools.tool` | Full control (content + structured_content + meta) |

`async def` and `def` both work. `*args` / `**kwargs` not supported.

**Errors:** raise `fastmcp.exceptions.ToolError` (or `ResourceError`, `PromptError`, `McpError`). Use `mask_error_details=True` on the server to hide tracebacks.

**3.x decorator quirk:** decorators return the **original function** (not a `FunctionTool` wrapper). Use `mcp.list_tools()` to inspect — no more `.name`/`.description` on the decorated symbol. Enable/disable moved to the server:

```python
mcp.disable(names={"my_tool"}, components={"tool"})
mcp.enable(names={"my_tool"}, components={"tool"})
mcp.disable(tags={"experimental"})
```

### 7.6 Context

Inject `Context` to access logging, progress, resources, sampling, elicitation, state, etc.

```python
from fastmcp import Context           # legacy type-hint style

@mcp.tool
async def long_task(data: str, ctx: Context) -> str:
    await ctx.info("Starting...")
    await ctx.report_progress(0.5, total=1.0)

    text = await ctx.read_resource("resource://config")
    answer = await ctx.elicit("Continue?", response_type=ConfirmSchema)
    sampled = await ctx.sample("Summarize this", temperature=0.7)

    await ctx.set_state("last_run", data)              # async in 3.x
    last = await ctx.get_state("last_run")

    return f"done: {ctx.request_id}"
```

Preferred 3.x style uses dependency injection:

```python
from fastmcp.dependencies import CurrentContext
from fastmcp.server.context import Context

@mcp.tool
async def t(ctx: Context = CurrentContext()) -> str: ...
```

Or retrieve dynamically from helpers:

```python
from fastmcp.server.dependencies import get_context
ctx = get_context()
```

**Async methods (full surface as of 3.x):**

| Method | Since | Purpose |
|---|---|---|
| `await ctx.debug(msg)` / `info` / `warning` / `error` | | Structured logging to client |
| `await ctx.report_progress(progress, total)` | | Progress notification |
| `await ctx.list_resources()` | v2.13 | Server's resources |
| `await ctx.read_resource(uri)` | | Read resource content |
| `await ctx.list_prompts()` | v2.13 | Server's prompts |
| `await ctx.get_prompt(name, arguments=None)` | v2.13 | Render a prompt |
| `await ctx.sample(prompt, temperature=0.7)` | v2.0 | Ask client to run LLM inference |
| `await ctx.elicit(message, response_type, ...)` | v2.10 | Request user input |
| `await ctx.set_state(k, v, *, serializable=True)` | **v3.0** | Per-session state |
| `await ctx.get_state(k)` / `await ctx.delete_state(k)` | **v3.0** | (Persists across requests in same session; default TTL 1 day) |
| `await ctx.enable_components(...)` / `disable_components(...)` / `reset_visibility()` | **v3.0** | Per-session component visibility |
| `await ctx.send_notification(notification)` | **v3.0** | Manually push list-change / other notifications |

**Sync properties:**

| Property | Type | Notes |
|---|---|---|
| `ctx.request_id` | `str` | Unique per MCP request |
| `ctx.client_id` | `str \| None` | If provided by client |
| `ctx.session_id` | `str` | Raises `RuntimeError` if MCP session not established |
| `ctx.fastmcp` | `FastMCP` | Underlying server |
| `ctx.request_context` | `RequestContext \| None` | After handshake (v2.13.1+); `request_context.meta` is attribute access (not dict) |
| `ctx.transport` | `Literal["stdio","sse","streamable-http"] \| None` | **v3.0** — active transport |
| `ctx.lifespan_context` | dict | Whatever the lifespan yielded — preferred over `ctx.request_context.lifespan_context` |

> **`Context` does NOT expose the inbound HTTP request.** For headers, cookies, etc., use the dependency helpers (work even before the MCP session is established):
> ```python
> from fastmcp.server.dependencies import get_http_request, get_http_headers
>
> @mcp.tool
> async def whoami() -> str:
>     headers = get_http_headers()
>     return headers.get("x-user-id", "anonymous")
> ```
> The old `Context.get_http_request()` method was removed in v2.14.0.

### 7.7 Resources

```python
@mcp.resource("resource://greeting")
def greeting() -> str:
    return "Hello"

@mcp.resource("weather://{city}/current", mime_type="application/json")
async def weather(city: str) -> str:
    return await fetch_weather(city)

@mcp.resource("path://{filepath*}")             # wildcard
def file(filepath: str) -> str: ...

@mcp.resource("data://{id}{?format}")           # RFC 6570 query param
def data(id: str, format: str = "json") -> str: ...
```

Return `str` (text), `bytes` (base64 blob — also set `mime_type`), or `ResourceResult`. Raise `fastmcp.exceptions.ResourceError`.

### 7.8 Prompts

```python
from fastmcp.prompts import Message      # NEW location in 3.x

@mcp.prompt
def code_review(code: str, language: str = "python") -> list[Message]:
    """Review code for quality issues."""
    return [
        Message(f"Review this {language}:\n\n```{language}\n{code}\n```"),
        Message("I'll review it.", role="assistant"),
    ]
```

`Message` defaults to role `"user"`. Return `str`, `Message`, `list[Message|str]`, or `PromptResult`.

### 7.9 Lifespan

Run setup once at startup, cleanup once at shutdown. The yielded dict is the **lifespan context** — accessible from tools as `ctx.lifespan_context`.

```python
from fastmcp import FastMCP, Context
from fastmcp.server.lifespan import lifespan
import httpx

@lifespan                                        # FastMCP 3.x decorator
async def app_lifespan(server):
    async with httpx.AsyncClient(timeout=30.0) as client:
        yield {"http_client": client}            # setup
    # teardown after yield (or via try/finally)

mcp = FastMCP("my-api-mcp", lifespan=app_lifespan)

@mcp.tool
async def search(query: str, ctx: Context) -> str:
    http = ctx.lifespan_context["http_client"]
    r = await http.get("https://api.example.com/search", params={"q": query})
    return r.text
```

Plain `@asynccontextmanager` lifespans still work. Compose multiple lifespans with `|` — they enter left-to-right and exit in reverse.

### 7.10 Custom HTTP routes

```python
from starlette.requests import Request
from starlette.responses import JSONResponse

@mcp.custom_route("/health", methods=["GET"])
async def health(request: Request) -> JSONResponse:
    return JSONResponse({"status": "healthy"})
```

### 7.11 Multi-module layout

```
my-api-mcp/
├── server.py                # FastMCP setup + run
├── tools/
│   ├── search.py            # register_search_tools(mcp)
│   └── items.py
├── core/
│   ├── config.py
│   └── client.py
├── pyproject.toml
└── Dockerfile
```

```python
# server.py
from fastmcp import FastMCP
from tools.search import register_search_tools
from tools.items import register_item_tools

mcp = FastMCP("my-api-mcp")
register_search_tools(mcp)
register_item_tools(mcp)

if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
```

```python
# tools/search.py
import json
from fastmcp import FastMCP, Context

def register_search_tools(mcp: FastMCP):

    @mcp.tool
    async def search_items(query: str, limit: int = 10, ctx: Context = None) -> str:
        """Search items by keyword."""
        http = ctx.lifespan_context["http_client"]
        r = await http.get("/search", params={"q": query, "limit": limit})
        return json.dumps(r.json(), indent=2)
```

### 7.12 Dependency Injection

FastMCP 3.x has a real dependency-injection system (backed by Docket + uncalled-for). DI parameters are **automatically excluded** from the MCP schema — clients never see them.

**Built-in injectables:**

| Helper (`fastmcp.dependencies`) | Function form (`fastmcp.server.dependencies`) | Yields | Since |
|---|---|---|---|
| `CurrentContext()` | `get_context()` | MCP `Context` | v2.14 / v2.2.11 |
| `CurrentFastMCP()` | `get_server()` | `FastMCP` instance | v2.14 |
| `CurrentRequest()` | `get_http_request()` | Starlette `Request` (HTTP transports only) | v2.2.11 |
| `CurrentHeaders()` | `get_http_headers(include_all=False)` | `dict[str,str]` (empty if unavailable) | v2.2.11 |
| `CurrentAccessToken()` | `get_access_token()` | `AccessToken \| None` | v2.11 |
| — | `TokenClaim("oid")` | individual JWT claim value | |
| `CurrentDocket()` / `CurrentWorker()` / `Progress()` | — | Task primitives (see §7.14) | v2.3 / v3.0 |

```python
from fastmcp.dependencies import (
    CurrentContext, CurrentFastMCP, CurrentRequest,
    CurrentHeaders, CurrentAccessToken,
)
from fastmcp.server.dependencies import TokenClaim
from fastmcp.server.auth import AccessToken

@mcp.tool
async def whoami(
    user_id: str = TokenClaim("oid"),                 # Azure/Entra
    token: AccessToken = CurrentAccessToken(),
    headers: dict = CurrentHeaders(),
) -> dict:
    return {
        "user_id": user_id,
        "client_id": token.client_id,
        "scopes": token.scopes,
        "ua": headers.get("user-agent"),
    }
```

**AccessToken** fields: `client_id`, `scopes`, `expires_at`, `claims` (full JWT/provider-specific claims).

**Custom dependencies** via `Depends()` — same model as FastAPI:

```python
from fastmcp.dependencies import Depends

def get_config() -> dict:
    return {"api_url": "https://api.example.com"}

@mcp.tool
async def fetch(query: str, config: dict = Depends(get_config)) -> str:
    return f"{config['api_url']}/{query}"
```

Async, sync, and `@asynccontextmanager` callables all work. Resolution is **cached per request** (the same call to `get_db()` in two dependents returns the same instance). Nested dependencies resolve automatically.

### 7.13 Server-Side Authorization (new in 3.x)

Authentication answers *who*; authorization answers *what they can do*. FastMCP 3.x adds a built-in authorization layer that filters list responses and blocks unauthorized direct calls.

**Built-in checks:**
- `require_scopes(...)` — assert OAuth scopes are present
- `restrict_tag(...)` — apply scope requirements conditionally based on component tags

**Custom check** = any sync or async callable taking `AuthContext` and returning `bool`. Multiple checks combine with **AND** logic.

```python
from fastmcp.server.auth.authorization import require_scopes, restrict_tag, AuthContext

@mcp.tool(auth=require_scopes(["write:data"]))
async def write_record(...): ...

# Custom check
async def is_internal(ctx: AuthContext) -> bool:
    email = ctx.token.claims.get("email", "")
    return email.endswith("@mycompany.com")

@mcp.tool(auth=[require_scopes(["read:data"]), is_internal])
async def internal_only(...): ...
```

**Server-level** via `AuthMiddleware`: applies a rule set across all components.

**Token introspection in code** uses `get_access_token()` from `fastmcp.server.dependencies` (see §7.12). OAuth tokens work only with HTTP transports — never stdio.

### 7.14 Background Tasks (Protocol-Native Long-Running Ops)

FastMCP 3.x implements MCP's experimental Tasks primitive. Clients get a task ID immediately, poll for progress, and retrieve results when done. Backed by [Docket](https://github.com/chrisguidry/docket).

```bash
pip install 'fastmcp[tasks]'
```

```python
from datetime import timedelta
from fastmcp import FastMCP
from fastmcp.dependencies import Progress
from fastmcp.server.tasks import TaskConfig

mcp = FastMCP("MyServer", tasks=True)            # enable globally

@mcp.tool(task=True)                              # mode="optional"
async def slow_compute(duration: int) -> str:
    ...

@mcp.tool(task=TaskConfig(mode="required",        # always background
                          poll_interval=timedelta(seconds=2)))
async def process_files(files: list[str],
                        progress: Progress = Progress()) -> str:
    await progress.set_total(len(files))
    for f in files:
        await progress.set_message(f"Processing {f}")
        # ... work ...
        await progress.increment()
    return "done"
```

**Modes:** `"forbidden"` (sync only), `"optional"` (sync OR background), `"required"` (always background). Tasks **require async** functions — `task=True` on a sync function raises `ValueError`.

**Backends:**

| Backend | Latency | Persistence | Multi-worker |
|---|---|---|---|
| In-memory (default) | ~250 ms | ephemeral | single-process |
| Redis / Valkey (`FASTMCP_DOCKET_URL=redis://...`) | ~1 ms | persistent | yes |

**Scaling workers:**
```bash
export FASTMCP_DOCKET_CONCURRENCY=20
fastmcp tasks worker server.py
```

Advanced: inject `CurrentDocket()` / `CurrentWorker()` to schedule additional task work, chain tasks, set timeouts.

### 7.15 Pagination

For large lists of tools/resources/prompts. Enable per-server:

```python
mcp = FastMCP("Reg", list_page_size=50)
```

Affects all `list_*` operations. Cursors are opaque base64 strings — clients treat them as black boxes.

**Client side:**

```python
# Automatic — convenience method fetches all pages
tools = await client.list_tools()

# Manual — for streaming/incremental processing
result = await client.list_tools_mcp()
while result.nextCursor:
    result = await client.list_tools_mcp(cursor=result.nextCursor)
```

Use pagination when components are sourced from a DB/filesystem, or when initial-response latency matters. Under ~100 components, the default is fine.

### 7.16 Versioning (new in 3.x)

Maintain multiple implementations of the same tool/resource/prompt under one name:

```python
@mcp.tool(version="1.0")
def calculate(x: int, y: int) -> int:
    return x + y

@mcp.tool(version="2.0")
def calculate(x: int, y: int, z: int = 0) -> int:
    return x + y + z
```

**Rule:** for a given name, either version **all** implementations or **none**.

**Filter** to publish distinct API surfaces (e.g., `/v1` vs `/v2`):

```python
from fastmcp.server.transforms import VersionFilter

api_v1.add_transform(VersionFilter(version_lt="2.0"))
api_v2.add_transform(VersionFilter(version_gte="2.0"))
```

**Client requests a specific version:**

```python
result = await client.call_tool("calculate", {"x": 1, "y": 2}, version="1.0")
```

Non-Python clients pass `_meta.fastmcp.version` in request params. Available versions are discoverable via `meta.fastmcp.versions` (highest to lowest). Comparison: PEP 440 for standard versions; lexicographic for custom formats (ISO dates etc.); leading `v` is stripped.

### 7.17 Storage Backends

FastMCP uses pluggable [py-key-value-aio](https://github.com/jamesbraza/py-key-value) stores for:

- OAuth tokens and dynamic client registrations
- Response cache (`ResponseCachingMiddleware`)
- Client-side OAuth token persistence

**Backends:** in-memory (default), `FileTreeStore` (single-server), `RedisStore`, plus DynamoDB / MongoDB / Elasticsearch / Memcached / RocksDB / Valkey via py-key-value-aio.

```python
import os
from pathlib import Path
from key_value.aio.stores.filetree import (
    FileTreeStore,
    FileTreeV1KeySanitizationStrategy,
    FileTreeV1CollectionSanitizationStrategy,
)
from fastmcp.server.middleware.caching import ResponseCachingMiddleware

storage_dir = Path("/var/cache/fastmcp")
store = FileTreeStore(
    data_directory=storage_dir,
    key_sanitization_strategy=FileTreeV1KeySanitizationStrategy(storage_dir),
    collection_sanitization_strategy=FileTreeV1CollectionSanitizationStrategy(storage_dir),
)
mcp.add_middleware(ResponseCachingMiddleware(cache_storage=store))
```

**Production OAuth storage MUST be encrypted** — wrap with `FernetEncryptionWrapper` or tokens persist in plaintext:

```python
from cryptography.fernet import Fernet
from key_value.aio.stores.redis import RedisStore
from key_value.aio.wrappers.encryption import FernetEncryptionWrapper

client_storage = FernetEncryptionWrapper(
    key_value=RedisStore(host="redis.example.com"),
    fernet=Fernet(os.environ["STORAGE_ENCRYPTION_KEY"]),
)
# pass into provider's client_storage= kwarg (e.g., AzureProvider)
```

`FileTreeStore` requires key/collection sanitization strategies — special chars in keys cause filesystem errors otherwise.

### 7.18 OpenTelemetry

Native OTel instrumentation with **zero config** — spans are no-ops without an SDK installed, fully active with one.

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
opentelemetry-instrument \
  --service_name my-fastmcp-server \
  --exporter_otlp_endpoint http://localhost:4317 \
  fastmcp run server.py
```

Or via env:

```bash
export OTEL_SERVICE_NAME=my-fastmcp-server
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
opentelemetry-instrument fastmcp run server.py
```

**Span names (MCP semantic conventions):**
- `tools/call {name}` — tool execution
- `resources/read {uri}`
- `prompts/get {name}`
- `delegate {name}` — mounted server delegation

**Custom spans:**

```python
from fastmcp.telemetry import get_tracer

tracer = get_tracer()
with tracer.start_as_current_span("operation_name") as span:
    span.set_attribute("key", "value")
```

For local dev: `otel-desktop-viewer` or Jaeger via Docker. For tests: use the in-memory span exporter in pytest fixtures.

---

## 8. Official MCP SDK Server

For minimalism or zero non-Anthropic deps, use `mcp.server.fastmcp.FastMCP` directly.

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("my-api-mcp")

@mcp.tool()
def hello(name: str) -> str:
    """Greet someone."""
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run(transport="streamable-http")
```

API is very similar to PrefectHQ FastMCP 1.0/2.x (which was its origin). Differences from PrefectHQ 3.x:
- Decorator requires parens: `@mcp.tool()` (PrefectHQ 3.x: `@mcp.tool` also works).
- No built-in middleware, OAuth providers, composition, or OpenAPI/FastAPI conversion.
- Transport kwargs still on `run()` (`transport`, `host`, `port`, `json_response`, `stateless_http`, etc.).
- Transport security via:
  ```python
  from mcp.server.transport_security import TransportSecuritySettings
  mcp.run(transport="streamable-http",
          transport_security=TransportSecuritySettings(
              allowed_origins=["https://myapp.example.com"]))
  ```

### Low-level Server API

For full control over JSON-RPC handlers:

```python
from mcp.server import Server
server = Server("my-server")

@server.list_tools()
async def handle_list_tools(): ...

@server.call_tool()
async def handle_call_tool(name, arguments): ...
```

Use this only if you need surgical control — the high-level decorator API covers ~95% of cases.

---

## 9. Server Template (Raw FastAPI)

Only when you need browser CORS, custom middleware, or non-standard wire behavior:

```python
"""
{API_NAME} MCP Server — Raw FastAPI implementation
"""
import hmac, os, json, logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import httpx

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SERVER_NAME = "{api-name}-mcp"
SERVER_VERSION = "1.0.0"
API_BASE_URL = os.getenv("API_BASE_URL", "https://api.example.com/v1")
API_KEY = os.getenv("API_KEY", "")
MCP_AUTH_TOKEN = os.getenv("MCP_AUTH_TOKEN", "")

@asynccontextmanager
async def lifespan(app):
    async with httpx.AsyncClient(timeout=30.0) as client:
        app.state.http_client = client
        yield

app = FastAPI(title=f"{SERVER_NAME}", lifespan=lifespan)

TOOLS = [{
    "name": "search_items",
    "description": "Search for items by keyword.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Search keywords"},
            "limit": {"type": "integer", "default": 10},
        },
        "required": ["query"],
    },
}]


async def dispatch_tool(name, args, http):
    if name == "search_items":
        query = args.get("query", "").strip()
        if not query:
            raise ValueError("query is required")
        limit = max(1, min(args.get("limit", 10), 50))
        r = await http.get(
            f"{API_BASE_URL}/search",
            params={"q": query, "limit": limit},
            headers={"Authorization": f"Bearer {API_KEY}"} if API_KEY else {},
        )
        r.raise_for_status()
        return r.json()
    return None


@app.post("/mcp")
async def mcp_endpoint(request: Request):
    if MCP_AUTH_TOKEN:
        token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        if not hmac.compare_digest(token, MCP_AUTH_TOKEN):
            return JSONResponse({"error": "unauthorized"}, status_code=401)

    try:
        body = await request.json()
    except json.JSONDecodeError:
        return JSONResponse({"jsonrpc": "2.0", "id": None,
                             "error": {"code": -32700, "message": "Parse error"}})

    method = body.get("method", "")
    params = body.get("params", {})
    rid = body.get("id")

    if method == "initialize":
        return JSONResponse({
            "jsonrpc": "2.0", "id": rid,
            "result": {
                "protocolVersion": "2025-11-25",
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "capabilities": {"tools": {}},
                "instructions": "Use search_items to find resources.",
            },
        })

    if method == "notifications/initialized":
        return JSONResponse(content=None, status_code=202)

    if method == "ping":
        return JSONResponse({"jsonrpc": "2.0", "id": rid, "result": {}})

    if method == "tools/list":
        return JSONResponse({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}})

    if method == "tools/call":
        name = params.get("name", "")
        args = params.get("arguments", {})
        try:
            result = await dispatch_tool(name, args, request.app.state.http_client)
            if result is None:
                return JSONResponse({
                    "jsonrpc": "2.0", "id": rid,
                    "error": {"code": -32601, "message": f"Unknown tool: {name}"},
                })
            return JSONResponse({
                "jsonrpc": "2.0", "id": rid,
                "result": {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]},
            })
        except ValueError as e:
            return JSONResponse({
                "jsonrpc": "2.0", "id": rid,
                "result": {"content": [{"type": "text", "text": f"Validation error: {e}"}],
                           "isError": True},
            })
        except Exception:
            logger.exception("Tool failed: %s", name)
            return JSONResponse({
                "jsonrpc": "2.0", "id": rid,
                "result": {"content": [{"type": "text", "text": "Internal tool error."}],
                           "isError": True},
            })

    return JSONResponse({
        "jsonrpc": "2.0", "id": rid,
        "error": {"code": -32601, "message": f"Method not found: {method}"},
    })


@app.get("/health")
async def health():
    return {"status": "healthy"}
```

---

## 10. Clients

### 10.1 FastMCP Client (recommended)

```python
from fastmcp import Client

# Auto-inferred transport:
async with Client(mcp_server_instance) as c:        # in-memory
    ...
async with Client("path/to/server.py") as c:        # stdio
    ...
async with Client("https://api.example.com/mcp") as c:   # streamable HTTP
    tools  = await c.list_tools()
    result = await c.call_tool("search", {"query": "x"})
    # result.data → structured content (Pydantic-validated if schema present)

    content  = await c.read_resource("file:///x")
    messages = await c.get_prompt("name", {"arg": "v"})
```

With callbacks (verified kwarg names — `*_handler`, not `*_callback`):

```python
async def handle_sampling(ctx, params):
    response = await my_llm.generate(params.messages)
    from mcp.types import CreateMessageResult, TextContent
    return CreateMessageResult(role="assistant",
                               content=TextContent(type="text", text=response),
                               model="my-model")

async def handle_elicitation(ctx, params):
    from mcp.types import ElicitResult
    return ElicitResult(action="accept", content={"proceed": True})

async def roots_callback(ctx):
    return ["/Users/me/project"]

client = Client(
    "https://server.example.com/mcp",
    env={"API_KEY": "..."},
    log_handler=my_log_handler,
    progress_handler=my_progress_handler,
    sampling_handler=handle_sampling,
    elicitation_handler=handle_elicitation,
    message_handler=None,
    roots=["/Users/me/project"],          # OR roots=roots_callback
    timeout=30.0,
)
```

Explicit transports in `fastmcp.client.transports`: `FastMCPTransport`, `StreamableHttpTransport`, `StdioTransport`, `NpxStdioTransport`, `UvxStdioTransport`.

### 10.2 Official SDK Client

```python
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.client.streamable_http import streamablehttp_client

# Stdio
params = StdioServerParameters(
    command="python",
    args=["server.py"],
    env={"API_KEY": os.getenv("API_KEY", "")},
    cwd="/path/to/server",
)
async with stdio_client(params) as (read, write):
    async with ClientSession(read, write) as session:
        await session.initialize()
        result = await session.call_tool("hello", {"name": "World"})

# Streamable HTTP
async with streamablehttp_client("https://example.com/mcp") as (read, write, _):
    async with ClientSession(read, write) as session:
        await session.initialize()
        tools = await session.list_tools()
```

With custom HTTP client (auth headers, timeouts):

```python
import httpx
async with httpx.AsyncClient(
    timeout=30.0,
    headers={"Authorization": "Bearer my-token"},
) as http_client:
    async with streamablehttp_client(
        "https://example.com/mcp",
        http_client=http_client,
        terminate_on_close=True,
    ) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
```

### 10.3 Multi-Server (FastMCP)

`fastmcp.client.session_group` allows aggregating multiple servers:

```python
from fastmcp.client.session_group import (
    ClientSessionGroup, StdioServerParameters, StreamableHttpParameters,
)
async with ClientSessionGroup() as group:
    await group.connect_to_server(StdioServerParameters(command="server1"))
    await group.connect_to_server(StreamableHttpParameters(url="https://s2/mcp"))
    result = await group.call_tool("any_tool", {"arg": "v"})
    all_tools = group.tools
```

---

## 11. Elicitation

### Form Mode (since 2025-06-18)

```python
from pydantic import BaseModel
from fastmcp import Context

class ConfirmAction(BaseModel):
    proceed: bool
    reason: str = ""

@mcp.tool
async def dangerous_action(target: str, ctx: Context) -> str:
    """Delete with user confirmation."""
    result = await ctx.elicit(
        f"Delete {target}?",
        response_type=ConfirmAction,
        response_title="Confirm deletion",
    )
    if result.action == "accept" and result.content.proceed:
        return f"Deleted {target}"
    return "Cancelled"
```

Form schemas support primitive types (`str`, `int`, `float`, `bool`, enums) and defaults.

### URL Mode (new in 2025-11-25)

For out-of-band flows (OAuth, manual review, etc.):

```python
@mcp.tool
async def oauth_login(ctx: Context) -> str:
    result = await ctx.elicit_url(
        message="Please log in",
        url="https://auth.example.com/login?callback=...",
        elicitation_id="login-12345",
    )
    return "Login complete"
```

**Client safety requirements** (spec):
- Display the full URL to the user.
- MUST NOT pre-fetch or auto-open.
- Open in isolated/secure context (e.g., `SFSafariViewController` on iOS — not embedded WebView).
- Highlight the domain; warn on Punycode.

### Client-side handler

```python
from mcp.types import ElicitResult

async def handle_elicitation(ctx, params):
    user_response = await show_form(params)
    if user_response is None:
        return ElicitResult(action="cancel")
    return ElicitResult(action="accept", content=user_response)
```

Actions: `"accept"`, `"decline"`, `"cancel"`.

---

## 12. Authentication & Authorization

### 12.1 The spec (OAuth 2.1)

- HTTP-based transports only (stdio uses env credentials).
- Base specs: OAuth 2.1 draft, RFC 8414 (AS metadata), RFC 7591 (DCR), **RFC 9728 (Protected Resource Metadata)**, OAuth Client ID Metadata Documents (CIMD).
- **PKCE required**, `S256`. Client MUST verify `code_challenge_methods_supported` in AS metadata.
- **Resource Indicators (RFC 8707)**: clients MUST include `resource=<canonical-mcp-uri>` in auth + token requests.
- Tokens via `Authorization: Bearer <token>` only — never query string. Server MUST validate audience. Token passthrough to upstream APIs is **forbidden**.

**Discovery flow:**

1. Client hits server → `401` + `WWW-Authenticate: Bearer resource_metadata="..."`.
2. Client fetches Protected Resource Metadata (from URL or `.well-known/oauth-protected-resource`).
3. PRM → `authorization_servers[]`.
4. Client discovers AS metadata via `.well-known/oauth-authorization-server` or `.well-known/openid-configuration`.
5. Standard OAuth 2.1 auth-code + PKCE with `resource=` param.

**Client registration priority:**
1. Pre-registered credentials
2. **CIMD** (if AS advertises `client_id_metadata_document_supported: true`)
3. Dynamic Client Registration (RFC 7591) fallback
4. Prompt user

**Incremental scope consent (2025-11-25):**

```
HTTP/1.1 403 Forbidden
WWW-Authenticate: Bearer error="insufficient_scope",
                         scope="files:read files:write",
                         resource_metadata="https://.../.well-known/oauth-protected-resource"
```

Client performs step-up auth and retries.

**HTTP codes:** `401` unauth, `403` insufficient scope / forbidden, `400` malformed.

### 12.2 FastMCP auth: pick the right pattern

FastMCP 3.x offers **five patterns**. Choose by what your IdP supports:

| Pattern | When to use | Class |
|---|---|---|
| **TokenVerifier** | You control JWT issuance, or have existing JWT infra. Pure resource-server validation. | `JWTVerifier` / `StaticTokenVerifier` / `IntrospectionTokenVerifier` / `DebugTokenVerifier` |
| **RemoteAuthProvider** | IdP supports **Dynamic Client Registration** (Descope, WorkOS AuthKit, modern OIDC). | `RemoteAuthProvider` |
| **OAuthProxy** | Traditional providers without DCR (GitHub, Google, Azure, AWS, Discord). FastMCP presents DCR to clients while using fixed upstream credentials. | `OAuthProxy` |
| **OIDCProxy** | OIDC providers without DCR, simpler config than full OAuthProxy. | `OIDCProxy` |
| **Full OAuthProvider** | Air-gapped / specialized compliance. **Avoid unless necessary.** | `OAuthProvider` (abstract) |
| **MultiAuth** | Hybrid: OAuth interactive + JWT for backend services. | `MultiAuth` |

### 12.3 Token verifiers

```python
# JWT (production)
from fastmcp.server.auth.providers.jwt import JWTVerifier
verifier = JWTVerifier(
    jwks_uri="https://issuer/.well-known/jwks.json",     # auto key rotation
    # OR public_key="-----BEGIN PUBLIC KEY-----\n...",   # static PEM / HMAC secret
    issuer="https://issuer",
    audience="mcp-production-api",
    algorithm="RS256",                                    # or HS256, ES256, etc.
    required_scopes=["read"],
    http_client=None,                                     # custom httpx.AsyncClient
)

# Static (DEV ONLY — plain text)
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier
verifier = StaticTokenVerifier(
    tokens={"dev-token": {"client_id": "alice", "scopes": ["read"]}},
    required_scopes=["read"],
)

# RFC 7662 introspection (opaque tokens)
from fastmcp.server.auth.providers.introspection import IntrospectionTokenVerifier
verifier = IntrospectionTokenVerifier(
    introspection_url="https://as/oauth/introspect",
    client_id="resource-server",
    client_secret="...",
    client_auth_method="client_secret_basic",   # or "client_secret_post"
    required_scopes=["read"],
)

# Debug / custom (TESTING only)
from fastmcp.server.auth.providers.debug import DebugTokenVerifier
verifier = DebugTokenVerifier(
    validate=lambda token: token.startswith("test-"),
    client_id="test-client",
    scopes=["read"],
)

# Test key generation
from fastmcp.server.auth.providers.jwt import RSAKeyPair
kp = RSAKeyPair.generate()
token = kp.create_token(subject="alice", issuer="test", audience="api", scopes=["read"])
```

### 12.4 RemoteAuthProvider (DCR-capable IdPs)

```python
from fastmcp import FastMCP
from fastmcp.server.auth import RemoteAuthProvider
from fastmcp.server.auth.providers.jwt import JWTVerifier
from pydantic import AnyHttpUrl

token_verifier = JWTVerifier(
    jwks_uri="https://auth.company.com/.well-known/jwks.json",
    issuer="https://auth.company.com",
    audience="mcp-api",
)

auth = RemoteAuthProvider(
    token_verifier=token_verifier,
    authorization_servers=[AnyHttpUrl("https://auth.company.com")],
    base_url="https://api.company.com",
    allowed_client_redirect_uris=["http://localhost:*", "http://127.0.0.1:*"],
    scopes_supported=None,
)

mcp = FastMCP("Protected", auth=auth)
```

### 12.5 OAuthProxy (non-DCR providers)

```python
from fastmcp.server.auth import OAuthProxy
from fastmcp.server.auth.providers.jwt import JWTVerifier

auth = OAuthProxy(
    upstream_authorization_endpoint="https://provider.com/oauth/authorize",
    upstream_token_endpoint="https://provider.com/oauth/token",
    upstream_client_id="...",
    upstream_client_secret="...",
    token_verifier=JWTVerifier(...),
    base_url="https://your-server.com",
    redirect_path="/auth/callback",
    jwt_signing_key=None,                # production: os.environ["JWT_SIGNING_KEY"]
    client_storage=None,                 # production: encrypted RedisStore (see §7.17)
    require_authorization_consent=True,  # confused-deputy protection
)
```

**Built-in security:**
- Mandatory consent screens with session binding (confused-deputy protection)
- Upstream tokens never reach clients — FastMCP issues its own JWTs
- PKCE end-to-end (client↔proxy and proxy↔provider)
- CIMD support — clients can use HTTPS metadata URLs instead of DCR

**Production OAuth storage MUST be encrypted** (see §7.17 for `FernetEncryptionWrapper`).

### 12.6 OIDCProxy (simpler than OAuthProxy for OIDC providers)

```python
from fastmcp.server.auth.oidc_proxy import OIDCProxy

auth = OIDCProxy(
    config_url="https://provider.com/.well-known/openid-configuration",
    client_id="...",
    client_secret=None,            # optional for PKCE
    base_url="https://your-server.com",
    audience=None,                 # e.g., Auth0 API identifier
    required_scopes=["openid", "email"],
    redirect_path="/auth/callback",
    jwt_signing_key=None,
    client_storage=None,
)
```

### 12.7 Pre-built provider classes

Wrappers around the above patterns for popular IdPs. All take `base_url=` (your MCP server's public URL).

| Provider | Class | Import | Pattern |
|---|---|---|---|
| WorkOS AuthKit | `AuthKitProvider` | `fastmcp.server.auth.providers.workos` | RemoteAuthProvider |
| Descope | `DescopeProvider` | `fastmcp.server.auth.providers.descope` | RemoteAuthProvider |
| Google | `GoogleProvider` | `fastmcp.server.auth.providers.google` | OAuthProxy |
| GitHub | `GitHubProvider` | `fastmcp.server.auth.providers.github` | OAuthProxy |
| Azure (Entra) | `AzureProvider` / `AzureJWTVerifier` / `EntraOBOToken` | `fastmcp.server.auth.providers.azure` | OAuthProxy |
| Auth0 | `Auth0Provider` | `fastmcp.server.auth.providers.auth0` | OIDCProxy |
| Keycloak (26.6.0+) | **`KeycloakAuthProvider`** | `fastmcp.server.auth.providers.keycloak` | RemoteAuthProvider |
| PropelAuth | `PropelAuthProvider` | `fastmcp.server.auth.providers.propelauth` | Remote + introspection |
| AWS Cognito | `aws` provider | `fastmcp.server.auth.providers.aws` | OAuthProxy |
| Clerk | `clerk` provider | `fastmcp.server.auth.providers.clerk` | OAuthProxy |
| Discord | `discord` provider | `fastmcp.server.auth.providers.discord` | OAuthProxy |
| OCI (Oracle Cloud) | `oci` provider | `fastmcp.server.auth.providers.oci` | OAuthProxy |
| Scalekit | `scalekit` provider | `fastmcp.server.auth.providers.scalekit` | RemoteAuthProvider |
| Supabase | `supabase` provider | `fastmcp.server.auth.providers.supabase` | JWT |

(Constructor signatures for the most-used providers — Google, GitHub, Azure, Auth0, Descope, Keycloak, PropelAuth — are detailed below.)

### 12.8 Provider snippets

```python
# WorkOS AuthKit (DCR)
from fastmcp.server.auth.providers.workos import AuthKitProvider
auth = AuthKitProvider(authkit_domain="https://x.authkit.app",
                       base_url="https://my-server.com")

# GitHub
from fastmcp.server.auth.providers.github import GitHubProvider
auth = GitHubProvider(client_id="...", client_secret="...",
                      base_url="https://my-server.com")

# Google
from fastmcp.server.auth.providers.google import GoogleProvider
auth = GoogleProvider(
    client_id="...", client_secret="...",
    base_url="http://localhost:8000",
    required_scopes=["openid",
                     "https://www.googleapis.com/auth/userinfo.email"],
)

# Azure (tenant_id REQUIRED — "common" no longer allowed)
from fastmcp.server.auth.providers.azure import AzureProvider
auth = AzureProvider(
    client_id="...", client_secret="...", tenant_id="...",
    base_url="https://my-server.com",
    required_scopes=["api://.../access_as_user"],   # at least one required
    # optional: identifier_uri, additional_authorize_scopes,
    #           redirect_path, base_authority, jwt_signing_key, client_storage
)
# Companion classes:
#   AzureJWTVerifier   — validation-only deployments (use with RemoteAuthProvider)
#   EntraOBOToken      — On-Behalf-Of flows for downstream APIs

# Auth0
from fastmcp.server.auth.providers.auth0 import Auth0Provider
auth = Auth0Provider(
    config_url="https://your.auth0.com/.well-known/openid-configuration",
    client_id="...", client_secret="...",
    audience="https://your-api",
    base_url="http://localhost:8000",
)

# Descope
from fastmcp.server.auth.providers.descope import DescopeProvider
auth = DescopeProvider(
    config_url="https://api.descope.com/v1/apps/.../.well-known/openid-configuration",
    base_url="http://localhost:3000",
)

# Keycloak — class is KeycloakAuthProvider (not KeycloakProvider). Kwargs-only.
from fastmcp.server.auth.providers.keycloak import KeycloakAuthProvider
auth = KeycloakAuthProvider(
    realm_url="https://keycloak.example.com/realms/myrealm",
    base_url="https://my-mcp-server.example.com",
    required_scopes=["openid"],     # default
    audience=None,                  # recommended for prod
    token_verifier=None,            # default: JWTVerifier against realm JWKS
)

# PropelAuth
from fastmcp.server.auth.providers.propelauth import PropelAuthProvider
auth = PropelAuthProvider(
    auth_url="https://auth.yourdomain.com",
    introspection_client_id="...",
    introspection_client_secret="...",
    base_url="https://my-server.com",
    required_scopes=None,
    resource=None,                          # RFC 8707 resource indicator
    token_introspection_overrides=None,     # cache_ttl_seconds, max_cache_size, timeout_seconds
)
```

### 12.9 MultiAuth (compose multiple sources)

For hybrid setups: interactive clients via OAuth + backend services with raw JWTs.

```python
from fastmcp.server.auth import MultiAuth, OAuthProxy
from fastmcp.server.auth.providers.jwt import JWTVerifier

auth = MultiAuth(
    server=OAuthProxy(...),                  # optional — handles OAuth routes
    verifiers=[
        JWTVerifier(jwks_uri="https://issuer-a/.well-known/jwks.json", ...),
        JWTVerifier(jwks_uri="https://issuer-b/.well-known/jwks.json", ...),
    ],
    base_url="https://my-server.com",
    required_scopes=None,
)
```

Verification order: `server` first (if provided), then `verifiers` in list order. First valid `AccessToken` wins. All-None → 401. Verifiers-only mode serves **no** OAuth routes or metadata (suitable for internal-only).

```python
# JWT verifier
from fastmcp.server.auth.providers.jwt import JWTVerifier
auth = JWTVerifier(jwks_uri="https://.../.well-known/jwks.json",
                   issuer="https://issuer",
                   audience="mcp-server")
mcp = FastMCP("Protected", auth=auth)

# Static token verifier (DEV ONLY — stores tokens in plain text)
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier
auth = StaticTokenVerifier(
    tokens={
        "dev-alice-token": {"client_id": "alice@x.com",
                            "scopes": ["read:data", "write:data"]},
        "dev-guest-token": {"client_id": "guest", "scopes": ["read:data"]},
    },
    required_scopes=["read:data"],
)

# WorkOS AuthKit (DCR)
from fastmcp.server.auth.providers.workos import AuthKitProvider
auth = AuthKitProvider(authkit_domain="https://x.authkit.app",
                       base_url="https://my-server.com")

# GitHub
from fastmcp.server.auth.providers.github import GitHubProvider
auth = GitHubProvider(client_id="...", client_secret="...",
                      base_url="https://my-server.com")

# Google
from fastmcp.server.auth.providers.google import GoogleProvider
auth = GoogleProvider(
    client_id="...", client_secret="...",
    base_url="http://localhost:8000",
    required_scopes=["openid",
                     "https://www.googleapis.com/auth/userinfo.email"],
)

# Azure (tenant_id REQUIRED — "common" no longer allowed)
from fastmcp.server.auth.providers.azure import AzureProvider
auth = AzureProvider(
    client_id="...", client_secret="...", tenant_id="...",
    base_url="https://my-server.com",
    required_scopes=["api://.../access_as_user"],   # at least one required
    # optional: identifier_uri, additional_authorize_scopes,
    #           redirect_path, base_authority, jwt_signing_key, client_storage
)
# Companion classes in the same module:
#   AzureJWTVerifier   — validation-only deployments (use with RemoteAuthProvider)
#   EntraOBOToken      — On-Behalf-Of flows for downstream APIs

# Auth0
from fastmcp.server.auth.providers.auth0 import Auth0Provider
auth = Auth0Provider(
    config_url="https://your.auth0.com/.well-known/openid-configuration",
    client_id="...", client_secret="...",
    audience="https://your-api",
    base_url="http://localhost:8000",
)

# Descope
from fastmcp.server.auth.providers.descope import DescopeProvider
auth = DescopeProvider(
    config_url="https://api.descope.com/v1/apps/.../.well-known/openid-configuration",
    base_url="http://localhost:3000",
)

# Keycloak — note the class is KeycloakAuthProvider (not KeycloakProvider)
#   Requires Keycloak 26.6.0+ (DCR fix). Constructor is kwargs-only.
from fastmcp.server.auth.providers.keycloak import KeycloakAuthProvider
auth = KeycloakAuthProvider(
    realm_url="https://keycloak.example.com/realms/myrealm",
    base_url="https://my-mcp-server.example.com",
    required_scopes=["openid"],     # default
    audience=None,                  # recommended for prod
    token_verifier=None,            # default: JWTVerifier against realm JWKS
)

# PropelAuth
from fastmcp.server.auth.providers.propelauth import PropelAuthProvider
auth = PropelAuthProvider(
    auth_url="https://auth.yourdomain.com",
    introspection_client_id="...",
    introspection_client_secret="...",
    base_url="https://my-server.com",
    required_scopes=None,
    resource=None,                          # RFC 8707 resource indicator
    token_introspection_overrides=None,     # cache_ttl_seconds, max_cache_size, timeout_seconds
)

# Compose: OAuth proxy + supplementary JWT verifier (3.1+)
from fastmcp.server.auth import MultiAuth, OAuthProxy
auth = MultiAuth(
    server=OAuthProxy(issuer_url="...", client_id="...", client_secret="...",
                      base_url="https://my-server.com"),
    verifiers=[JWTVerifier(jwks_uri="...", issuer="...", audience="...")],
)
```

### 12.10 Full OAuth server (advanced — avoid)

FastMCP exposes `OAuthProvider` (abstract) for implementing a complete OAuth 2.1 authorization server inside your MCP server. **Avoid unless you genuinely need it** (air-gapped, specialized compliance). You must subclass and implement:

- Client mgmt: `get_client(client_id)`, `register_client(client_info)`
- Authorization: `authorize(client, params)`, `load_authorization_code(client, code)`
- Tokens: `exchange_authorization_code()`, `load_refresh_token()` / `exchange_refresh_token()`, `load_access_token()`, `verify_token()`, `revoke_token()`

Use **RemoteAuthProvider** or an **OAuthProxy** instead in almost all cases.

### 12.11 Official SDK auth

```python
from mcp.server.fastmcp import FastMCP
from mcp.server.auth.settings import AuthSettings

mcp = FastMCP(
    "my-server",
    auth=AuthSettings(
        issuer_url="https://auth.example.com",
        resource_server_url="https://mcp.example.com",
        required_scopes=["read", "write"],
    ),
    token_verifier=my_token_verifier,
)
```

### 12.12 Simple API-key auth (server-to-server)

```python
import hmac, os

async def verify_token(token: str) -> bool:
    expected = os.getenv("MCP_AUTH_TOKEN", "")
    return bool(expected) and hmac.compare_digest(token, expected)

# Official SDK
from mcp.server.fastmcp import FastMCP
mcp = FastMCP("my-server", token_verifier=verify_token)
```

Raw FastAPI:

```python
@app.middleware("http")
async def auth_middleware(request, call_next):
    if request.url.path == "/health":
        return await call_next(request)
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    expected = os.getenv("MCP_AUTH_TOKEN", "")
    if not expected or not hmac.compare_digest(token, expected):
        return JSONResponse({"error": "unauthorized"}, status_code=401)
    return await call_next(request)
```

> **Always use `hmac.compare_digest()`** for token comparison — `==` and `!=` short-circuit on the first differing byte (timing side-channel).

---

## 13. Middleware

FastMCP ships a real middleware system; the official SDK doesn't.

```python
from fastmcp.server.middleware import Middleware, MiddlewareContext
from fastmcp.server.middleware.logging        import LoggingMiddleware, StructuredLoggingMiddleware
from fastmcp.server.middleware.timing         import TimingMiddleware, DetailedTimingMiddleware
from fastmcp.server.middleware.caching        import ResponseCachingMiddleware
from fastmcp.server.middleware.rate_limiting  import (
    RateLimitingMiddleware, SlidingWindowRateLimitingMiddleware,
)
from fastmcp.server.middleware.error_handling import ErrorHandlingMiddleware, RetryMiddleware
from fastmcp.server.middleware                import PingMiddleware
from fastmcp.server.middleware.response_limiting import ResponseLimitingMiddleware

mcp.add_middleware(LoggingMiddleware(include_payloads=True, max_payload_length=1000))
mcp.add_middleware(RateLimitingMiddleware(max_requests_per_second=10.0, burst_capacity=20))
mcp.add_middleware(ErrorHandlingMiddleware(include_traceback=True))
```

### Custom middleware

```python
from fastmcp.exceptions import ToolError

class Guard(Middleware):
    async def on_call_tool(self, ctx: MiddlewareContext, call_next):
        if ctx.message.name == "danger":
            raise ToolError("denied")
        return await call_next(ctx)
```

**Hook surface:**
- Message level: `on_message`, `on_request`, `on_notification`
- Operation level: `on_call_tool`, `on_read_resource`, `on_get_prompt`, `on_list_tools`, `on_list_resources`, `on_list_prompts`, `on_list_resource_templates`, `on_initialize`

Execution order: ingress = registration order; egress = reverse.

---

## 14. Server Composition (mount, proxy, OpenAPI)

### 14.1 Mount (in-process, live)

```python
main = FastMCP("Main")
main.mount(weather)
main.mount(calendar, namespace="cal")
```

New tools added to `weather` later show up on `main`. **Prefer `mount()` over `import_server()`.**

### 14.2 `import_server()` (one-time copy — deprecated)

Still present in 3.x but **deprecated**; use `mount()` instead.

```python
main.import_server(subserver, prefix="api")    # signature: (server, prefix=None)
```

One-time copy of tools/resources/templates/prompts; not live. Server-level lifespans and config are NOT imported.

### 14.3 Proxy a remote/stdio server

```python
from fastmcp.server import create_proxy

proxy = create_proxy("http://example.com/mcp", name="P")     # remote streamable-HTTP
proxy = create_proxy("local_server.py")                       # stdio subprocess
proxy = create_proxy({
    "mcpServers": {
        "weather": {"url": "https://...", "transport": "http"},
        "fs":      {"command": "uvx", "args": ["mcp-server-filesystem", "/data"]},
    }
})
```

Lower-level: `FastMCPProxy`, `ProxyClient`, `ProxyProvider` in `fastmcp.server.providers.proxy` (the old `fastmcp.server.proxy` module is deprecated).

> `FastMCP.as_proxy(...)` still exists for backwards compatibility but is **deprecated** — use `create_proxy()` / `FastMCPProxy`.

### 14.4 OpenAPI → MCP

Generate an MCP server from an OpenAPI spec:

```python
import httpx
from fastmcp import FastMCP
from fastmcp.server.openapi import RouteMap, MCPType

mcp = FastMCP.from_openapi(
    openapi_spec=spec,                          # dict
    client=httpx.AsyncClient(base_url="https://api.example.com"),
    name="API",
    route_maps=[RouteMap(methods=["GET"],
                         pattern=r"^/users/.*",
                         mcp_type=MCPType.RESOURCE)],
    timeout=30.0,
)
```

GET routes become resources by default; other methods become tools. Customize via `route_maps`, `mcp_names`, `tags`, `mcp_component_fn`.

### 14.5 FastAPI → MCP

Still available in 3.x:

```python
from fastapi import FastAPI
from fastmcp import FastMCP

app = FastAPI(...)
mcp = FastMCP.from_fastapi(
    app=app,
    name="MyAPI",
    route_maps=[...],                # optional
    httpx_client_kwargs={"headers": {"Authorization": "Bearer ..."}},
    mcp_names=None,
    tags=None,
)
```

---

## 15. HTTP Client Best Practices

### 15.1 Shared async client via lifespan

```python
from contextlib import asynccontextmanager
import httpx

@asynccontextmanager
async def lifespan(server):
    async with httpx.AsyncClient(timeout=30.0) as client:
        yield {"http_client": client}

mcp = FastMCP("my-api-mcp", lifespan=lifespan)

@mcp.tool
async def search(query: str, ctx: Context) -> str:
    http = ctx.request_context.lifespan_context["http_client"]
    ...
```

Module-level `httpx.AsyncClient()` leaks connections — don't do it.

### 15.2 Rate limiting

```python
import asyncio, time

_last = 0.0
_lock = asyncio.Lock()
INTERVAL = 0.2   # 5 req/s

async def rate_limit():
    global _last
    async with _lock:
        elapsed = time.time() - _last
        if elapsed < INTERVAL:
            await asyncio.sleep(INTERVAL - elapsed)
        _last = time.time()
```

(Or use FastMCP's built-in `RateLimitingMiddleware` for inbound MCP rate limiting.)

### 15.3 Retry with exponential backoff

```python
MAX_RETRIES = 3
async def api_request_with_retry(http, method, url, **kw):
    for attempt in range(MAX_RETRIES + 1):
        try:
            r = await http.request(method, url, **kw)
            if r.status_code == 429:
                wait = min(int(r.headers.get("Retry-After", 2 ** attempt)), 30)
                await asyncio.sleep(wait)
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

### 15.4 Pagination helper

```python
async def fetch_all(http, endpoint, params=None, max_pages=10):
    out = []
    for page in range(1, max_pages + 1):
        data = (await http.get(endpoint,
                params={**(params or {}), "page": page, "per_page": 100})).json()
        items = data.get("items") or data.get("results") or []
        if not items: break
        out.extend(items)
        if len(items) < 100: break
    return out
```

---

## 16. Error Handling

### Two levels

**Protocol error** (JSON-RPC) — for bad JSON, unknown method, unknown tool:
```json
{"jsonrpc": "2.0", "id": 1,
 "error": {"code": -32601, "message": "Unknown tool: bad_tool"}}
```

**Tool execution error** (tool ran, failed) — for API errors, validation, business logic:
```json
{"jsonrpc": "2.0", "id": 1,
 "result": {"content": [{"type": "text", "text": "Error: API returned 503"}],
            "isError": true}}
```

> **2025-11-25 change:** tool **input validation** failures should now be returned as Tool Execution Errors (so the model can self-correct), not Protocol Errors.

### FastMCP behavior

- Raised exceptions → `isError: true` with exception message.
- Unknown tools → `isError: true`.
- Missing required args → `isError: true`.
- Set `mask_error_details=True` on the server to hide tracebacks; clients see a generic message.

Explicit:
```python
from fastmcp.exceptions import ToolError

@mcp.tool
async def search(query: str) -> str:
    if not query.strip():
        raise ToolError("query is required")
    ...
```

### Client side

```python
result = await client.call_tool("search", {"query": "test"})
if result.is_error:
    print(f"Tool error: {result.content[0].text}")
else:
    print(result.data)
```

---

## 17. Security

### Spec requirements (2025-11-25)

1. **HTTPS** for all production endpoints and non-localhost OAuth redirects.
2. **Origin validation** on Streamable HTTP — invalid Origin → **HTTP 403**. FastMCP 3.x does **not** ship a built-in Origin allowlist (no `TransportSecuritySettings`, no `allowed_origins=` kwarg, no `FASTMCP_ALLOWED_ORIGINS` env var). Either:
   - Add Starlette `CORSMiddleware` to the ASGI app (see §18), **or**
   - Run behind a reverse proxy that enforces `Host` / `Origin`, **or**
   - Use the official `mcp` SDK's `TransportSecuritySettings(allowed_origins=[...])` (see §8) if you need a built-in primitive.
   FastMCP's `fastmcp.server.auth.ssrf` module exists for **outbound** SSRF/DNS-pinning during JWKS/OIDC discovery — it does not protect inbound HTTP.
3. **Bind localhost** (`127.0.0.1`) when running locally; `0.0.0.0` only behind a trusted proxy.
4. **Authentication** for all non-stdio connections — use a FastMCP provider or `token_verifier`.
5. **Validate all tool inputs** — never trust client params.
6. **Rate limit** invocations (inbound MCP + outbound upstream).
7. **Sanitize error output** — log details server-side, return generic messages.
8. **Constant-time token compare** — `hmac.compare_digest()`, never `==`/`!=`.
9. **Non-deterministic session IDs** — UUID/JWT/hash, visible-ASCII.
10. **Bind sessions to user info** to prevent hijacking.
11. **No token passthrough** — server MUST NOT forward client-issued tokens to upstream APIs.
12. **URL elicitation**: never auto-open or pre-fetch; display full URL; isolated context.

### Confused deputy

Servers MUST require per-client consent before forwarding requests to third parties. Proxy servers with static client IDs MUST obtain user consent per dynamic client.

### Input validation

```python
# Clamp numerics
limit = max(1, min(args.get("limit", 10), 50))

# Validate enums
valid = {"relevance", "date_desc", "date_asc"}
sort = args.get("sort", "relevance")
if sort not in valid:
    sort = "relevance"

# Reject empty required
q = args.get("query", "").strip()
if not q:
    raise ToolError("query is required")
```

### Human in the loop

Clients SHOULD: show tool inputs before calling, prompt confirmation on destructive ops, display tool-invocation indicators, log usage.

---

## 18. Dockerfile & Deployment

### .dockerignore

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

### FastMCP Dockerfile

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

CMD ["python", "server.py"]
```

### Raw FastAPI Dockerfile

```dockerfile
FROM python:3.12-slim
RUN groupadd -r mcp && useradd -r -g mcp -s /sbin/nologin mcp
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .

USER mcp
EXPOSE 8001
HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8001/health')" || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8001"]
```

### Docker Compose

```yaml
services:
  my-api-mcp:
    build: ./my-api-mcp
    ports:
      - "127.0.0.1:8000:8000"     # localhost-bound; expose via reverse proxy
    env_file:
      - .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 30s
      timeout: 3s
      retries: 3
```

### CORS (when serving browser clients)

```python
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware

app = mcp.http_app(middleware=[
    Middleware(CORSMiddleware,
        allow_origins=["http://localhost:3000"],
        allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
        allow_headers=["mcp-protocol-version", "mcp-session-id",
                       "Authorization", "Content-Type"],
        expose_headers=["mcp-session-id"]),   # critical for browsers
])
```

### Stateless mode

Set when running behind a load balancer without session affinity:

```python
mcp.http_app(stateless_http=True)
# or env var
FASTMCP_STATELESS_HTTP=true
```

---

## 19. Testing

### 19.1 In-memory (preferred)

```python
import pytest
from fastmcp import Client
from myproj import mcp

@pytest.fixture
async def mcp_client():
    async with Client(mcp) as c:    # in-memory — no network
        yield c

async def test_search(mcp_client):
    r = await mcp_client.call_tool("search_items", {"query": "test"})
    assert not r.is_error

async def test_unknown(mcp_client):
    r = await mcp_client.call_tool("nope", {})
    assert r.is_error
```

### 19.2 curl (raw FastAPI)

```bash
# Initialize
curl -s -X POST http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | jq .

# Call a tool
curl -s -X POST http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_items","arguments":{"query":"test"}}}' \
  | jq '.result.content[0].text' -r | jq .
```

### 19.3 curl (FastMCP — SSE responses)

```bash
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# Response is SSE-framed:
# event: message
# data: {"jsonrpc":"2.0","id":1,"result":{...}}
```

### 19.4 MCP Inspector

```bash
# Stdio
npx @modelcontextprotocol/inspector uv run my-server

# Streamable HTTP — launch UI, then paste URL
npx @modelcontextprotocol/inspector

# Via FastMCP CLI
fastmcp dev inspector server.py
```

### 19.5 LibreChat config

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

---

## 20. CLI Tools & Inspector

### FastMCP CLI

```bash
fastmcp run <server>             # local file, factory, URL, or config
fastmcp dev inspector <server>   # MCP Inspector (was `fastmcp dev` in 2.x)
fastmcp dev apps <server>        # Prefab Apps preview
fastmcp install <server>         # Install into Claude Code, Claude Desktop,
                                 #   Cursor, Gemini CLI, Goose
fastmcp inspect <server>         # tools/resources/prompts summary
fastmcp list <server>            # list tools (and resources/prompts)
fastmcp call <server> <tool> ... # call a single tool
fastmcp discover                 # find configured MCP servers in editors
fastmcp generate-cli <server>    # scaffold a typed CLI from tool schemas
fastmcp project prepare          # pre-install deps into a reusable uv project
fastmcp auth cimd ...            # create/validate CIMD OAuth docs
fastmcp version
```

### Official Inspector

`@modelcontextprotocol/inspector` is an interactive dev tool — browse tools/resources/prompts, run calls, view requests/responses, test auth flows.

```bash
npx @modelcontextprotocol/inspector <command> [args...]
# e.g.
npx @modelcontextprotocol/inspector uv run my-server
```

For Streamable HTTP servers, run with no args and paste the URL in the UI.

---

## 21. Checklist

### Protocol compliance
- [ ] `protocolVersion` is `2025-11-25`
- [ ] Single `POST /mcp` endpoint handles all JSON-RPC messages
- [ ] `initialize` returns `protocolVersion`, `serverInfo`, `capabilities`
- [ ] `notifications/initialized` returns 202 or empty result
- [ ] `ping` returns empty result
- [ ] `tools/list` returns array of tool defs
- [ ] `tools/call` dispatches correctly
- [ ] Unknown tools → result with `isError: true` (not JSON-RPC error)
- [ ] Tool input-validation errors → `isError: true` (2025-11-25 change)
- [ ] Unknown methods → JSON-RPC `-32601`
- [ ] Invalid JSON → `-32700`
- [ ] Invalid `Origin` → **HTTP 403**
- [ ] `MCP-Protocol-Version` accepted/required on post-init requests
- [ ] `Mcp-Session-Id` is cryptographically secure, visible-ASCII

### Tool quality
- [ ] Every tool has a 50–150 word description
- [ ] Every parameter has a description
- [ ] Required params listed in `required`
- [ ] Optional params have defaults
- [ ] Enum params use `enum`
- [ ] Input validation before API calls
- [ ] Annotations set where applicable (`readOnlyHint`, `destructiveHint`, etc.)
- [ ] Icons set for tools where useful (2025-11-25)

### Server features
- [ ] `/health` endpoint
- [ ] Rate limiting (inbound + upstream)
- [ ] 30s default HTTP timeout
- [ ] Structured errors (no raw tracebacks unless dev mode)
- [ ] Logging with request context
- [ ] Env-based config (no hardcoded secrets)
- [ ] Dockerfile with healthcheck
- [ ] CORS configured if serving browser clients
- [ ] Stateless mode if behind LB without session affinity

### Client features
- [ ] `initialize` → `notifications/initialized` handshake
- [ ] Session ID on all post-init requests
- [ ] `MCP-Protocol-Version` header on post-init requests
- [ ] Sampling callback (if server samples)
- [ ] Elicitation callback (form **and** URL modes)
- [ ] Roots callback (if server requests roots)
- [ ] URL elicitation: display full URL, isolated open, no pre-fetch
- [ ] Tool-error handling (`isError: true`)
- [ ] Configurable timeouts
- [ ] DELETE on session shutdown

---

## 22. Reference Links

### Spec
- [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25)
- [2025-11-25 Changelog](https://modelcontextprotocol.io/specification/2025-11-25/changelog)
- [Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [Elicitation (form + URL)](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation)
- [Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [Resources](https://modelcontextprotocol.io/specification/2025-11-25/server/resources)
- [Prompts](https://modelcontextprotocol.io/specification/2025-11-25/server/prompts)

### Python implementations
- [PrefectHQ FastMCP repo](https://github.com/PrefectHQ/fastmcp)
- [FastMCP docs](https://gofastmcp.com)
- [FastMCP LLM-friendly docs](https://gofastmcp.com/llms-full.txt)
- [FastMCP changelog](https://gofastmcp.com/changelog.md)
- [Upgrade 2 → 3](https://gofastmcp.com/getting-started/upgrading/from-fastmcp-2.md)
- [Upgrade from official SDK](https://gofastmcp.com/getting-started/upgrading/from-mcp-sdk.md)
**FastMCP docs (each URL accepts `.md` suffix for plain markdown):**

*Servers — core:*
- [Overview](https://gofastmcp.com/servers/server.md) · [Tools](https://gofastmcp.com/servers/tools.md) · [Resources](https://gofastmcp.com/servers/resources.md) · [Prompts](https://gofastmcp.com/servers/prompts.md) · [Context](https://gofastmcp.com/servers/context.md)

*Servers — features (3.x):*
- [Tasks](https://gofastmcp.com/servers/tasks.md) · [Dependency injection](https://gofastmcp.com/servers/dependency-injection.md) · [Lifespan](https://gofastmcp.com/servers/lifespan.md) · [Pagination](https://gofastmcp.com/servers/pagination.md) · [Versioning](https://gofastmcp.com/servers/versioning.md) · [Storage backends](https://gofastmcp.com/servers/storage-backends.md) · [Telemetry](https://gofastmcp.com/servers/telemetry.md) · [Middleware](https://gofastmcp.com/servers/middleware.md)

*Servers — composition:*
- [Composition](https://gofastmcp.com/servers/composition.md) · [Proxy](https://gofastmcp.com/servers/proxy.md)

*Servers — auth & authorization:*
- [Authentication overview](https://gofastmcp.com/servers/auth/authentication.md) · [Authorization](https://gofastmcp.com/servers/authorization.md)
- [Token verification](https://gofastmcp.com/servers/auth/token-verification.md) · [Remote OAuth](https://gofastmcp.com/servers/auth/remote-oauth.md) · [OAuth Proxy](https://gofastmcp.com/servers/auth/oauth-proxy.md) · [OIDC Proxy](https://gofastmcp.com/servers/auth/oidc-proxy.md) · [Full OAuth server](https://gofastmcp.com/servers/auth/full-oauth-server.md) · [Multi-auth](https://gofastmcp.com/servers/auth/multi-auth.md)

*Integrations (one `.md` page each under `/integrations/`):*
- IdPs: `auth0`, `authkit`, `aws-cognito`, `azure`, `descope`, `discord`, `github`, `google`, `keycloak`, `propelauth`, `scalekit`, `supabase`
- Authorization: `eunomia-authorization`, `permit`
- Hosts: `claude-code`, `claude-desktop`, `cursor`, `chatgpt`, `gemini`, `gemini-cli`, `goose`
- Frameworks: `fastapi`, `openapi`, `anthropic`, `openai`, `pydantic-ai`
- Misc: `mcp-json-configuration`, `oci`

*Clients:*
- [Client](https://gofastmcp.com/clients/client.md) · [Transports](https://gofastmcp.com/clients/transports.md) · [CLI](https://gofastmcp.com/clients/cli.md) · [Client-only package](https://gofastmcp.com/clients/client-only-package.md)
- Capabilities: [Tools](https://gofastmcp.com/clients/tools.md) · [Resources](https://gofastmcp.com/clients/resources.md) · [Prompts](https://gofastmcp.com/clients/prompts.md) · [Sampling](https://gofastmcp.com/clients/sampling.md) · [Elicitation](https://gofastmcp.com/clients/elicitation.md) · [Roots](https://gofastmcp.com/clients/roots.md) · [Logging](https://gofastmcp.com/clients/logging.md) · [Progress](https://gofastmcp.com/clients/progress.md) · [Notifications](https://gofastmcp.com/clients/notifications.md) · [Tasks](https://gofastmcp.com/clients/tasks.md)
- Client auth: [Bearer](https://gofastmcp.com/clients/auth/bearer.md) · [OAuth](https://gofastmcp.com/clients/auth/oauth.md) · [CIMD](https://gofastmcp.com/clients/auth/cimd.md)

*Apps (Prefab interactive UIs — new in 3.x):*
- [Overview](https://gofastmcp.com/apps/overview.md) · [Quickstart](https://gofastmcp.com/apps/quickstart.md) · [Architecture](https://gofastmcp.com/apps/architecture.md) · [Development](https://gofastmcp.com/apps/development.md) · [Prefab](https://gofastmcp.com/apps/prefab.md) · [Generative](https://gofastmcp.com/apps/generative.md) · [Low-level](https://gofastmcp.com/apps/low-level.md)
- Providers: `approval`, `choice`, `file-upload`, `form` (under `/apps/providers/`)

*CLI:*
- [Overview](https://gofastmcp.com/cli/overview.md) · [Running](https://gofastmcp.com/cli/running.md) · [Inspecting](https://gofastmcp.com/cli/inspecting.md) · [Install (MCP host)](https://gofastmcp.com/cli/install-mcp.md) · [Client](https://gofastmcp.com/cli/client.md) · [Generate CLI](https://gofastmcp.com/cli/generate-cli.md) · [Auth](https://gofastmcp.com/cli/auth.md)

*Deployment:*
- [Running a server](https://gofastmcp.com/deployment/running-server.md) · [HTTP](https://gofastmcp.com/deployment/http.md) · [Server configuration](https://gofastmcp.com/deployment/server-configuration.md) · [Sandboxed agents](https://gofastmcp.com/deployment/sandboxed-agents.md) · [Prefect Horizon](https://gofastmcp.com/deployment/prefect-horizon.md)

*Patterns & dev:*
- [Testing](https://gofastmcp.com/patterns/testing.md) · [CLI patterns](https://gofastmcp.com/patterns/cli.md) · [Contrib](https://gofastmcp.com/patterns/contrib.md)
- [Contributing](https://gofastmcp.com/development/contributing.md) · [Releases](https://gofastmcp.com/development/releases.md) · [Tests](https://gofastmcp.com/development/tests.md) · [v3 features](https://gofastmcp.com/development/v3-notes/v3-features.md)

*Python SDK API reference:* every module documented under [`/python-sdk/`](https://github.com/PrefectHQ/fastmcp/tree/main/docs/python-sdk) (e.g. `fastmcp-server-auth-providers-keycloak.mdx`).
- [Official Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [`mcp` on PyPI](https://pypi.org/project/mcp/)

### Other SDKs (official)
- [TypeScript](https://github.com/modelcontextprotocol/typescript-sdk) — `npm install @modelcontextprotocol/sdk`
- [Kotlin](https://github.com/modelcontextprotocol/kotlin-sdk) (with JetBrains)
- [Java](https://github.com/modelcontextprotocol/java-sdk) (with Spring AI)
- [C#](https://github.com/modelcontextprotocol/csharp-sdk) (with Microsoft)
- [Swift](https://github.com/modelcontextprotocol/swift-sdk) (with Loopwork)
- [Rust](https://github.com/modelcontextprotocol/rust-sdk)
- [Go](https://github.com/modelcontextprotocol/go-sdk) (with Google)
- [Ruby](https://github.com/modelcontextprotocol/ruby-sdk) (with Shopify)

### Tools
- [MCP Inspector](https://github.com/modelcontextprotocol/inspector) — `npx @modelcontextprotocol/inspector`
