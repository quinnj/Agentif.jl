#!/usr/bin/env julia
#
# generate_models.jl -- regenerate LLMProviders/src/models_generated.jl from
# pi-mono's packages/ai/src/models.generated.ts.
#
# Usage:
#     julia LLMProviders/gen/generate_models.jl [SOURCE_TS] [OUTPUT_JL]
#
# Defaults:
#     SOURCE_TS  $PI_MONO_MODELS_TS, else $PI_MONO/packages/ai/src/models.generated.ts,
#                else ~/pi-mono/packages/ai/src/models.generated.ts
#     OUTPUT_JL  <this file>/../../src/models_generated.jl
#
# The script is intentionally dependency-free (Base only) and does not shell out
# to any TypeScript tooling: `models.generated.ts` is itself machine-generated,
# so its shape is a strictly regular nesting of literal objects that a
# line-oriented parser can read reliably. See gen/README.md.

const DEFAULT_TS_RELPATH = "packages/ai/src/models.generated.ts"

# ---------------------------------------------------------------------------
# Value model
#
# Parsed TS values are kept in a tiny tagged representation so that numbers can
# survive as their *verbatim source token*. Reparsing them as Float64 and
# re-printing would silently rewrite upstream values (e.g. 0.19999999999999998
# vs 0.2); the existing checked-in file preserves the raw tokens, and so do we.
# ---------------------------------------------------------------------------

struct TSNum          # verbatim numeric token, e.g. "0.19999999999999998" or "4"
    token::String
end

struct TSStr
    value::String
end

struct TSBool
    value::Bool
end

const TSArray = Vector{Any}
const TSObject = Vector{Pair{String, Any}}   # ordered, upstream key order preserved

# ---------------------------------------------------------------------------
# Scalar / inline-literal parsing
# ---------------------------------------------------------------------------

"""
    parse_js_string(s, i) -> (String, nextindex)

Parse a double-quoted JS/JSON string literal starting at `s[i] == '"'`.
Handles the standard escape set including `\\uXXXX` (with surrogate pairs).
"""
function parse_js_string(s::AbstractString, i::Int)
    @assert s[i] == '"' "expected '\"' at index $i in: $(first(s, 120))"
    io = IOBuffer()
    i = nextind(s, i)
    while i <= lastindex(s)
        c = s[i]
        if c == '"'
            return String(take!(io)), nextind(s, i)
        elseif c == '\\'
            i = nextind(s, i)
            i <= lastindex(s) || error("unterminated escape in string literal")
            e = s[i]
            if e == 'n'
                print(io, '\n')
            elseif e == 't'
                print(io, '\t')
            elseif e == 'r'
                print(io, '\r')
            elseif e == 'b'
                print(io, '\b')
            elseif e == 'f'
                print(io, '\f')
            elseif e == '/'
                print(io, '/')
            elseif e == '\\'
                print(io, '\\')
            elseif e == '"'
                print(io, '"')
            elseif e == 'u'
                hex = s[(i + 1):(i + 4)]
                cp = parse(UInt32, hex; base = 16)
                i += 4
                if 0xD800 <= cp <= 0xDBFF && i + 6 <= lastindex(s) && s[i + 1] == '\\' && s[i + 2] == 'u'
                    lo = parse(UInt32, s[(i + 3):(i + 6)]; base = 16)
                    if 0xDC00 <= lo <= 0xDFFF
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        i += 6
                    end
                end
                print(io, Char(cp))
            else
                error("unsupported escape '\\$e' in string literal")
            end
            i = nextind(s, i)
        else
            print(io, c)
            i = nextind(s, i)
        end
    end
    return error("unterminated string literal")
end

skipws(s::AbstractString, i::Int) = (while i <= lastindex(s) && isspace(s[i]); i = nextind(s, i); end; i)

