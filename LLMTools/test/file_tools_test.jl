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

@testset "File tools multi-byte safety" begin
    mktempdir() do tmpdir
        funcs = file_funcs(tmpdir)
        read_file = funcs["read"]
        write_file = funcs["write"]
        edit_file = funcs["edit"]
        find_files = funcs["find"]

        @testset "edit: oldText ends with multi-byte char" begin
            write_file("mb1.txt", "prefix café suffix")
            msg = edit_file("mb1.txt", "café", "tea")
            @test occursin("Successfully replaced text", msg)
            result = read_file("mb1.txt", nothing, nothing)
            @test isvalid(result)
            @test result == "prefix tea suffix"
        end

        @testset "edit: match immediately preceded by multi-byte char" begin
            write_file("mb2.txt", "héllo world")
            msg = edit_file("mb2.txt", "llo world", "y planet")
            @test occursin("Successfully replaced text", msg)
            result = read_file("mb2.txt", nothing, nothing)
            @test isvalid(result)
            @test result == "héy planet"
        end

        @testset "edit: emoji-terminated oldText at end of file" begin
            write_file("mb3.txt", "status: done 🎉")
            msg = edit_file("mb3.txt", "done 🎉", "shipped 🚀")
            @test occursin("Successfully replaced text", msg)
            result = read_file("mb3.txt", nothing, nothing)
            @test isvalid(result)
            @test result == "status: shipped 🚀"
        end

        @testset "edit: multi-byte match spans whole file" begin
            write_file("mb4.txt", "é")
            msg = edit_file("mb4.txt", "é", "e")
            @test occursin("Successfully replaced text", msg)
            result = read_file("mb4.txt", nothing, nothing)
            @test isvalid(result)
            @test result == "e"
        end

        @testset "glob_to_regex with non-ASCII pattern" begin
            rx = LLMTools.glob_to_regex("café*.jl")
            @test occursin(rx, "café_test.jl")
            @test !occursin(rx, "cafe_test.jl")
            rx2 = LLMTools.glob_to_regex("**/déjà?.txt")
            @test occursin(rx2, "a/b/déjàX.txt")
            @test !occursin(rx2, "a/b/déjà.txt")
        end

        @testset "find with non-ASCII glob" begin
            write_file("café/menu.txt", "espresso")
            found = find_files("café/*.txt", nothing, 20)
            @test occursin("café/menu.txt", found)
        end

        @testset "strip_dir_suffix multi-byte" begin
            @test LLMTools.strip_dir_suffix("café/") == "café"
            @test LLMTools.strip_dir_suffix("café") == "café"
            @test LLMTools.strip_dir_suffix("ascii/") == "ascii"
            @test LLMTools.strip_dir_suffix("") == ""
        end
    end
end
