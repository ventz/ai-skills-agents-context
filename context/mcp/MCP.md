# MCP Development Guide (Server & Client)

> By: Ventz Petkov <ventz@vpetkov.net>


## Purpose

This document covers everything needed to build MCP (Model Context Protocol) **servers** and **clients** using the Python SDK v2. It targets **spec version `2025-11-25`** and the `MCPServer` class (renamed from `FastMCP` in SDK v2). Feed this to Claude Code alongside your API spec to produce working MCP servers and clients.

---

## Table of Contents

1. [Protocol Overview](#1-protocol-overview)
2. [Transport: Streamable HTTP](#2-transport-streamable-http)
3. [Transport: Stdio](#3-transport-stdio)
4. [Lifecycle & Session Management](#4-lifecycle--session-management)
5. [JSON-RPC 2.0 Message Format](#5-json-rpc-20-message-format)
6. [Server Development with MCPServer SDK](#6-server-development-with-mcpserver-sdk)
7. [Server Template (Raw FastAPI)](#7-server-template-raw-fastapi)
8. [Client Development](#8-client-development)
9. [Elicitation](#9-elicitation)
10. [Authentication & Authorization](#10-authentication--authorization)
11. [HTTP Client Best Practices](#11-http-client-best-practices)
12. [Error Handling](#12-error-handling)
13. [Security](#13-security)
14. [Dockerfile & Deployment](#14-dockerfile--deployment)
15. [Testing](#15-testing)
16. [Checklist](#16-checklist)

---

## 1. Protocol Overview

MCP uses **JSON-RPC 2.0** over HTTP or stdio. All messages MUST be UTF-8 encoded.

**Protocol Version**: `2025-11-25` (latest) — previous: `2025-06-18`, `2025-03-26`

**Architecture**: Client-Host-Server model:
- **Hosts** are LLM applications (e.g., Claude Desktop, LibreChat) that manage client connections
- **Clients** connect to servers and expose capabilities to the host/LLM
- **Servers** provide capabilities to clients

**Core concepts:**
- **Tools**: Functions the LLM can call (query APIs, perform computations)
- **Resources**: Read-only data the LLM can access (files, database records, API data)
- **Prompts**: Pre-built prompt templates with arguments
- **Sampling**: Server-initiated LLM requests (the server asks the client to run inference)
- **Elicitation**: Server-initiated user input requests (forms or URL redirects)

**For most API wrappers, you only need Tools.**

---

## 2. Transport: Streamable HTTP

### Single Endpoint

The server MUST provide **one HTTP endpoint** (the "MCP endpoint") that handles POST, GET, and DELETE:

```
POST   /mcp    ← All client messages (requests, notifications, responses)
GET    /mcp    ← SSE stream for server-initiated messages (requires session ID)
DELETE /mcp    ← Session termination (requires session ID)
GET    /health ← Health check (not part of MCP spec, but best practice)
```

### POST /mcp Requirements

Every JSON-RPC message from the client is a new HTTP POST:

| Requirement | Detail |
|-------------|--------|
| Client MUST include `Accept` header | `application/json, text/event-stream` (both required, `*/*` is rejected by the SDK) |
| Body MUST be | Single JSON-RPC request, notification, or response (batch arrays not supported by SDK) |
| Response for requests | `Content-Type: text/event-stream` with SSE `event: message` + `data:` lines (the SDK always uses SSE for responses) |
| Response for notifications | HTTP 202 Accepted, empty body |
| Response for errors | HTTP 4xx/5xx with `Content-Type: application/json` and JSON-RPC error body |

> **SDK behavior note (mcp >= 1.x):** The Python SDK's `MCPServer` always returns responses as SSE events (`text/event-stream`), even for simple request/response. The JSON-RPC response is inside `event: message\ndata: {...}\n\n`. Raw FastAPI servers can return `application/json` directly.

### GET /mcp (SSE Stream)

Opens a long-lived SSE stream for server-initiated messages. Requires:
- `Accept: text/event-stream` header (returns 406 without it)
- Valid `Mcp-Session-Id` header (returns 400 without it, 404 for invalid)

Supports resumability via `Last-Event-ID` header — the server replays missed events.

### DELETE /mcp (Session Termination)

Terminates a session. Requires `Mcp-Session-Id` header. Returns 200 with empty body on success, 400 if missing session ID, 404 if session not found.

### Headers

| Header | Direction | Required | Description |
|--------|-----------|----------|-------------|
| `Accept` | Client → Server | MUST | `application/json, text/event-stream` (must list both explicitly) |
| `Content-Type` | Client → Server | MUST | `application/json` (returns 400 plain text if missing/wrong) |
| `Content-Type` | Server → Client | MUST | `text/event-stream` (for success responses) or `application/json` (for errors) |
| `MCP-Protocol-Version` | Client → Server | SHOULD | `2025-11-25` (spec version negotiation) |
| `Mcp-Session-Id` | Both | MUST (after init) | Session identifier returned by server on `initialize` |
| `Cache-Control` | Server → Client | Auto | `no-cache, no-transform` (set by SDK on SSE responses) |
| `X-Accel-Buffering` | Server → Client | Auto | `no` (prevents reverse proxy buffering of SSE) |

---

## 3. Transport: Stdio

Stdio transport uses subprocess communication — the client launches the server as a child process:

- **Client → Server**: Messages written to the server process's **stdin**
- **Server → Client**: Messages written to the server process's **stdout**
- **Diagnostics**: Server writes to **stderr** (not part of protocol)

Messages are newline-delimited JSON-RPC. No HTTP overhead, no session IDs.

**When to use stdio**: Local integrations (e.g., Claude Desktop, editor plugins) where the client can launch the server as a subprocess.

**When to use Streamable HTTP**: Remote/production deployments, multi-user servers, web-accessible services.

---

## 4. Lifecycle & Session Management

### Initialization Flow

```
Client                          Server
  │                               │
  ├─── POST initialize ──────────►│
  │◄── InitializeResult ──────────┤  (server MAY set Mcp-Session-Id header)
  │                               │
  ├─── POST initialized ─────────►│
  │◄── 202 Accepted ──────────────┤
  │                               │
  │    ══ Normal Operations ══    │
  │                               │
  ├─── POST tools/list ──────────►│
  │◄── tools list ────────────────┤
  │                               │
  ├─── POST tools/call ──────────►│
  │◄── tool result ───────────────┤
```

### Initialize Request (from client)

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {
      "sampling": {},
      "elicitation": {},
      "roots": {"listChanged": true}
    },
    "clientInfo": {"name": "client-name", "version": "1.0.0"}
  }
}
```

### Initialize Response (from server)

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-11-25",
    "serverInfo": {"name": "my-api-mcp", "version": "1.0.0"},
    "capabilities": {
      "tools": {},
      "resources": {"subscribe": true},
      "prompts": {}
    },
    "instructions": "Optional: tell the LLM how/when to use this server"
  }
}
```

### Session Management

- Server assigns a session ID via `mcp-session-id` response header on InitializeResult
- Client MUST include `Mcp-Session-Id` on all subsequent requests (POST, GET, DELETE)
- Session IDs MUST be non-deterministic (e.g., 32-character hex strings)
- Requests with missing session ID → HTTP 400 (`"Bad Request: Missing session ID"`)
- Requests with invalid/expired session ID → HTTP 404 (`"Session not found"`)
- Client sends HTTP DELETE to `/mcp` with session ID to terminate the session → HTTP 200 empty body

**MCPServer handles sessions automatically.** If using raw FastAPI, session management is optional — skip it unless you need per-session state.

---

## 5. JSON-RPC 2.0 Message Format

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "method_name",
  "params": {}
}
```

### Notification (no `id`, no response expected)

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized"
}
```

### Success Response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { ... }
}
```

### Error Response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found: bad_method"
  }
}
```

### Standard JSON-RPC Error Codes

| Code | Meaning |
|------|---------|
| `-32700` | Parse error (invalid JSON) |
| `-32600` | Invalid request |
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32603` | Internal error |
| `-32002` | Resource not found |
| `-32042` | URLElicitationRequiredError (new in 2025-11-25) |

---

## 6. Server Development with MCPServer SDK

### Dependencies

```bash
# Using uv (recommended)
uv add "mcp[cli]"

# Or pip
pip install "mcp[cli]"
```

This installs the `mcp` package which includes `MCPServer`, `uvicorn`, `starlette`, `pydantic`, and all transport support. **Do not install the separate `fastmcp` PyPI package** — that is a third-party fork, not the official SDK.

```toml
# pyproject.toml (if managing manually)
[project]
dependencies = [
    "mcp[cli]>=1.26.0",
    "httpx>=0.28.1",        # For upstream API calls
]
```

### Minimal Single-File Server

```python
# server.py — Complete MCP server with streamable-http transport
from mcp.server.mcpserver import MCPServer

mcp = MCPServer("my-api-mcp")


@mcp.tool()
def hello(name: str) -> str:
    """Greet someone by name. Use when the user wants a personalized greeting.

    Args:
        name: The person's name to greet
    """
    return f"Hello, {name}!"


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
    # Serves at http://localhost:8000/mcp
    # Sessions, SSE, DELETE — all handled automatically
```

Run with: `python server.py` or `uv run server.py`

### MCPServer Constructor

```python
MCPServer(
    name: str | None = None,             # Server identifier
    title: str | None = None,            # Human-readable title
    description: str | None = None,      # Server description
    instructions: str | None = None,     # Instructions for the LLM
    version: str | None = None,          # Server version
    website_url: str | None = None,      # Website URL
    icons: list[Icon] | None = None,     # Icon metadata (new in 2025-11-25)
    auth_server_provider=None,           # OAuth authorization server
    token_verifier=None,                 # Token verification
    *,
    tools: list[Tool] | None = None,     # Pre-built tool list
    debug: bool = False,                 # Debug mode
    log_level: str = "INFO",             # DEBUG/INFO/WARNING/ERROR/CRITICAL
    lifespan=None,                       # Async context manager for startup/shutdown
    auth: AuthSettings | None = None,    # Authentication settings
)
```

Environment variables with `MCP_` prefix override defaults (e.g., `MCP_DEBUG=true`).

### Transport Options

```python
# Streamable HTTP (recommended for production/remote)
mcp.run(transport="streamable-http")              # http://localhost:8000/mcp
mcp.run(transport="streamable-http", host="0.0.0.0", port=9000)

# Stdio (for local CLI integrations like Claude Desktop)
mcp.run(transport="stdio")

# SSE (legacy, still supported)
mcp.run(transport="sse")
```

#### ASGI Mount (embed in existing FastAPI/Starlette app)

```python
from fastapi import FastAPI
from mcp.server.mcpserver import MCPServer

app = FastAPI()
mcp = MCPServer("my-api-mcp")

# Register tools on mcp...

# Mount as sub-application
mcp_app = mcp.streamable_http_app(streamable_http_path="/mcp")
app.mount("/", mcp_app)
```

### Tools

#### Decorator Pattern

```python
@mcp.tool(
    name="search_items",           # Optional, defaults to function name
    title="Search Items",          # Optional display name
    description="...",             # Optional, defaults to docstring
    annotations=ToolAnnotations(   # Optional behavioral hints
        readOnlyHint=True,
        openWorldHint=True,
    ),
    icons=[Icon(url="https://...")],  # Optional icon metadata
    structured_output=None,        # None=auto, True=force, False=disable
)
async def search_items(query: str, limit: int = 10) -> str:
    """Search for items by keyword. Returns matching results.

    Args:
        query: Search keywords or phrase
        limit: Max results to return (default 10, max 50)
    """
    result = await api_request("GET", "/search", params={"q": query})
    return json.dumps(result, indent=2)
```

#### Context Injection

Tools can request a `Context` object by adding a type-annotated parameter:

```python
from mcp.server.mcpserver import MCPServer, Context

@mcp.tool()
async def long_running_task(data: str, ctx: Context) -> str:
    """Process data with progress reporting."""
    await ctx.info("Starting processing...")
    await ctx.report_progress(0.5, total=1.0, message="Halfway done")

    # Read a resource from within a tool
    contents = await ctx.read_resource("resource://config")

    # Elicit user input
    result = await ctx.elicit("Please confirm:", schema=ConfirmSchema)

    await ctx.report_progress(1.0, total=1.0, message="Complete")
    return f"Processed: {data}"
```

**Context methods:**
- `await ctx.report_progress(progress, total=None, message=None)` — progress notification
- `await ctx.read_resource(uri)` — read a server resource
- `await ctx.elicit(message, schema)` — request user input (form mode)
- `await ctx.elicit_url(message, url, elicitation_id)` — request user input (URL mode)
- `await ctx.log(level, message)` — structured logging
- `ctx.debug(msg)`, `ctx.info(msg)`, `ctx.warning(msg)`, `ctx.error(msg)` — convenience logging
- `ctx.request_id` — unique request ID
- `ctx.client_id` — client identifier (if available)
- `ctx.session` — underlying session for advanced usage

#### Structured Output

When a tool returns a typed value (not `str`), the SDK auto-generates `outputSchema` and includes `structuredContent` alongside `content`:

```python
from pydantic import BaseModel

class SearchResult(BaseModel):
    query: str
    total: int
    items: list[dict]

@mcp.tool()
async def search(query: str) -> SearchResult:
    """Search with structured results."""
    return SearchResult(query=query, total=1, items=[{"title": "Result 1"}])
```

Control behavior with `structured_output` parameter:
- `None` (default): Auto-detect from return type
- `True`: Force structured output (error if return type not serializable)
- `False`: Force unstructured only

#### Tool Annotations

Hints for clients about tool behavior (new in 2025-11-25):

```python
from mcp.types import ToolAnnotations

@mcp.tool(annotations=ToolAnnotations(
    readOnlyHint=True,      # Tool doesn't modify state
    destructiveHint=False,   # Tool is not destructive
    idempotentHint=True,     # Safe to retry
    openWorldHint=True,      # Interacts with external systems
))
async def fetch_data(url: str) -> str:
    ...
```

### Resources

```python
# Static resource
@mcp.resource("resource://config")
def get_config() -> str:
    """Server configuration."""
    return json.dumps({"version": "1.0", "env": "production"})

# Template resource with parameters
@mcp.resource("resource://{city}/weather")
async def get_weather(city: str) -> str:
    """Weather for a specific city."""
    data = await fetch_weather(city)
    return f"Weather for {city}: {data}"
```

Resource types: `TextResource`, `BinaryResource`, `FunctionResource`, `FileResource`, `HttpResource`, `DirectoryResource`.

### Prompts

```python
from mcp.server.mcpserver.prompts import UserMessage, AssistantMessage

@mcp.prompt()
async def code_review(code: str, language: str = "python") -> list:
    """Review code for quality issues.

    Args:
        code: The code to review
        language: Programming language (default: python)
    """
    return [
        UserMessage(
            content=f"Please review this {language} code for quality issues:\n\n```{language}\n{code}\n```"
        )
    ]
```

Prompts can return `str`, `Message`, `dict`, or `list` of any of those. Context injection works the same as tools.

### Lifespan Management

```python
from contextlib import asynccontextmanager
import httpx

@asynccontextmanager
async def lifespan(server: MCPServer):
    """Manage shared resources across server lifetime."""
    async with httpx.AsyncClient(timeout=30.0) as client:
        # Store on server for tools to access
        yield {"http_client": client}

mcp = MCPServer("my-api-mcp", lifespan=lifespan)
```

### Multi-Module Pattern

```
my-api-mcp/
├── server.py              # MCPServer setup + run
├── tools/
│   ├── search.py          # register_search_tools(mcp)
│   ├── items.py           # register_item_tools(mcp)
│   └── admin.py           # register_admin_tools(mcp)
├── core/
│   ├── config.py          # Environment config
│   └── client.py          # Shared httpx client
├── pyproject.toml
└── Dockerfile
```

```python
# server.py
from mcp.server.mcpserver import MCPServer
from tools.search import register_search_tools
from tools.items import register_item_tools

mcp = MCPServer("my-api-mcp")
register_search_tools(mcp)
register_item_tools(mcp)

if __name__ == "__main__":
    mcp.run(transport="streamable-http")
```

```python
# tools/search.py
import json
from mcp.server.mcpserver import MCPServer
from core.client import api_request

def register_search_tools(mcp: MCPServer):

    @mcp.tool()
    async def search_items(query: str, limit: int = 10) -> str:
        """Search for items by keyword. Returns matching results with title and URL.

        Args:
            query: Search keywords or phrase
            limit: Max results to return (default 10, max 50)
        """
        result = await api_request("GET", "/search", params={"q": query, "limit": limit})
        return json.dumps(result, indent=2)
```

### Custom HTTP Routes

```python
from starlette.requests import Request
from starlette.responses import JSONResponse

@mcp.custom_route("/health", methods=["GET"])
async def health(request: Request) -> JSONResponse:
    return JSONResponse({"status": "healthy"})
```

### What MCPServer Handles Automatically

| Feature | Details |
|---------|---------|
| **Session management** | Assigns non-deterministic session IDs, validates on all requests |
| **Content negotiation** | Enforces `Accept: application/json, text/event-stream` |
| **SSE responses** | All request responses sent as `text/event-stream` with `event: message` |
| **GET /mcp** | SSE stream for server-initiated messages |
| **DELETE /mcp** | Session termination with 200 empty body |
| **Tool schemas** | Auto-generated `inputSchema` and `outputSchema` from type hints |
| **Structured output** | Returns `structuredContent` alongside `content` for typed returns |
| **Error handling** | Missing args → `isError: true`; unknown tools → `isError: true` |
| **HTTP methods** | PUT/PATCH/HEAD → 405 with `Allow: GET, POST, DELETE` |
| **Trailing slash** | `/mcp/` → 307 redirect to `/mcp` |

---

## 7. Server Template (Raw FastAPI)

For cases where you need full HTTP control (CORS, custom middleware, etc.):

```python
"""
{API_NAME} MCP Server — Raw FastAPI implementation
"""
import os
import json
import logging
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import httpx

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="{API_NAME} MCP Server")

SERVER_NAME = "{api-name}-mcp"
SERVER_VERSION = "1.0.0"
API_BASE_URL = os.getenv("API_BASE_URL", "https://api.example.com/v1")
API_KEY = os.getenv("API_KEY", "")
http_client = httpx.AsyncClient(timeout=30.0)

TOOLS = [
    {
        "name": "search_items",
        "description": "Search for items by keyword.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search keywords"},
                "limit": {"type": "integer", "description": "Max results (default 10)", "default": 10}
            },
            "required": ["query"]
        }
    }
]


async def dispatch_tool(tool_name: str, arguments: dict) -> dict | None:
    if tool_name == "search_items":
        resp = await http_client.get(
            f"{API_BASE_URL}/search",
            params={"q": arguments.get("query", ""), "limit": arguments.get("limit", 10)},
            headers={"Authorization": f"Bearer {API_KEY}"} if API_KEY else {},
        )
        resp.raise_for_status()
        return resp.json()
    return None


@app.post("/mcp")
async def mcp_endpoint(request: Request):
    try:
        body = await request.json()
    except json.JSONDecodeError:
        return JSONResponse({"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}})

    method = body.get("method", "")
    params = body.get("params", {})
    request_id = body.get("id")

    if method == "initialize":
        return JSONResponse({
            "jsonrpc": "2.0", "id": request_id,
            "result": {
                "protocolVersion": "2025-11-25",
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "capabilities": {"tools": {}},
                "instructions": "Use search_items to find resources."
            }
        })

    if method == "notifications/initialized":
        return JSONResponse({"jsonrpc": "2.0", "id": request_id, "result": {}}, status_code=202)

    if method == "ping":
        return JSONResponse({"jsonrpc": "2.0", "id": request_id, "result": {}})

    if method == "tools/list":
        return JSONResponse({"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}})

    if method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})
        try:
            result = await dispatch_tool(tool_name, arguments)
            if result is None:
                return JSONResponse({
                    "jsonrpc": "2.0", "id": request_id,
                    "error": {"code": -32601, "message": f"Unknown tool: {tool_name}"}
                })
            return JSONResponse({
                "jsonrpc": "2.0", "id": request_id,
                "result": {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}
            })
        except Exception as e:
            return JSONResponse({
                "jsonrpc": "2.0", "id": request_id,
                "result": {"content": [{"type": "text", "text": f"Error: {e}"}], "isError": True}
            })

    return JSONResponse({
        "jsonrpc": "2.0", "id": request_id,
        "error": {"code": -32601, "message": f"Method not found: {method}"}
    })


@app.get("/health")
async def health():
    return {"status": "healthy", "server": SERVER_NAME, "version": SERVER_VERSION}
```

### When to Use Raw FastAPI vs MCPServer

| Factor | MCPServer (Recommended) | Raw FastAPI |
|--------|------------------------|-------------|
| Complexity | Low — protocol handled for you | High — implement protocol yourself |
| Dependencies | `mcp[cli]` | `fastapi`, `uvicorn` |
| Sessions | Automatic | Manual or skip |
| SSE/streaming | Automatic | Manual |
| CORS support | Not built-in (SDK limitation) | Add via middleware |
| Custom middleware | Via `@custom_route` | Full FastAPI control |

**Recommendation**: Start with MCPServer. Only use Raw FastAPI if you need CORS support for browser clients or custom middleware.

---

## 8. Client Development

### High-Level Client (Recommended)

The `Client` class is the simplest way to connect to an MCP server:

```python
from mcp.client import Client

async with Client("https://mcp.example.com/mcp") as client:
    # List available tools
    tools = await client.list_tools()
    for tool in tools.tools:
        print(f"{tool.name}: {tool.description}")

    # Call a tool
    result = await client.call_tool("search_items", {"query": "machine learning"})
    print(result.content[0].text)
```

#### Client Constructor

```python
Client(
    server,                                    # URL string, MCPServer, or Transport
    raise_exceptions: bool = False,            # Raise on tool errors
    read_timeout_seconds: float | None = None, # Read timeout
    sampling_callback=None,                    # Handle sampling requests
    elicitation_callback=None,                 # Handle elicitation requests
    list_roots_callback=None,                  # Handle roots requests
    logging_callback=None,                     # Handle log notifications
    message_handler=None,                      # Raw message handler
    client_info=None,                          # Implementation info
)
```

The `server` parameter accepts:
- **URL string** → connects via Streamable HTTP
- **`MCPServer` instance** → connects via in-memory transport (great for testing)
- **`Transport` instance** → uses the transport directly

#### Client Methods

```python
# Tools
tools = await client.list_tools(cursor=None)
result = await client.call_tool("name", {"arg": "value"}, read_timeout_seconds=30)

# Resources
resources = await client.list_resources(cursor=None)
templates = await client.list_resource_templates(cursor=None)
content = await client.read_resource("resource://config")
await client.subscribe_resource("resource://live-data")
await client.unsubscribe_resource("resource://live-data")

# Prompts
prompts = await client.list_prompts(cursor=None)
prompt = await client.get_prompt("code_review", {"code": "def foo(): pass"})
completion = await client.complete(ref, argument)

# Utilities
await client.send_ping()
await client.set_logging_level("debug")
await client.send_roots_list_changed()
```

### Stdio Client

Connect to a server running as a subprocess:

```python
from mcp.client import ClientSession
from mcp.client.stdio import stdio_client, StdioServerParameters

params = StdioServerParameters(
    command="python",
    args=["server.py"],
    env={"API_KEY": "..."},      # Optional, defaults to safe env vars
    cwd="/path/to/server",       # Optional working directory
)

async with stdio_client(params) as (read_stream, write_stream):
    async with ClientSession(read_stream, write_stream) as session:
        await session.initialize()

        tools = await session.list_tools()
        result = await session.call_tool("hello", {"name": "World"})
        print(result.content[0].text)
```

### Streamable HTTP Client

Connect to a remote server over HTTP:

```python
from mcp.client import ClientSession
from mcp.client.streamable_http import streamable_http_client

async with streamable_http_client("https://mcp.example.com/mcp") as (read_stream, write_stream):
    async with ClientSession(read_stream, write_stream) as session:
        await session.initialize()
        result = await session.call_tool("search", {"query": "test"})
```

With custom HTTP client (auth, timeouts, etc.):

```python
import httpx
from mcp.client import ClientSession
from mcp.client.streamable_http import streamable_http_client

async with httpx.AsyncClient(
    timeout=30.0,
    headers={"Authorization": "Bearer my-token"},
) as http_client:
    async with streamable_http_client(
        "https://mcp.example.com/mcp",
        http_client=http_client,
        terminate_on_close=True,  # Send DELETE to terminate session
    ) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            ...
```

### In-Memory Client (Testing)

Connect directly to an `MCPServer` instance — no network involved:

```python
from mcp.client import Client
from mcp.server.mcpserver import MCPServer

server = MCPServer("test-server")

@server.tool()
def add(a: int, b: int) -> int:
    """Add two numbers."""
    return a + b

async with Client(server) as client:
    result = await client.call_tool("add", {"a": 2, "b": 3})
    print(result.content[0].text)  # "5"
```

### Sampling Callback

When a server requests LLM inference from the client:

```python
from mcp.types import CreateMessageResult, TextContent

async def handle_sampling(context, params):
    """Server requests client to perform LLM inference."""
    # params.messages — the conversation messages
    # params.systemPrompt — optional system prompt
    # params.modelPreferences — model selection hints
    # params.tools — tools available for the LLM (new in 2025-11-25)

    # Call your LLM here
    response = await my_llm.generate(params.messages)

    return CreateMessageResult(
        role="assistant",
        content=TextContent(type="text", text=response),
        model="my-model",
    )

async with Client(server, sampling_callback=handle_sampling) as client:
    ...
```

### Elicitation Callback

When a server requests user input:

```python
from mcp.types import ElicitResult

async def handle_elicitation(context, params):
    """Server requests user input."""
    # params — elicitation parameters with form schema
    user_input = await prompt_user(params)
    return ElicitResult(action="accept", content=user_input)

async with Client(server, elicitation_callback=handle_elicitation) as client:
    ...
```

### Roots Callback

When a server requests filesystem roots:

```python
from mcp.types import ListRootsResult, Root

async def handle_roots(context):
    """Server requests list of filesystem roots."""
    return ListRootsResult(roots=[
        Root(uri="file:///Users/ventz/project", name="Project"),
    ])

async with Client(server, list_roots_callback=handle_roots) as client:
    ...
```

### Multi-Server Session Group

Connect to multiple servers and aggregate their capabilities:

```python
from mcp.client.session_group import (
    ClientSessionGroup,
    StdioServerParameters,
    StreamableHttpParameters,
)

async with ClientSessionGroup() as group:
    await group.connect_to_server(
        StdioServerParameters(command="server1")
    )
    await group.connect_to_server(
        StreamableHttpParameters(url="https://server2.example.com/mcp")
    )

    # Aggregated tools from all servers
    result = await group.call_tool("any_tool", {"arg": "value"})

    # Access all tools, resources, prompts
    all_tools = group.tools       # dict[str, Tool]
    all_resources = group.resources
    all_prompts = group.prompts
```

Handle naming collisions with a hook:

```python
def name_hook(component_name: str, server_info) -> str:
    return f"{server_info.name}_{component_name}"

async with ClientSessionGroup(component_name_hook=name_hook) as group:
    ...
```

---

## 9. Elicitation

Elicitation lets servers request input from the user during tool execution.

### Form Mode

The server sends a schema and the client renders a form:

```python
from pydantic import BaseModel

class ConfirmAction(BaseModel):
    proceed: bool
    reason: str = ""

@mcp.tool()
async def dangerous_action(target: str, ctx: Context) -> str:
    """Perform a destructive action with user confirmation."""
    result = await ctx.elicit(
        message=f"Are you sure you want to delete {target}?",
        schema=ConfirmAction,
    )

    if result.action == "accept" and result.content.proceed:
        return f"Deleted {target}"
    return "Action cancelled"
```

Form schemas support primitive types: `str`, `int`, `float`, `bool`, enums.

### URL Mode

The server redirects the user to a URL for out-of-band interaction:

```python
@mcp.tool()
async def oauth_login(ctx: Context) -> str:
    """Initiate OAuth login flow."""
    result = await ctx.elicit_url(
        message="Please log in to continue",
        url="https://auth.example.com/login?callback=...",
        elicitation_id="login-12345",
    )
    # Client sends notifications/completed_elicitation when user finishes
    return "Login complete"
```

### Client-Side Elicitation Handling

```python
from mcp.types import ElicitResult

async def handle_elicitation(context, params):
    # Render form to user and collect input
    user_response = await show_form_to_user(params)

    if user_response is None:
        return ElicitResult(action="cancel")

    return ElicitResult(action="accept", content=user_response)

client = Client(server, elicitation_callback=handle_elicitation)
```

Possible actions: `"accept"` (user provided input), `"decline"` (user refused), `"cancel"` (user cancelled).

---

## 10. Authentication & Authorization

### OAuth 2.1 (Spec-Defined)

MCP uses OAuth 2.1 with PKCE (S256) for authentication:

1. **Discovery**: Client fetches Protected Resource Metadata (RFC 9728) to find the authorization server
2. **Authorization**: Standard OAuth 2.1 flow with PKCE
3. **Token Use**: Bearer token in `Authorization` header

### Server-Side Auth (MCPServer)

```python
from mcp.server.mcpserver import MCPServer
from mcp.server.auth import AuthSettings

mcp = MCPServer(
    "my-server",
    auth=AuthSettings(
        issuer_url="https://auth.example.com",
        audience="my-server",
    ),
    token_verifier=my_token_verifier,
)
```

### Client-Side Auth (HTTP Headers)

```python
import httpx
from mcp.client.streamable_http import streamable_http_client

async with httpx.AsyncClient(
    headers={"Authorization": "Bearer my-access-token"}
) as http_client:
    async with streamable_http_client(
        "https://mcp.example.com/mcp",
        http_client=http_client,
    ) as (read_stream, write_stream):
        ...
```

### Simple API Key Auth (Server-to-Server)

For non-OAuth scenarios, inject credentials via headers:

```python
# Server side — validate on incoming requests
@mcp.custom_route("/mcp", methods=["POST"])
async def mcp_with_auth(request):
    token = request.headers.get("Authorization", "").removeprefix("Bearer ")
    if token != os.getenv("API_KEY"):
        return JSONResponse({"error": "unauthorized"}, status_code=401)
    ...
```

### Incremental Scope Consent (New in 2025-11-25)

Servers can request additional OAuth scopes progressively. If a tool needs elevated permissions, the server returns HTTP 403 with `insufficient_scope` challenge, and the client initiates a new OAuth flow with the required scope.

---

## 11. HTTP Client Best Practices

### Shared Async Client

```python
import httpx

# Create once at module level, reuse across requests
http_client = httpx.AsyncClient(timeout=30.0)
```

### Rate Limiting

```python
import asyncio
import time

_last_request_time = 0
_rate_limit_lock = asyncio.Lock()
RATE_LIMIT_INTERVAL = 0.2  # 5 req/sec

async def rate_limit():
    global _last_request_time
    async with _rate_limit_lock:
        now = time.time()
        elapsed = now - _last_request_time
        if elapsed < RATE_LIMIT_INTERVAL:
            await asyncio.sleep(RATE_LIMIT_INTERVAL - elapsed)
        _last_request_time = time.time()
```

### Retry with Exponential Backoff

```python
MAX_RETRIES = 3

async def api_request_with_retry(method, url, **kwargs):
    for attempt in range(MAX_RETRIES + 1):
        try:
            response = await http_client.request(method, url, **kwargs)
            if response.status_code == 429:
                retry_after = int(response.headers.get("Retry-After", 2 ** attempt))
                await asyncio.sleep(retry_after)
                continue
            response.raise_for_status()
            return response.json()
        except httpx.TimeoutException:
            if attempt == MAX_RETRIES:
                return {"error": "Request timed out after retries"}
            await asyncio.sleep(2 ** attempt)
        except httpx.HTTPStatusError as e:
            return {"error": f"HTTP {e.response.status_code}", "status_code": e.response.status_code}
    return {"error": "Max retries exceeded"}
```

### Pagination Helper

```python
async def fetch_all_pages(endpoint: str, params: dict = None, max_pages: int = 10) -> list:
    all_results = []
    page = 1
    for _ in range(max_pages):
        page_params = {**(params or {}), "page": page, "per_page": 100}
        data = await api_request("GET", endpoint, params=page_params)
        if "error" in data:
            break
        items = data.get("items", data.get("results", []))
        if not items:
            break
        all_results.extend(items)
        if len(items) < 100:
            break
        page += 1
    return all_results
```

---

## 12. Error Handling

### Two Levels of Errors

**Protocol errors** (JSON-RPC level — bad JSON, unknown method, unknown tool):
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {"code": -32601, "message": "Unknown tool: bad_tool"}
}
```

**Tool execution errors** (tool ran but failed — API errors, validation, business logic):
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [{"type": "text", "text": "Error: API returned 503"}],
    "isError": true
  }
}
```

> **Key distinction**: Protocol errors use the JSON-RPC `error` field. Tool errors use the `result` field with `isError: true`. This matters because tool errors are shown to the LLM (which may retry), while protocol errors indicate a bug.

### MCPServer Error Handling

In MCPServer, tool errors are handled automatically:
- Exceptions raised in tool functions → `isError: true` with the exception message
- Unknown tools → `isError: true` response
- Missing required arguments → `isError: true` response

For explicit error control:

```python
@mcp.tool()
async def search(query: str) -> str:
    if not query.strip():
        raise ValueError("query is required")  # → isError: true
    result = await api_request("GET", "/search", params={"q": query})
    if "error" in result:
        raise RuntimeError(f"API error: {result['error']}")
    return json.dumps(result, indent=2)
```

### Client-Side Error Handling

```python
result = await client.call_tool("search", {"query": "test"})
if result.isError:
    print(f"Tool error: {result.content[0].text}")
else:
    print(f"Success: {result.content[0].text}")
```

With `raise_exceptions=True`:

```python
client = Client(server, raise_exceptions=True)
try:
    result = await client.call_tool("search", {"query": ""})
except Exception as e:
    print(f"Error: {e}")
```

---

## 13. Security

### Spec Requirements (2025-11-25)

1. **Validate Origin header** on all requests (prevents DNS rebinding)
2. **Bind to localhost** (127.0.0.1) when running locally, not 0.0.0.0
3. **Implement authentication** for all connections
4. **Validate all tool inputs** — never trust client-provided parameters
5. **Rate limit tool invocations**
6. **Sanitize tool outputs** — don't leak internal errors or stack traces
7. **Non-deterministic session IDs** — prevent session prediction
8. **Bind sessions to user info** — prevent session hijacking

### Confused Deputy Problem

Servers MUST require per-client consent before forwarding requests to third parties. Never accept upstream tokens from clients.

### Input Validation

```python
# Clamp numeric params
limit = max(1, min(arguments.get("limit", 10), 50))

# Validate enum params
valid_sorts = {"relevance", "date_desc", "date_asc"}
sort = arguments.get("sort", "relevance")
if sort not in valid_sorts:
    sort = "relevance"

# Reject empty required params
query = arguments.get("query", "").strip()
if not query:
    return {"error": "query is required"}
```

### Human in the Loop

Clients SHOULD:
- Show tool inputs to the user before calling the server
- Prompt for confirmation on destructive operations
- Display visual indicators when tools are invoked
- Log tool usage for audit purposes

---

## 14. Dockerfile & Deployment

### MCPServer Dockerfile

```dockerfile
FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY pyproject.toml .
RUN pip install --no-cache-dir .

COPY . .

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

CMD ["python", "server.py"]
```

### Raw FastAPI Dockerfile

```dockerfile
FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn httpx

COPY server.py .

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
      - "8000:8000"
    env_file:
      - .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 3s
      retries: 3
```

---

## 15. Testing

### Test with curl (Raw FastAPI)

```bash
# Initialize
curl -s -X POST http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  | jq .

# List tools
curl -s -X POST http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | jq .

# Call a tool
curl -s -X POST http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_items","arguments":{"query":"test"}}}' \
  | jq '.result.content[0].text' -r | jq .
```

### Test with curl (MCPServer — SSE responses)

MCPServer returns SSE, so use `Accept` header and parse SSE events:

```bash
# Initialize (SSE response)
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# The response will be SSE formatted:
# event: message
# data: {"jsonrpc":"2.0","id":1,"result":{...}}
```

### Test with Python Client

```python
import asyncio
from mcp.client import Client

async def test():
    async with Client("http://localhost:8000/mcp") as client:
        # List tools
        tools = await client.list_tools()
        print(f"Tools: {[t.name for t in tools.tools]}")

        # Call a tool
        result = await client.call_tool("search_items", {"query": "test"})
        print(f"Result: {result.content[0].text}")

asyncio.run(test())
```

### Test with In-Memory Client (Unit Tests)

```python
import pytest
from mcp.client import Client
from my_server import mcp  # Your MCPServer instance

@pytest.mark.asyncio
async def test_search_tool():
    async with Client(mcp) as client:
        result = await client.call_tool("search_items", {"query": "test"})
        assert not result.isError
        assert "results" in result.content[0].text

@pytest.mark.asyncio
async def test_unknown_tool():
    async with Client(mcp) as client:
        result = await client.call_tool("nonexistent", {})
        assert result.isError
```

### Test Edge Cases

```bash
# Invalid JSON
curl -s -X POST http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d 'not json' | jq .

# Unknown method
curl -s -X POST http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"bad/method","params":{}}' | jq .

# Ping
curl -s -X POST http://localhost:8001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' | jq .

# Health check
curl -s http://localhost:8001/health | jq .
```

### LibreChat Integration Config

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

## 16. Checklist

### Protocol Compliance

- [ ] Protocol version is `2025-11-25`
- [ ] Single `POST /mcp` endpoint handles all JSON-RPC messages
- [ ] `initialize` returns `protocolVersion`, `serverInfo`, `capabilities`
- [ ] `notifications/initialized` returns 202 or empty result
- [ ] `ping` returns empty result
- [ ] `tools/list` returns array of tool definitions
- [ ] `tools/call` dispatches to correct handler
- [ ] Unknown tools return appropriate error
- [ ] Unknown methods return JSON-RPC error code -32601
- [ ] Invalid JSON returns error code -32700
- [ ] Tool execution errors use `isError: true` in result (not JSON-RPC error)
- [ ] All responses include `jsonrpc: "2.0"` and matching `id`

### Tool Quality

- [ ] Every tool has a detailed `description` (50-150 words)
- [ ] Every parameter has a `description`
- [ ] Required parameters listed in `required` array
- [ ] Optional parameters have `default` values
- [ ] Enum parameters use `enum` field
- [ ] Input validation before API calls
- [ ] Tool annotations set where applicable (readOnlyHint, destructiveHint, etc.)

### Server Features

- [ ] Health check endpoint
- [ ] Rate limiting for upstream API
- [ ] Timeout on all HTTP requests (30s default)
- [ ] Structured error responses (never raw stack traces)
- [ ] Logging with request context
- [ ] Environment-based configuration (no hardcoded secrets)
- [ ] Dockerfile with health check

### Client Features (if building a client)

- [ ] Proper initialization handshake (initialize → initialized)
- [ ] Session ID management (include on all requests after init)
- [ ] Sampling callback (if server uses sampling)
- [ ] Elicitation callback (if server uses elicitation)
- [ ] Roots callback (if server requests filesystem roots)
- [ ] Error handling for tool execution errors
- [ ] Timeout configuration
- [ ] Graceful session termination (DELETE)

---

## Reference Links

- [MCP Specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25)
- [MCP Tools Spec](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [MCP Resources Spec](https://modelcontextprotocol.io/specification/2025-11-25/server/resources)
- [MCP Prompts Spec](https://modelcontextprotocol.io/specification/2025-11-25/server/prompts)
- [MCP Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [MCP Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [MCP Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [Python MCP SDK](https://github.com/modelcontextprotocol/python-sdk)
