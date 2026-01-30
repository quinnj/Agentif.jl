"""
    Qmd-based search tools for semantic code search

These tools provide semantic search capabilities using Qmd (a quantized markdown
and code search utility). They enable agents to:

1. Index files in a directory for later searching
2. Perform semantic/keyword searches across indexed content

# Usage

```julia
using LLMTools

# Index files in a directory
index_result = qmd_index_files("/path/to/project", include_pattern="**/*.jl")

# Search for relevant content
results = qmd_search("how does error handling work")
```
"""

# Global state for the current Qmd collection and store path
const QMD_CURRENT_COLLECTION = Ref{Union{String,Nothing}}(nothing)
const QMD_STORE_PATH = Ref{Union{String,Nothing}}(nothing)

"""
    qmd_set_store_path(path::Union{String,Nothing})

Set the SQLite database path to use for Qmd operations.
If nothing, uses the default Qmd database path.
"""
function qmd_set_store_path(path::Union{String,Nothing})
    QMD_STORE_PATH[] = path
    return path
end

"""
    qmd_get_store_path() -> Union{String,Nothing}

Get the current SQLite database path used for Qmd operations.
"""
function qmd_get_store_path()
    return QMD_STORE_PATH[]
end

function open_qmd_store(; load_vec::Bool=true)
    path = QMD_STORE_PATH[]
    if path !== nothing
        return Qmd.Store.open_store(path; load_vec=load_vec)
    else
        return Qmd.Store.open_store(; load_vec=load_vec)
    end
end

"""
    qmd_ensure_collection(base_dir::String, name::String="default") -> String

Ensure a Qmd collection exists for the given directory.
Returns the collection name.
"""
function qmd_ensure_collection(base_dir::String, name::String="default")
    # Normalize the base directory
    base_dir = abspath(expanduser(base_dir))
    isdir(base_dir) || throw(ArgumentError("Directory not found: $base_dir"))
    
    # Check if collection already exists
    collections = Qmd.Collections.list()
    for coll in collections
        if coll.name == name
            # Update path if it changed
            if coll.path != base_dir
                Qmd.Collections.remove(name)
                Qmd.Collections.add(name, base_dir)
            end
            return name
        end
    end
    
    # Create new collection
    Qmd.Collections.add(name, base_dir)
    return name
end

