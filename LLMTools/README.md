# LLMTools

`LLMTools` provides the tool suites used by the higher-level agent packages in this repo.

Current tool areas include:

- file editing and search
- PTY-backed terminal sessions
- Julia worker execution
- web fetch and search
- Subagent helpers

The `ls`, `find`, and `grep` tools omit `.git` and honor applicable
`.gitignore` rules. Other dotfiles remain visible.

Semantic/code-search experiments are no longer exposed from `LLMTools`; that work moved to `LocalSearch.jl`.

## Repo-Root Workflow

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then:

```julia
using LLMTools
```

## Tool Suites

```julia
using LLMTools

read_only = LLMTools.read_only_tools(pwd())
coding = LLMTools.coding_tools(pwd())
everything = LLMTools.all_tools(pwd(); workers = true)
```

## MCP Client Tools

Load the [JuliaServices ModelContextProtocol.jl](https://github.com/JuliaServices/ModelContextProtocol.jl)
package to use an MCP server's tools from Agentif. This is an optional LLMTools
extension. The repo-root environment includes it. Outside this monorepo, install
it by URL: the General registry contains a different package with the same name.

```julia
using Pkg
Pkg.add(url = "https://github.com/JuliaServices/ModelContextProtocol.jl",
        rev = "71ec8548bba6f81a2e3f670a43689d5e5acd39e6")
```

For a Streamable HTTP server:

```julia
using Agentif, LLMTools
import ModelContextProtocol as MCP

discovery = MCP.discover_server("http://127.0.0.1:3000")
client = MCP.prepare_manual_client(discovery)
MCP.initialize_client!(client)
try
    agent = Agentif.Agent(
        prompt = "Use the available remote tools to answer the user.",
        model = Agentif.getModel("openai", "gpt-4.1-mini"),
        apikey = ENV["OPENAI_API_KEY"],
        tools = LLMTools.mcp_tools(client; prefix = "remote_"),
    )
    result = Agentif.evaluate(agent, "Which tools can help me?")
finally
    MCP.terminate_session!(client)
end
```

For a local stdio server, the do-block owns and closes its child process:

```julia
MCP.prepare_stdio_client(`my-mcp-server`) do client
    MCP.initialize_client!(client)
    tools = LLMTools.mcp_tools(client; prefix = "local_")
    # Use these tools while the client remains open.
end
```

Both transports default to protocol `2025-11-25`. Pass
`config = MCP.MCPClientConfig(protocol_version = "2026-07-28")` when creating
the client for the newer protocol. Configure authentication, request handlers,
and timeouts on the MCP client before use.

Discovery follows pagination and returns a snapshot. Call `mcp_tools` again to
refresh it. Names use a caller-chosen prefix and replace unsupported characters
with underscores; colliding names or names longer than 64 characters are rejected.
Use distinct prefixes when combining servers. Tool calls validate the discovered
schema before sending arguments, preserve the complete result envelope as JSON
text within Agentif's result size limit, and mark remote failures as tool errors.
An `input_required` response is returned as an error for the host to handle;
the adapter does not automatically answer or replay it. Remote tools can have
side effects. External schema references are rejected; local fragment references
are supported. Prompts, resources, and subscriptions remain available through
the MCP client's own APIs.

## Terminal Tools

The PTY-backed terminal tools are created with:

```julia
tools = LLMTools.create_terminal_tools(pwd())
```

See:

- `examples/terminal_tools/README.md`
- `examples/terminal_tools/run_all.jl`
- `examples/terminal_tools/quick_smoke_test.jl`

## Web Tools

```julia
using LLMTools

tools = LLMTools.web_tools()
```

These provide the `web_fetch` and `web_search` tool wrappers used in tests and agent setups.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl LLMTools
```