"""
    parse_value(s, i) -> (value, nextindex)

Parse one inline TS/JSON value (string, number, bool, null, array, object).
Only used for values that upstream emits on a single line: `input`, `compat`,
`headers`, and every scalar. Multi-line blocks (`cost`) are handled by the
line-oriented reader below.
"""
function parse_value(s::AbstractString, i::Int)
    i = skipws(s, i)
    i <= lastindex(s) || error("unexpected end of value")
    c = s[i]
    if c == '"'
        v, i = parse_js_string(s, i)
        return TSStr(v), i
    elseif c == '['
        arr = TSArray()
        i = skipws(s, nextind(s, i))
        if i <= lastindex(s) && s[i] == ']'
            return arr, nextind(s, i)
        end
        while true
            v, i = parse_value(s, i)
            push!(arr, v)
            i = skipws(s, i)
            i <= lastindex(s) || error("unterminated array")
            if s[i] == ','
                i = nextind(s, i)
            elseif s[i] == ']'
                return arr, nextind(s, i)
            else
                error("unexpected char '$(s[i])' in array")
            end
        end
    elseif c == '{'
        obj = TSObject()
        i = skipws(s, nextind(s, i))
        if i <= lastindex(s) && s[i] == '}'
            return obj, nextind(s, i)
        end
        while true
            i = skipws(s, i)
            local key::String
            if s[i] == '"'
                key, i = parse_js_string(s, i)
            else  # bare identifier key
                j = i
                while j <= lastindex(s) && (isletter(s[j]) || isdigit(s[j]) || s[j] in ('_', '$'))
                    j = nextind(s, j)
                end
                key = s[i:prevind(s, j)]
                i = j
            end
            i = skipws(s, i)
            s[i] == ':' || error("expected ':' after object key '$key'")
            v, i = parse_value(s, nextind(s, i))
            push!(obj, key => v)
            i = skipws(s, i)
            i <= lastindex(s) || error("unterminated object")
            if s[i] == ','
                i = nextind(s, i)
                i = skipws(s, i)
                s[i] == '}' && return obj, nextind(s, i)   # tolerate trailing comma
            elseif s[i] == '}'
                return obj, nextind(s, i)
            else
                error("unexpected char '$(s[i])' in object")
            end
        end
    elseif startswith(SubString(s, i), "true")
        return TSBool(true), i + 4
    elseif startswith(SubString(s, i), "false")
        return TSBool(false), i + 5
    elseif startswith(SubString(s, i), "null")
        return nothing, i + 4
    elseif c == '-' || isdigit(c)
        j = i
        while j <= lastindex(s) && (isdigit(s[j]) || s[j] in ('-', '+', '.', 'e', 'E'))
            j = nextind(s, j)
        end
        tok = s[i:prevind(s, j)]
        # sanity: must reparse as a number
        parse(Float64, tok)
        return TSNum(tok), j
    end
    return error("unrecognized value starting with '$c'")
end

# ---------------------------------------------------------------------------
# Line-oriented TS reader
# ---------------------------------------------------------------------------

struct ParsedModel
    provider::String
    id::String
    fields::TSObject
end

"""
    parse_models_ts(path) -> Vector{ParsedModel}

Read `models.generated.ts` and return every model literal it declares.

Structure relied upon (upstream is machine-generated, so indentation is exact):

    export const MODELS = {
    \\t"<provider>": {
    \\t\\t"<model-id>": {
    \\t\\t\\t<key>: <inline value>,
    \\t\\t\\tcost: {
    \\t\\t\\t\\t<key>: <number>,
    \\t\\t\\t},
    \\t\\t} satisfies Model<"...">,
    \\t},
    } as const;

Anything unexpected raises rather than being silently skipped, so upstream
shape drift surfaces as a generator failure instead of a truncated registry.
"""
function parse_models_ts(path::AbstractString)
    lines = readlines(path)
    models = ParsedModel[]

    start = findfirst(l -> startswith(l, "export const MODELS"), lines)
    start === nothing && error("could not find `export const MODELS` in $path")

    provider = ""
    id = ""
    fields = TSObject()
    nested_key = ""
    nested = TSObject()
    # depth: 1 = inside MODELS, 2 = inside a provider, 3 = inside a model, 4 = inside a nested block
    depth = 1

    for lineno in (start + 1):length(lines)
        raw = lines[lineno]
        line = rstrip(raw)
        isempty(strip(line)) && continue
        line == "} as const;" && break

        indent = something(findfirst(c -> c != '\t', line), length(line) + 1) - 1
        body = lstrip(line, '\t')

        if depth == 1
            if indent == 1 && endswith(body, ": {")
                provider, _ = parse_js_string(body, 1)
                depth = 2
            else
                error("$path:$lineno: expected a provider key, got: $line")
            end
        elseif depth == 2
            if indent == 2 && endswith(body, ": {")
                id, _ = parse_js_string(body, 1)
                fields = TSObject()
                depth = 3
            elseif indent == 1 && (body == "}," || body == "}")
                depth = 1
            else
                error("$path:$lineno: expected a model key or provider close, got: $line")
            end
        elseif depth == 3
            if indent == 2 && (startswith(body, "} satisfies") || body == "}," || body == "}")
                push!(models, ParsedModel(provider, id, fields))
                depth = 2
            elseif indent == 3
                colon = findfirst(==(':'), body)
                colon === nothing && error("$path:$lineno: missing ':' in field line: $line")
                key = strip(body[1:(colon - 1)], ['"', ' '])
                rest = strip(body[(colon + 1):end])
                if rest == "{"
                    nested_key = key
                    nested = TSObject()
                    depth = 4
                else
                    v, _ = parse_value(rest, 1)
                    push!(fields, key => v)
                end
            else
                error("$path:$lineno: unexpected line inside model \"$id\": $line")
            end
        else # depth == 4
            if indent == 3 && (body == "}," || body == "}")
                push!(fields, nested_key => nested)
                depth = 3
            elseif indent == 4
                colon = findfirst(==(':'), body)
                colon === nothing && error("$path:$lineno: missing ':' in nested field line: $line")
                key = strip(body[1:(colon - 1)], ['"', ' '])
                v, _ = parse_value(strip(body[(colon + 1):end]), 1)
                push!(nested, key => v)
            else
                error("$path:$lineno: unexpected line inside \"$id\".$nested_key: $line")
            end
        end
    end

    depth == 1 || error("$path: unbalanced literal (ended at depth $depth)")
    isempty(models) && error("$path: parsed zero models")
    return models
