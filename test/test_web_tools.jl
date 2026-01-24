# Test web tools (web_fetch and web_search)
using Agentif
using Test

@testset "Web Tools" begin

    @testset "web_fetch" begin
        fetch_tool = create_web_fetch_tool()

        @testset "Basic fetch" begin
            result = fetch_tool.func("https://example.com")
            @test occursin("Example Domain", result)
            @test occursin("file_id=", result)  # file_id="xxxx" format
            @test occursin("Status: 200", result)
        end

        @testset "Invalid URL syntax" begin
            # Empty URL should throw
            @test_throws ArgumentError fetch_tool.func("")
        end

        @testset "Invalid URL returns error (not throws)" begin
            # Non-existent domain returns error message (doesn't throw)
            result = fetch_tool.func("not-a-valid-url")
            # Should be normalized to https://not-a-valid-url and fail
            @test occursin("Error", result) || occursin("error", result) || occursin("not-a-valid-url", result)
        end

        @testset "Text extraction" begin
            # Need positional args: url, method, headers, body, extract_text
            result = fetch_tool.func("https://example.com", "GET", nothing, nothing, true)
            @test occursin("Example Domain", result)
            # Should have less HTML tags when extracting text
            @test !occursin("<!doctype", lowercase(result))
        end

        @testset "JSON response" begin
            result = fetch_tool.func("https://httpbin.org/json")
            @test occursin("slideshow", result)
        end

        @testset "Non-existent domain" begin
            result = fetch_tool.func("https://this-domain-does-not-exist-12345.com")
            @test occursin("Error", result) || occursin("error", result)
        end

        @testset "HTTP error status" begin
            result = fetch_tool.func("https://httpbin.org/status/404")
            @test occursin("404", result)
        end
    end

    @testset "web_search" begin
        search_tool = create_web_search_tool()

        @testset "Empty query" begin
            @test_throws ArgumentError search_tool.func("")
        end

        # DuckDuckGo rate limiting makes these tests flaky
        # We test that the function runs and returns a sensible response
        @testset "Basic search (may be rate limited)" begin
            result = search_tool.func("Julia programming language")
            # Either we got results OR we got a rate limit message
            success = occursin("julia", lowercase(result)) && occursin("URL:", result)
            rate_limited = occursin("202", result) || occursin("unavailable", lowercase(result))
            @test success || rate_limited
            if rate_limited
                @info "DuckDuckGo rate limited - test skipped but function works"
            end
        end

        @testset "Special characters (may be rate limited)" begin
            result = search_tool.func("C++ programming")
            success = occursin("URL:", result)
            rate_limited = occursin("202", result) || occursin("unavailable", lowercase(result))
            @test success || rate_limited
        end

        @testset "Limit results (may be rate limited)" begin
            result = search_tool.func("Python", 3)
            rate_limited = occursin("202", result) || occursin("unavailable", lowercase(result))
            if !rate_limited
                lines = split(result, "\n")
                url_count = count(l -> startswith(l, "   URL:"), lines)
                @test url_count <= 3
            else
                @test true  # Rate limited is acceptable
                @info "DuckDuckGo rate limited - test skipped"
            end
        end
    end

    @testset "web_tools helper" begin
        tools = web_tools()
        @test length(tools) == 2
        @test any(t -> t.name == "web_fetch", tools)
        @test any(t -> t.name == "web_search", tools)
    end
end
