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

        @testset "dangling symlink containment" begin
            mktempdir() do outside
                target = joinpath(outside, "created.txt")
                symlink(target, joinpath(tmpdir, "escape.txt"))
                @test islink(joinpath(tmpdir, "escape.txt"))
                @test !ispath(joinpath(tmpdir, "escape.txt"))
                @test_throws ArgumentError write_file("escape.txt", "outside")
                @test !isfile(target)
            end
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

        @testset "ls/find/grep honor git ignore rules" begin
            write_file(".gitignore", "*.log\nbuild/\n")
            write_file(".env", "needle visible dotfile")
            write_file("visible.txt", "needle visible")
            write_file("ignored.log", "needle ignored")
            write_file("build/output.txt", "needle ignored")
            write_file("nested/.gitignore", "ignored.txt\n!keep.log\n")
            write_file("nested/ignored.txt", "needle ignored")
            write_file("nested/keep.log", "needle visible")
            write_file("nested/visible.md", "needle visible")
            write_file(".git/objects/blob", "needle ignored")

            listing = ls_dir(".", 50)
            @test occursin(".env", listing)
            @test occursin(".gitignore", listing)
            @test occursin("visible.txt", listing)
            @test !occursin(".git/", listing)
            @test !occursin("ignored.log", listing)
            @test !occursin("build/", listing)

            nested_listing = ls_dir("nested", 50)
            @test occursin("keep.log", nested_listing)
            @test occursin("visible.md", nested_listing)
            @test !occursin("ignored.txt", nested_listing)

            found = find_files("**", nothing, 50)
            @test occursin(".env", found)
            @test occursin("visible.txt", found)
            @test occursin("nested/keep.log", found)
            @test !occursin(".git/", found)
            @test !occursin("ignored.log", found)
            @test !occursin("build/", found)
            @test !occursin("nested/ignored.txt", found)

            matches = grep_files("needle", ".", nothing, false, true, 0, 50)
            @test occursin(".env:1: needle visible dotfile", matches)
            @test occursin("visible.txt:1: needle visible", matches)
            @test occursin("nested/keep.log:1: needle visible", matches)
            @test occursin("nested/visible.md:1: needle visible", matches)
            @test !occursin(".git/", matches)
            @test !occursin("ignored.log", matches)
            @test !occursin("build/", matches)
            @test !occursin("nested/ignored.txt", matches)

            explicit_listing = ls_dir("build", 50)
            @test occursin("output.txt", explicit_listing)

            explicitly_found = find_files("**", "build", 50)
            @test occursin("output.txt", explicitly_found)

            explicit_match = grep_files("needle", "ignored.log", nothing, false, true, 0, 50)
            @test occursin("ignored.log:1: needle ignored", explicit_match)
        end
    end
end

@testset "File tools honor repository rules above base" begin
    mktempdir() do repo
        mkpath(joinpath(repo, ".git"))
        mkpath(joinpath(repo, "src"))
        write(joinpath(repo, ".gitignore"), "src/*.log\n")
        write(joinpath(repo, "src", "ignored.log"), "needle ignored")
        write(joinpath(repo, "src", "visible.txt"), "needle visible")

        funcs = file_funcs(joinpath(repo, "src"))
        listing = funcs["ls"](".", 20)
        @test occursin("visible.txt", listing)
        @test !occursin("ignored.log", listing)

        found = funcs["find"]("**", nothing, 20)
        @test occursin("visible.txt", found)
        @test !occursin("ignored.log", found)

        matches = funcs["grep"]("needle", ".", nothing, false, true, 0, 20)
        @test occursin("visible.txt:1: needle visible", matches)
        @test !occursin("ignored.log", matches)

        explicit_match = funcs["grep"]("needle", "ignored.log", nothing, false, true, 0, 20)
        @test occursin("ignored.log:1: needle ignored", explicit_match)
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
