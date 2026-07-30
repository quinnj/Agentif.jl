using Test
using HTTP
using Sockets
using LLMTools

function web_funcs()
    return Dict(tool.name => tool.func for tool in LLMTools.web_tools())
end

@testset "Web tools" begin
    funcs = web_funcs()
    web_fetch = funcs["web_fetch"]
    web_search = funcs["web_search"]

    @testset "POST requests with body" begin
        server = HTTP.serve!(ip"127.0.0.1", 0) do req
            body = String(req.body)
            return HTTP.Response(200, ["Content-Type" => "text/plain"], "method=$(req.method);body=$body")
        end

        try
            sock = getsockname(server.listener.server)
            port = sock[2]
            url = "http://127.0.0.1:$port/echo"
            result = web_fetch(url, "POST", nothing, "hello-post", false, 10, nothing, nothing)
            @test occursin("Status: 200", result)
            @test occursin("method=POST;body=hello-post", result)
        finally
            close(server)
        end
    end

    @testset "Cached binary content handling" begin
        mktemp() do path, io
            write(io, UInt8[0xff, 0x00, 0xfe, 0x7f])
            flush(io)

            binary_id = LLMTools.register_temp_file(path; is_binary = true, content_type = "application/octet-stream")
            binary_msg = LLMTools.read_cached_web_content(binary_id, nothing, false)
            @test occursin("Binary content", binary_msg)

            unknown_id = LLMTools.register_temp_file(path)
            unknown_msg = LLMTools.read_cached_web_content(unknown_id, nothing, false)
            @test occursin("cannot be rendered as UTF-8", unknown_msg)
        end
    end

    @testset "Offset preview honors offset on initial fetch" begin
        payload = join(["line $(i)" for i in 1:120], "\n")
        server = HTTP.serve!(ip"127.0.0.1", 0) do req
            HTTP.Response(200, ["Content-Type" => "text/plain"], payload)
        end

        try
            sock = getsockname(server.listener.server)
            port = sock[2]
            url = "http://127.0.0.1:$port/lines"
            result = web_fetch(url, "GET", nothing, nothing, false, 10, nothing, 50)
            @test occursin("--- Content Preview ---", result)
            @test occursin("line 50", result)
            @test !occursin("line 1\nline 2\nline 3", result)
        finally
            close(server)
        end
    end

    @testset "DuckDuckGo lite parser filters ads and decodes URLs" begin
        html = """
        <html><body>
        <a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs&rut=abc" class='result-link'>Example &amp; Docs</a>
        <td class='result-snippet'>A <b>useful</b> snippet.</td>
        <a href="//duckduckgo.com/y.js?ad_provider=test" class='result-link'>Sponsored</a>
        <td class='result-snippet'>Ad content</td>
        <a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.julialang.org%2Fen%2Fv1%2F&rut=def" class='result-link'>Julia Docs</a>
        <td class='result-snippet'>The Julia Language documentation.</td>
        </body></html>
        """
        parsed = LLMTools.parse_duckduckgo_lite_results(html)
        @test length(parsed) == 2
        @test parsed[1][1] == "Example & Docs"
        @test parsed[1][2] == "https://example.com/docs"
        @test occursin("useful snippet", lowercase(parsed[1][3]))
        @test parsed[2][2] == "https://docs.julialang.org/en/v1/"
    end

    @testset "web_search validates empty query" begin
        @test_throws ArgumentError web_search("   ", 5, 5)
    end

    @testset "Numeric entity decoding is UTF-8 safe" begin
        # Valid decimal and hex entities still decode
        @test LLMTools.extract_text_from_html("<p>&#65;&#x42;</p>") == "AB"

        # Overflow-huge, out-of-range, and surrogate values must not throw and
        # must decode to the replacement character
        for bad in ("&#99999999999999999999;", "&#99999999;", "&#xD800;", "&#xdfff;", "&#x110000;")
            out = LLMTools.extract_text_from_html("<p>before " * bad * " after</p>")
            @test isvalid(out)
            @test occursin('�', out)
            @test occursin("before", out)
            @test occursin("after", out)
        end

        # Mixed with surrounding multi-byte text and a valid astral-plane entity
        out = LLMTools.extract_text_from_html("<p>café &#xD800; déjà &#128512;</p>")
        @test isvalid(out)
        @test occursin("café", out)
        @test occursin("déjà", out)
        @test occursin("😀", out)
        @test occursin('�', out)
    end

    @testset "decode_numeric_entity" begin
        @test LLMTools.decode_numeric_entity("&#65;") == "A"
        @test LLMTools.decode_numeric_entity("&#x1F600;") == "😀"
        @test LLMTools.decode_numeric_entity("&#0;") == "\0"
        @test LLMTools.decode_numeric_entity("&#1114111;") == "\U10FFFF"
        @test LLMTools.decode_numeric_entity("&#1114112;") == "�"   # scalar range + 1
        @test LLMTools.decode_numeric_entity("&#xD800;") == "�"     # surrogate low bound
        @test LLMTools.decode_numeric_entity("&#xDFFF;") == "�"     # surrogate high bound
        @test LLMTools.decode_numeric_entity("&#55296;") == "�"     # 0xD800 in decimal
        @test LLMTools.decode_numeric_entity("&#99999999999999999999;") == "�"  # Int overflow
    end

    @testset "repair_utf8" begin
        good = "café 😀"
        @test LLMTools.repair_utf8(good) == good
        # 'a', an unpaired-surrogate byte sequence, 'b'
        bad = String(UInt8[0x61, 0xed, 0xa0, 0x80, 0x62])
        @test !isvalid(bad)
        repaired = LLMTools.repair_utf8(bad)
        @test isvalid(repaired)
        @test startswith(repaired, "a")
        @test endswith(repaired, "b")
        @test occursin('�', repaired)
    end
end