"""
    qmd_index_files(
        base_dir::String;
        collection_name::Union{String,Nothing}=nothing,
        include_pattern::String="**/*",
        exclude_dirs::Vector{String}=String[],
        embed::Bool=true
    ) -> Dict{String,Any}

Index files in a directory for semantic search.

# Arguments
- `base_dir`: Base directory to index
- `collection_name`: Name for this collection (defaults to directory name)
- `include_pattern`: Glob pattern for files to include (default: "**/*" for all files)
- `exclude_dirs`: Additional directories to exclude beyond defaults
- `embed`: Whether to also generate embeddings (slower but enables semantic search)

# Returns
Dictionary with indexing statistics:
- `success`: Boolean indicating success
- `collection`: Collection name used
- `indexed`: Number of files indexed
- `embedded`: Number of files embedded (if embed=true)
- `message`: Human-readable summary

# Example
```julia
result = qmd_index_files("./src", include_pattern="**/*.jl", exclude_dirs=["test"])
```
"""
function qmd_index_files(
    base_dir::String;
    collection_name::Union{String,Nothing}=nothing,
    include_pattern::String="**/*",
    exclude_dirs::Vector{String}=String[],
    embed::Bool=true
)
    base_dir = abspath(expanduser(base_dir))
    isdir(base_dir) || return Dict(
        "success" => false,
        "message" => "Directory not found: $base_dir"
    )
    
    # Generate collection name from directory if not provided
    if collection_name === nothing
        collection_name = "agentif_" * replace(basename(base_dir), r"[^a-zA-Z0-9_]" => "_")
    end
    
    try
        # Ensure collection exists with the right pattern
        coll = Qmd.Collections.get_collection(collection_name)
        if coll === nothing || coll.path != base_dir || coll.pattern != include_pattern
            # Remove existing if different
            if coll !== nothing
                Qmd.Collections.remove(collection_name)
            end
            # Create new collection
            Qmd.Collections.add(collection_name, base_dir; pattern=include_pattern)
        end
        
        # Index files (indexes all collections)
        store = open_qmd_store()
        try
            # Run indexing on all collections (Qmd.index returns IndexAndEmbedResult)
            combined_result = Qmd.index(; store=store, exclude_dirs=exclude_dirs, skip_embed=!embed)
            
            # Find result for our collection from the index vector
            our_result = nothing
            for r in combined_result.index
                if r.collection == collection_name
                    our_result = r
                    break
                end
            end
            
            if our_result === nothing
                return Dict(
                    "success" => false,
                    "message" => "Collection '$collection_name' was not indexed"
                )
            end
            
            # Set as current collection
            QMD_CURRENT_COLLECTION[] = collection_name
            
            return Dict(
                "success" => true,
                "collection" => collection_name,
                "indexed" => our_result.indexed,
                "updated" => our_result.updated,
                "unchanged" => our_result.unchanged,
                "embedded" => embed ? combined_result.embed.documents : 0,
                "message" => "Indexed $(our_result.indexed) files in '$collection_name'" *
                    (embed ? ", embedded $(combined_result.embed.documents) documents" : "")
            )
        finally
            Qmd.Store.close(store)
        end
        
    catch e
        return Dict(
            "success" => false,
            "message" => "Indexing failed: $(sprint(showerror, e))"
        )
    end
end

"""
    qmd_search(
        query::String;
        collection::Union{String,Nothing}=nothing,
        limit::Int=5,
        search_mode::Symbol=:combined,
        min_score::Float64=0.0
    ) -> Dict{String,Any}

Search indexed files using keyword search, semantic search, or both combined (default).

# Arguments
- `query`: Search query (natural language or keywords)
- `collection`: Collection to search (defaults to last indexed collection)
- `limit`: Maximum number of results to return
- `search_mode`: One of:
  - `:combined` (default) - Uses both keyword and semantic search with reciprocal rank fusion for best results
  - `:keyword` - Keyword/full-text search only (faster, good for exact matches)
  - `:semantic` - Semantic/vector search only (finds conceptually related content)
- `min_score`: Minimum relevance score (0.0 to 1.0)

# Returns
Dictionary with search results:
- `success`: Boolean indicating success
- `results`: Vector of result dictionaries with `path`, `score`, `snippet`
- `message`: Human-readable summary

# Example
```julia
# Default: combined search (best results, uses both keyword and semantic with RRF)
results = qmd_search("error handling try catch")

# Keyword-only search (faster, exact matches)
results = qmd_search("function parse_json", search_mode=:keyword)

# Semantic-only search (conceptual similarity)
results = qmd_search("how to handle errors", search_mode=:semantic)
```
"""
function qmd_search(
    query::String;
    collection::Union{String,Nothing}=nothing,
    limit::Int=5,
    search_mode::Symbol=:combined,
    min_score::Float64=0.0
)
    # Use current collection if not specified
    if collection === nothing
        collection = QMD_CURRENT_COLLECTION[]
        if collection === nothing
            return Dict(
                "success" => false,
                "message" => "No collection specified and no collection has been indexed yet. Call qmd_index_files first."
            )
        end
    end
    
    # Check collection exists
    coll = Qmd.Collections.get_collection(collection)
    if coll === nothing
        return Dict(
            "success" => false,
            "message" => "Collection not found: $collection. Call qmd_index_files first."
        )
    end
    
    try
        store = open_qmd_store()
        try
            results = if search_mode == :combined
                # Use Qmd.query() which combines keyword and vector search with RRF
                Qmd.query(query; store=store, collection=collection, limit=limit, min_score=min_score)
            elseif search_mode == :semantic
                # Use vector search for semantic similarity
                Qmd.vsearch(query; store=store, collection=collection, limit=limit, min_score=min_score)
            else
                # Use full-text search (keyword)
                Qmd.search(query; store=store, collection=collection, limit=limit, min_score=min_score)
            end
            
            # Format results
            formatted = Vector{Dict{String,Any}}()
            for r in results
                # Extract a snippet from the body
                snippet = r.body !== nothing ? r.body : ""
                if length(snippet) > 300
                    snippet = snippet[1:297] * "..."
                end
                push!(formatted, Dict(
                    "path" => r.filepath,
                    "display_path" => r.display_path,
                    "score" => round(r.score, digits=3),
                    "snippet" => snippet
                ))
            end
            
            search_type = if search_mode == :combined
                "combined (keyword + semantic with RRF)"
            elseif search_mode == :semantic
                "semantic"
            else
                "keyword"
            end
            return Dict(
                "success" => true,
                "collection" => collection,
                "query" => query,
                "search_type" => search_type,
                "result_count" => length(formatted),
                "results" => formatted,
                "message" => "Found $(length(formatted)) $search_type results for '$query'"
            )
            
        finally
            Qmd.Store.close(store)
        end
        
    catch e
        return Dict(
            "success" => false,
            "message" => "Search failed: $(sprint(showerror, e))"
        )
    end
