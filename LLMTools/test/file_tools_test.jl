using Test
using LLMTools

function file_funcs(base_dir::AbstractString)
    tools = [
        LLMTools.create_read_tool(base_dir),
        LLMTools.create_write_tool(base_dir),
        LLMTools.create_edit_tool(base_dir),
        LLMTools.create_ls_tool(base_dir),
        LLMTools.create_find_tool(base_dir),
        LLMTools.create_grep_tool(base_dir),
    ]
    return Dict(tool.name => tool.func for tool in tools)
end

@testset "File tools" begin
    mktempdir() do tmpdir
        funcs = file_funcs(tmpdir)
        read_file = funcs["read"]
        write_file = funcs["write"]
        edit_file = funcs["edit"]
        ls_dir = funcs["ls"]
        find_files = funcs["find"]
        grep_files = funcs["grep"]

        @testset "write/read/edit" begin
            write_msg = write_file("src/example.txt", "hello\nworld")
            @test occursin("Successfully wrote", write_msg)

            content = read_file("src/example.txt", nothing, nothing)
            @test content == "hello\nworld"

            edit_msg = edit_file("src/example.txt", "world", "julia")
            @test occursin("Successfully replaced text", edit_msg)

            updated = read_file("src/example.txt", nothing, nothing)
            @test updated == "hello\njulia"
        end

        @testset "ls/find/grep" begin
            mkpath(joinpath(tmpdir, "notes"))
            write_file("notes/todo.txt", "buy milk")
            write_file("notes/ideas.md", "agent ideas")

            listing = ls_dir(".", 50)
            @test occursin("notes/", listing)
            @test occursin("src/", listing)

            found = find_files("**/*.txt", nothing, 20)
            @test occursin("src/example.txt", found)
            @test occursin("notes/todo.txt", found)

            grep_literal = grep_files("julia", ".", "**/*.txt", false, true, 0, 20)
            @test occursin("src/example.txt:2: julia", grep_literal)

            grep_regex = grep_files("^buy", ".", "**/*.txt", false, false, 0, 20)
            @test occursin("notes/todo.txt:1: buy milk", grep_regex)
        end
    end
end
