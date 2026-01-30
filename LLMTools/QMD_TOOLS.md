# Qmd Search Tools for LLMTools.jl

This document describes the Qmd-based semantic search tools added to LLMTools.jl.

## Overview

The Qmd integration provides two main tools for agents:

1. **`qmd_index`** - Index files in a directory for semantic search
2. **`qmd_search_tool`** - Search indexed files using keyword or semantic search

## Tools

### `qmd_index`

Index files in the project for semantic search using Qmd.

**Parameters:**
- `path`: Relative path to index (default: "." for entire project)
- `include_pattern`: Glob pattern for files to include (default: "**/*")
- `exclude_dirs`: Additional directories to exclude as JSON array (default: [])
- `embed`: Whether to generate embeddings for semantic search (default: true)

**Examples:**
```julia
# Index all Julia files in src directory
qmd_index(path="src", include_pattern="**/*.jl")

# Index everything except tests
qmd_index(path=".", exclude_dirs="[\"test\",\"tests\"]")
```

### `qmd_search_tool`

Search indexed files using keyword search, semantic search, or both combined (default).

**Parameters:**
- `query`: Search query (natural language or keywords)
- `search_mode`: Search mode - one of:
  - `"combined"` (default) - Uses both keyword and semantic search with reciprocal rank fusion (RRF) for the best results
  - `"keyword"` - Full-text search only (faster, good for exact matches like function names)
  - `"semantic"` - Vector similarity search (finds conceptually related content)
- `limit`: Maximum results to return (default: 5, max: 20)
- `min_score`: Minimum relevance score 0.0-1.0 (default: 0.0)

**Examples:**
```julia
# Default: combined search (best results, uses both approaches with RRF)
qmd_search_tool(query="how does error handling work")

# Keyword-only for exact symbol matches
qmd_search_tool(query="function parse_json", search_mode="keyword")

# Semantic-only for conceptual similarity
qmd_search_tool(query="how to handle errors", search_mode="semantic")
```

## API Functions

### `qmd_index_files(base_dir; kwargs...)`

Programmatic interface for indexing files.

```julia
result = qmd_index_files(
    "./src";
    collection_name="my_project",  # Optional custom name
    include_pattern="**/*.jl",
    exclude_dirs=["test", "docs"],
    embed=true
)

# Returns Dict with:
# - success::Bool
# - collection::String
# - indexed::Int
# - updated::Int
# - unchanged::Int
# - embedded::Int
# - message::String
```

### `qmd_search(query; kwargs...)`

Programmatic interface for searching.

```julia
# Default: combined search (uses both keyword + semantic with RRF)
result = qmd_search("error handling")

# Keyword-only search
result = qmd_search("function parse_json"; search_mode=:keyword)

# Semantic-only search  
result = qmd_search("how to handle errors"; search_mode=:semantic)

# Full parameters
result = qmd_search(
    "error handling";
    collection="my_project",  # Optional, uses last indexed by default
    limit=10,
    search_mode=:combined,    # :combined (default), :keyword, or :semantic
    min_score=0.5
)

# Returns Dict with:
# - success::Bool
# - results::Vector{Dict} with path, display_path, score, snippet
# - message::String
```

## Tool Creation

Create tools for use with an Agent:

```julia
using Agentif, LLMTools

# Create tools for a specific base directory
index_tool = create_qmd_index_tool("/path/to/project")
search_tool = create_qmd_search_tool("/path/to/project")

# Create agent with Qmd tools
agent = Agent(
    prompt = "You can search the codebase using qmd_index and qmd_search_tool",
    model = model,
    apikey = apikey,
    tools = [index_tool, search_tool, other_tools...]
)
```

## Helper Functions

- `qmd_tools(base_dir)` - Returns both index and search tools
- `qmd_list_collections()` - List all available collections
- `qmd_get_current_collection()` - Get the last used collection name
- `qmd_set_current_collection(name)` - Set the active collection

## How It Works

1. **Indexing**: 
   - Creates a Qmd collection for the specified directory
   - Scans files matching the include pattern
   - Stores file contents and metadata in SQLite
   - Optionally generates vector embeddings for semantic search

2. **Search**:
   - **Combined mode (default)**: Uses `Qmd.query()` which runs both keyword and semantic searches,
     then combines results using reciprocal rank fusion (RRF). This gives the best of both approaches - 
     exact matches from keywords and conceptually related content from semantic search.
   - **Keyword mode**: Full-text search using SQLite FTS (fastest, good for exact symbol names)
   - **Semantic mode**: Vector similarity using embeddings (finds conceptually related content)
   - Results include file path, relevance score, and content snippet

## Testing

Run unit tests:
```bash
cd packages/LLMTools.jl
julia --project -e "using Pkg; Pkg.test()"
```

Run smoke test with live agent:
```bash
cd packages/LLMTools.jl
export MINIMAX_API_KEY="..."
export MINIMAX_PROVIDER="openrouter"
export MINIMAX_MODEL_ID="minimax/minimax-m2.1"
julia --project=. test/smoke_test.jl
```

## Dependencies

- **Qmd**: The core search/indexing engine
- **Agentif**: For AgentTool integration
- **LLMProviders**: For model selection

## Notes

- Collections are persisted between sessions in Qmd's SQLite database
- The default collection name is derived from the directory name
- Embedding generation can be slow for large codebases
- **When to use each search mode:**
  - **Combined** (default): Best overall results, uses RRF to combine keyword + semantic
  - **Keyword**: Use when searching for exact function names, file paths, or specific strings
  - **Semantic**: Use when exploring concepts or when you don't know the exact terminology

## Search Mode Comparison

| Mode | Speed | Best For | Algorithm |
|------|-------|----------|-----------|
| `combined` | Medium | General search, best accuracy | Keyword + Semantic with RRF |
| `keyword` | Fastest | Exact matches, symbol names | SQLite FTS |
| `semantic` | Slower | Conceptual similarity | Vector cosine similarity |
