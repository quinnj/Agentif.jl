using JSON

mode = isempty(ARGS) ? "normal" : only(ARGS)
schema = Dict("type" => "object", "properties" => Dict("text" => Dict("type" => "string")), "required" => ["text"], "additionalProperties" => false)
tool(name) = Dict("name" => name, "description" => name, "inputSchema" => schema)
for line in eachline(stdin)
    request = JSON.parse(line)
    haskey(request, "id") || continue
    params = get(request, "params", Dict())
    method = request["method"]
    result = if method == "initialize"
        Dict("protocolVersion" => params["protocolVersion"], "capabilities" => Dict("tools" => Dict()), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
    elseif method == "server/discover"
        Dict("supportedVersions" => ["2026-07-28"], "capabilities" => Dict("tools" => Dict()), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
    elseif method == "tools/list"
        if mode == "collision"
            Dict("tools" => [tool("a.b"), tool("a_b")])
        elseif mode == "cycle"
            Dict("tools" => [], "nextCursor" => "again")
        elseif get(params, "cursor", nothing) === nothing
            Dict("tools" => [tool("echo")], "nextCursor" => "second")
        else
            Dict("tools" => [tool("fail"), tool("input")])
        end
    elseif method == "tools/call"
        name = params["name"]
        name == "input" ? Dict("resultType" => "input_required", "inputRequests" => Dict("permission" => Dict("method" => "elicitation/create"))) :
            Dict("content" => [Dict("type" => "text", "text" => name)], "structuredContent" => params["arguments"], "isError" => name == "fail")
    else
        Dict()
    end
    println(JSON.json(Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => result)))
    flush(stdout)
end