end

"""
    qmd_list_collections() -> Dict{String,Any}

List all available Qmd collections.
"""
function qmd_list_collections()
    try
        collections = Qmd.Collections.list()
        formatted = Vector{Dict{String,String}}()
        for c in collections
            push!(formatted, Dict(
                "name" => c.name,
                "path" => c.path,
                "pattern" => c.pattern
            ))
        end
        
        return Dict(
            "success" => true,
            "collections" => formatted,
            "message" => "Found $(length(formatted)) collections"
        )
    catch e
        return Dict(
            "success" => false,
            "message" => "Failed to list collections: $(sprint(showerror, e))"
        )
    end
end

"""
    qmd_get_current_collection() -> Union{String,Nothing}

Get the name of the currently active collection (last indexed).
"""
function qmd_get_current_collection()
    return QMD_CURRENT_COLLECTION[]
end

"""
    qmd_set_current_collection(name::String) -> Bool

Set the current collection for subsequent searches.
"""
function qmd_set_current_collection(name::String)
    coll = Qmd.Collections.get_collection(name)
    if coll === nothing
        return false
    end
    QMD_CURRENT_COLLECTION[] = name
    return true
end

"""
    create_qmd_index_tool(base_dir::String)

Create an AgentTool for indexing files with Qmd.
"""
function create_qmd_index_tool(base_dir::String)
    base = ensure_base_dir(base_dir)
    
    return @tool(
        """Index files in the project for semantic search using Qmd.
        
This tool scans files in the project and indexes them for fast semantic search.
You should call this before using qmd_search if files have changed or if this
is the first time searching.

Parameters:
- path: Relative path to index (default: "." for entire project)
- include_pattern: Glob pattern for files to include (default: "**/*")
- exclude_dirs: Additional directories to exclude as JSON array (default: [])
- embed: Whether to generate embeddings for semantic search (default: true)

Examples:
- Index all Julia files: path=".", include_pattern="**/*.jl"
- Index src directory excluding tests: path="src", exclude_dirs=["test","tests"]""",
        qmd_index(
            path::Union{Nothing,String}=nothing,
            include_pattern::String="**/*",
            exclude_dirs::Union{Nothing,String}=nothing,
            embed::Bool=true
        ) = begin
            dir_path = path === nothing ? base : resolve_relative_path(base, path)
            
            # Parse exclude_dirs from JSON if provided
            exclude_vec = String[]
            if exclude_dirs !== nothing && !isempty(exclude_dirs)
                try
                    parsed = JSON.parse(exclude_dirs)
                    if parsed isa Vector
                        exclude_vec = String[string(x) for x in parsed]
                    end
                catch
                    # If not valid JSON, treat as comma-separated
                    exclude_vec = String[strip(x) for x in split(exclude_dirs, ',') if !isempty(strip(x))]
                end
            end
            
            result = qmd_index_files(
                dir_path;
                include_pattern=include_pattern,
                exclude_dirs=exclude_vec,
                embed=embed
            )
            
            if !result["success"]
                return "Error: $(result["message"])"
            end
            
            output = IOBuffer()
            println(output, "✓ Indexed $(result["indexed"]) files")
            println(output, "  Updated: $(result["updated"])")
            println(output, "  Unchanged: $(result["unchanged"])")
            embed > 0 && println(output, "  Embedded: $(result["embedded"]) chunks")
            println(output, "  Collection: $(result["collection"])")
            
            return String(take!(output))
        end
    )