end

# ---------------------------------------------------------------------------
# Julia emission
# ---------------------------------------------------------------------------

function jl_string(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '$'
            print(io, "\\\$")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\r'
            print(io, "\\r")
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

jl_value(v::TSStr) = jl_string(v.value)
jl_value(v::TSNum) = v.token
jl_value(v::TSBool) = v.value ? "true" : "false"
jl_value(::Nothing) = "nothing"
jl_value(v::TSArray) = "[" * join(jl_value.(v), ", ") * "]"
jl_value(v::TSObject) = "Dict(" * join(["$(jl_string(k)) => $(jl_value(x))" for (k, x) in v], ", ") * ")"

function getfieldval(fields::TSObject, key::AbstractString)
    idx = findfirst(p -> first(p) == key, fields)
    return idx === nothing ? nothing : last(fields[idx])
end

function require_field(m::ParsedModel, key::AbstractString)
    v = getfieldval(m.fields, key)
    v === nothing && error("model $(m.provider)/$(m.id) is missing required field `$key`")
    return v
end

"""
    emit_model(io, m)

Write one `"<id>" => Model(...)` entry in the exact field order and formatting
used by the checked-in file. `headers`/`compat` are always emitted (as `nothing`
when absent upstream) so entries are shape-stable; `kw` is never emitted and
falls back to the struct default.
"""
const KNOWN_FIELDS = Set([
    "id", "name", "api", "provider", "baseUrl", "reasoning",
    "input", "cost", "contextWindow", "maxTokens", "headers", "compat",
])

function emit_model(io::IO, m::ParsedModel)
    # Fail loud on upstream schema growth rather than silently dropping a field
    # that `Model` might need to carry.
    for (k, _) in m.fields
        k in KNOWN_FIELDS ||
            error("model $(m.provider)/$(m.id): unknown upstream field `$k` -- update KNOWN_FIELDS/emit_model")
    end
    idfield = require_field(m, "id")
    idfield isa TSStr && idfield.value == m.id ||
        error("model $(m.provider)/$(m.id): `id` field does not match its object key")

    cost = require_field(m, "cost")
    cost isa TSObject || error("model $(m.provider)/$(m.id): `cost` is not an object")
    issetequal(first.(cost), ["input", "output", "cacheRead", "cacheWrite"]) ||
        error("model $(m.provider)/$(m.id): unexpected `cost` keys $(first.(cost))")
    headers = getfieldval(m.fields, "headers")
    compat = getfieldval(m.fields, "compat")

    println(io, "        ", jl_string(m.id), " => Model(")
    println(io, "            id = ", jl_string(m.id), ",")
    println(io, "            name = ", jl_value(require_field(m, "name")), ",")
    println(io, "            api = ", jl_value(require_field(m, "api")), ",")
    println(io, "            provider = ", jl_value(require_field(m, "provider")), ",")
    println(io, "            baseUrl = ", jl_value(require_field(m, "baseUrl")), ",")
    println(io, "            reasoning = ", jl_value(require_field(m, "reasoning")), ",")
    println(io, "            input = ", jl_value(require_field(m, "input")), ",")
    println(io, "            cost = ", jl_value(cost), ",")
    println(io, "            contextWindow = ", jl_value(require_field(m, "contextWindow")), ",")
    println(io, "            maxTokens = ", jl_value(require_field(m, "maxTokens")), ",")
    println(io, "            headers = ", jl_value(headers), ",")
    println(io, "            compat = ", jl_value(compat), ",")
    println(io, "        ),")
    return nothing
end

function git_describe(path::AbstractString)
    dir = isdir(path) ? path : dirname(path)
    try
        out = read(`git -C $dir describe --always --dirty`, String)
        return strip(out)
    catch
        return "unknown"
    end
end

"""
    generate(ts_path, out_path; source_label, describe, date)

Parse `ts_path` and write the Julia registry initializer to `out_path`.
Output is deterministic: providers and model ids are sorted by codepoint, and
every value is derived only from the source file plus the header metadata.
"""
function generate(
        ts_path::AbstractString,
        out_path::AbstractString;
        source_label::AbstractString = ts_path,
        describe::AbstractString = git_describe(ts_path),
        date::AbstractString = string(Dates_today()),
    )
    models = parse_models_ts(ts_path)

    by_provider = Dict{String, Vector{ParsedModel}}()
    for m in models
        push!(get!(() -> ParsedModel[], by_provider, m.provider), m)
    end
    providers = sort!(collect(keys(by_provider)))

    io = IOBuffer()
    println(io, "# This file is auto-generated from models.generated.ts")
    println(io, "# Do not edit manually -- run `julia LLMProviders/gen/generate_models.jl` to refresh.")
    println(io, "#")
    println(io, "# Source:    ", source_label)
    println(io, "# Source rev: ", describe)
    println(io, "# Generated: ", date)
    println(io)
    println(io, "# Initialize model registry")
    println(io, "function _init_model_registry!()")
    println(io, "    empty!(_model_registry)")

    for (idx, provider) in enumerate(providers)
        entries = sort!(by_provider[provider]; by = m -> m.id)
        ids = [m.id for m in entries]
        allunique(ids) || error("duplicate model ids within provider \"$provider\"")

        println(io)
        println(io, "    # $provider models")
        # JuliaFormatter renders the final statement of the function with an
        # explicit `return`; keep that so a formatter pass is a no-op.
        prefix = idx == length(providers) ? "    return " : "    "
        println(io, prefix, "_model_registry[", jl_string(provider), "] = Dict{String, Model}(")
        for m in entries
            emit_model(io, m)
        end
        println(io, "    )")
    end

    println(io)
    println(io, "end")
    println(io)
    println(io, "# Initialize on module load")
    println(io, "_init_model_registry!()")

    mkpath(dirname(abspath(out_path)))
    write(out_path, String(take!(io)))
    return (; providers = length(providers), models = length(models), path = abspath(out_path))
end

# `Dates` is not a dependency of LLMProviders; derive the ISO date from Base.
function Dates_today()
    t = round(Int, time())
    days = t ÷ 86400
    # civil-from-days (Howard Hinnant's algorithm), epoch 1970-01-01
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5 * doy + 2) ÷ 153
    d = doy - (153 * mp + 2) ÷ 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    y += (m <= 2)
    return string(y, "-", lpad(m, 2, '0'), "-", lpad(d, 2, '0'))
end

"""
    tildify(path)

Render an absolute path under `\$HOME` as `~/...` so the generated header does
not bake one developer's home directory into a checked-in file.
"""
function tildify(path::AbstractString)
    home = homedir()
    return startswith(path, home * "/") ? "~" * path[(length(home) + 1):end] : path
end

function default_ts_path()
    env = get(ENV, "PI_MONO_MODELS_TS", "")
    isempty(env) || return env
    root = get(ENV, "PI_MONO", joinpath(homedir(), "pi-mono"))
    return joinpath(root, DEFAULT_TS_RELPATH)
end

function main(args::Vector{String})
    ts_path = (isempty(args) || isempty(args[1])) ? default_ts_path() : args[1]
    out_path = length(args) >= 2 ? args[2] :
        normpath(joinpath(@__DIR__, "..", "src", "models_generated.jl"))
    isfile(ts_path) || error("source file not found: $ts_path (set PI_MONO or PI_MONO_MODELS_TS, or pass it as arg 1)")

    result = generate(ts_path, out_path; source_label = tildify(abspath(ts_path)))
    println("wrote $(result.path)")
    println("  providers: $(result.providers)")
    println("  models:    $(result.models)")
    return nothing
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(copy(ARGS))
