# Eval tasks: small, self-contained coding tasks with programmatic pass/fail
# checks. Each task is (name, setup, prompt, check):
#   setup(dir)  — create the task's files in an empty directory
#   prompt      — the user request given to the agent
#   check(dir)  — true iff the agent solved the task
#
# Tasks only need a bare `julia` on PATH (no package deps). Together they cover
# the core competencies of a coding agent: explore, implement, fix, refactor,
# create, and edit precisely.

function _run_ok(dir, cmd)
    return success(pipeline(Cmd(cmd; dir); stdout = devnull, stderr = devnull))
end

const TASKS = [

(
    name = "fix-bug",
    setup = function (dir)
        write(joinpath(dir, "stats.jl"), """
            function mean(xs)
                total = 0.0
                for i in 1:(length(xs) - 1)
                    total += xs[i]
                end
                return total / length(xs)
            end
            """)
        write(joinpath(dir, "test_stats.jl"), """
            include("stats.jl")
            using Test
            @test mean([1.0, 2.0, 3.0]) == 2.0
            @test mean([4.0]) == 4.0
            println("OK")
            """)
    end,
    prompt = "The test in test_stats.jl fails. Find the bug and fix it so the test passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_stats.jl`),
),

(
    name = "implement",
    setup = function (dir)
        write(joinpath(dir, "slug.jl"), """
            \"\"\"
                slugify(s) -> String

            Lowercase `s`, replace runs of non-alphanumeric characters with a single
            dash, and strip leading/trailing dashes.
            \"\"\"
            function slugify(s::AbstractString)
                error("not implemented")
            end
            """)
        write(joinpath(dir, "test_slug.jl"), """
            include("slug.jl")
            using Test
            @test slugify("Hello, World!") == "hello-world"
            @test slugify("  Julia 1.12 -- fast!  ") == "julia-1-12-fast"
            @test slugify("already-a-slug") == "already-a-slug"
            println("OK")
            """)
    end,
    prompt = "Implement slugify in slug.jl per its docstring so test_slug.jl passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_slug.jl`),
),

(
    name = "hidden-bug",
    setup = function (dir)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "parse.jl"), """
            parse_amount(s) = Base.parse(Float64, strip(s))
            """)
        write(joinpath(dir, "src", "format.jl"), """
            format_cents(c) = string(div(c, 100)) * "." * lpad(rem(c, 100), 2, '0')
            """)
        write(joinpath(dir, "src", "convert.jl"), """
            # dollars -> cents
            to_cents(d) = Int(floor(d * 100))
            """)
        write(joinpath(dir, "src", "lib.jl"), """
            include("parse.jl")
            include("format.jl")
            include("convert.jl")
            roundtrip(s) = format_cents(to_cents(parse_amount(s)))
            """)
        write(joinpath(dir, "test_lib.jl"), """
            include("src/lib.jl")
            using Test
            @test roundtrip("19.99") == "19.99"
            @test roundtrip("0.07") == "0.07"
            @test roundtrip("1.10") == "1.10"
            println("OK")
            """)
    end,
    prompt = "test_lib.jl fails on some inputs. Track down the bug in src/ and fix it so the test passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_lib.jl`),
),

(
    name = "refactor-rename",
    setup = function (dir)
        write(joinpath(dir, "core.jl"), """
            procces_data(xs) = sort(unique(xs))
            """)
        write(joinpath(dir, "report.jl"), """
            include("core.jl")
            report(xs) = join(procces_data(xs), ",")
            """)
        write(joinpath(dir, "main.jl"), """
            include("report.jl")
            # procces_data powers the report below
            println(report([3, 1, 2, 1]))
            """)
    end,
    prompt = "The function procces_data is misspelled. Rename it to process_data everywhere (including comments) so main.jl still works.",
    check = function (dir)
        for f in ("core.jl", "report.jl", "main.jl")
            occursin("procces", read(joinpath(dir, f), String)) && return false
        end
        out = try
            read(Cmd(`julia --startup-file=no main.jl`; dir), String)
        catch
            return false
        end
        return strip(out) == "1,2,3"
    end,
),

(
    name = "create-file",
    setup = dir -> nothing,
    prompt = "Create a script fizzbuzz.jl that prints the numbers 1 to 20, one per line, but prints Fizz for multiples of 3, Buzz for multiples of 5, and FizzBuzz for multiples of both.",
    check = function (dir)
        isfile(joinpath(dir, "fizzbuzz.jl")) || return false
        out = try
            read(Cmd(`julia --startup-file=no fizzbuzz.jl`; dir), String)
        catch
            return false
        end
        expected = join([n % 15 == 0 ? "FizzBuzz" : n % 3 == 0 ? "Fizz" : n % 5 == 0 ? "Buzz" : string(n) for n in 1:20], "\n")
        return strip(out) == expected
    end,
),

(
    name = "precise-edit",
    setup = function (dir)
        lines = ["setting_$(i) = $(i * 10)" for i in 1:300]
        write(joinpath(dir, "settings.conf"), join(lines, "\n") * "\n")
    end,
    prompt = "In settings.conf, change the value of setting_137 to 9999. Change nothing else.",
    check = function (dir)
        content = read(joinpath(dir, "settings.conf"), String)
        expected = join(["setting_$(i) = $(i == 137 ? 9999 : i * 10)" for i in 1:300], "\n") * "\n"
        return content == expected
    end,
),

]