end

"""
    create_qmd_search_tool(base_dir::String)

Create an AgentTool for searching indexed files with Qmd.
"""
function create_qmd_search_tool(base_dir::String)
    base = ensure_base_dir(base_dir)
    
    return @tool(
        """Search indexed files for relevant content.

This tool searches through previously indexed files using keyword search, 
semantic search, or both combined (default). The combined mode uses 
reciprocal rank fusion (RRF) to give the best results from both approaches.

Parameters:
- query: Search query (natural language or keywords)
- search_mode: One of "combined" (default), "keyword", or "semantic"
  - "combined": Uses both keyword and semantic search with RRF (best results)
  - "keyword": Full-text search only (faster, good for exact matches)
  - "semantic": Vector similarity search (finds conceptually related content)
- limit: Maximum results to return (default: 5, max: 20)
- min_score: Minimum relevance score 0.0-1.0 (default: 0.0)

Examples:
- "how does error handling work" - finds conceptually related code
- "function parse_json" - finds exact function definitions
- Use search_mode="keyword" for exact symbol names
- Use search_mode="semantic" for finding similar concepts""",
        qmd_search_tool(
            query::String,
            search_mode::String="combined",
            limit::Int=5,
            min_score::Float64=0.0
        ) = begin
            isempty(query) && throw(ArgumentError("query is required"))
            limit = clamp(limit, 1, 20)
            min_score = clamp(min_score, 0.0, 1.0)
            
            # Parse search_mode string to Symbol
            mode_sym = if lowercase(search_mode) == "keyword" || search_mode == "false"
                :keyword
            elseif lowercase(search_mode) == "semantic" || search_mode == "true"
                :semantic
            else
                :combined
            end
            
            result = qmd_search(
                query;
                search_mode=mode_sym,
                limit=limit,
                min_score=min_score
            )
            
            if !result["success"]
                return "Error: $(result["message"])"
            end
            
            output = IOBuffer()
            println(output, "Search results for: $(result["query"]) ($(result["search_type"]))")
            println(output, "")
            
            if isempty(result["results"])
                println(output, "No results found.")
                println(output, "")
                println(output, "Tip: Try rephrasing your query or use semantic=false for keyword search.")
                println(output, "You may also need to run qmd_index first to index the files.")
            else
                for (i, r) in enumerate(result["results"])
                    println(output, "$(i). $(r["display_path"]) (score: $(r["score"]))")
                    snippet = r["snippet"]
                    # Truncate long snippets
                    if length(snippet) > 300
                        snippet = snippet[1:297] * "..."
                    end
                    println(output, "   $(snippet)")
                    println(output, "")
                end
            end
            
            return String(take!(output))
        end
    )
end

"""
    qmd_tools(base_dir::String=pwd()) -> Vector{AgentTool}

Return both Qmd search tools (index and search).
"""
function qmd_tools(base_dir::String=pwd())
    return AgentTool[
        create_qmd_index_tool(base_dir),
        create_qmd_search_tool(base_dir)
    ]
end
