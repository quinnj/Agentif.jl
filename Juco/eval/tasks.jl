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

# ─── Harder tasks (added for the iteration phase) ───

(
    name = "multi-file-feature",
    setup = function (dir)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "Queue.jl"), """
            # A simple FIFO queue used as the style reference for this codebase.
            struct Queue
                items::Vector{Any}
            end
            Queue() = Queue(Any[])
            enqueue!(q::Queue, x) = (push!(q.items, x); q)
            dequeue!(q::Queue) = popfirst!(q.items)
            Base.isempty(q::Queue) = isempty(q.items)
            Base.length(q::Queue) = length(q.items)
            """)
        write(joinpath(dir, "src", "Collections.jl"), """
            module Collections
            include("Queue.jl")
            export Queue, enqueue!, dequeue!
            end
            """)
        write(joinpath(dir, "test_stack.jl"), """
            include("src/Collections.jl")
            using .Collections, Test
            s = Stack()
            push!(s, 1); push!(s, 2); push!(s, 3)
            @test peek(s) == 3
            @test pop!(s) == 3
            @test pop!(s) == 2
            @test length(s) == 1
            @test !isempty(s)
            @test pop!(s) == 1
            @test isempty(s)
            println("OK")
            """)
    end,
    prompt = "Add a Stack type to the Collections module (src/) with push!, pop!, peek, isempty, and length support, following the existing Queue style, so test_stack.jl passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_stack.jl`),
),

(
    name = "debug-suite",
    setup = function (dir)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "text.jl"), """
            # Count words in a string.
            count_words(s) = length(split(strip(s)))

            # Reverse each word but keep word order.
            function reverse_words(s)
                join(reverse.(split(s, " ")), " ")
            end

            # Truncate to n chars, appending an ellipsis when truncated
            function truncate_text(s, n)
                length(s) <= n && return s
                return first(s, n) * "..."
            en
            """)
        write(joinpath(dir, "src", "num.jl"), """
            # Sum of digits of a non-negative integer.
            function digit_sum(n)
                total = 0
                while n > 0
                    total += n % 10
                    n = n ÷ 10
                end
                return total
            end

            # Clamp x into [lo, hi].
            clamp_to(x, lo, hi) = max(lo, min(hi, lo))
            """)
        write(joinpath(dir, "runtests.jl"), """
            include("src/text.jl")
            include("src/num.jl")
            using Test
            @test count_words("  the quick brown fox  ") == 4
            @test reverse_words("abc def") == "cba fed"
            @test truncate_text("hello world", 5) == "hello..."
            @test truncate_text("hi", 5) == "hi"
            @test digit_sum(1234) == 10
            @test clamp_to(5, 1, 10) == 5
            @test clamp_to(-3, 1, 10) == 1
            @test clamp_to(42, 1, 10) == 10
            println("OK")
            """)
    end,
    prompt = "runtests.jl fails to even load: there are multiple distinct problems in src/ (at least one syntax error and at least one logic bug). Fix the source files — do not change runtests.jl — until the whole suite passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no runtests.jl`),
),

(
    name = "needle",
    setup = function (dir)
        mkpath(joinpath(dir, "src"))
        for i in 1:40
            body = i == 23 ?
                "handler_23(x) = x * 2  # BUG: spec says triple\n" :
                "handler_$(i)(x) = x * 3\n"
            write(joinpath(dir, "src", "handler_$(lpad(i, 2, '0')).jl"), body)
        end
        write(joinpath(dir, "main.jl"), """
            for f in sort(readdir("src"))
                include(joinpath("src", f))
            end
            using Test
            for i in 1:40
                h = getfield(Main, Symbol("handler_", i))
                @test h(7) == 21
            end
            println("OK")
            """)
    end,
    prompt = "Exactly one of the 40 handlers in src/ violates the spec that every handler must triple its input. main.jl catches it. Find the offender efficiently and fix it. Do not modify main.jl.",
    check = dir -> _run_ok(dir, `julia --startup-file=no main.jl`),
),

(
    name = "api-migration",
    setup = function (dir)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "client.jl"), """
            \"\"\"
                request(url; retries = 0)

            Fake HTTP client. `retries` is the number of retries AFTER the initial
            attempt (so retries = 2 means up to 3 total attempts).
            \"\"\"
            function request(url; retries::Int = 0)
                attempts_made = 1 + retries
                return "GET \$url [\$attempts_made attempts]"
            end
            """)
        write(joinpath(dir, "src", "api.jl"), """
            include("client.jl")
            fetch_user(id) = request("/users/\$id"; retries = 2)
            fetch_repo(name) = request("/repos/\$name"; retries = 4)
            fetch_status() = request("/status")
            """)
        write(joinpath(dir, "migration_test.jl"), """
            include("src/api.jl")
            using Test
            # After migration: request takes `attempts` = TOTAL attempt count,
            # and callers must preserve their current total-attempt behavior.
            @test request("/x"; attempts = 3) == "GET /x [3 attempts]"
            @test request("/x") == "GET /x [1 attempts]"
            @test fetch_user(1) == "GET /users/1 [3 attempts]"
            @test fetch_repo("a") == "GET /repos/a [5 attempts]"
            @test fetch_status() == "GET /status [1 attempts]"
            println("OK")
            """)
    end,
    prompt = "Migrate the request API in src/ from `retries` (count after the first attempt) to `attempts` (total attempt count, default 1), updating the docstring and every call site so behavior is preserved and migration_test.jl passes. The old `retries` keyword must be fully gone.",
    check = function (dir)
        occursin("retries", read(joinpath(dir, "src", "client.jl"), String)) && return false
        occursin("retries", read(joinpath(dir, "src", "api.jl"), String)) && return false
        return _run_ok(dir, `julia --startup-file=no migration_test.jl`)
    end,
),

(
    name = "output-discipline",
    setup = function (dir)
        write(joinpath(dir, "process.jl"), """
            # Processes 8000 records; record 4217 is corrupt.
            for i in 1:8000
                if i == 4217
                    println("record \$i: ERROR malformed field 'qty' (got \\"seven\\")")
                else
                    println("record \$i: ok")
                end
            end
            """)
        write(joinpath(dir, "records.csv"),
            join(["id_$(i),$(i == 4217 ? "seven" : string(i % 50))" for i in 1:8000], "\n") * "\n")
    end,
    prompt = "Running `julia process.jl` reports exactly one corrupt record buried in ~8000 lines of output. Find which record is corrupt and fix its qty field in records.csv to the number 7. Change only that one line.",
    check = function (dir)
        lines = readlines(joinpath(dir, "records.csv"))
        length(lines) == 8000 || return false
        lines[4217] == "id_4217,7" || return false
        for (i, line) in enumerate(lines)
            i == 4217 && continue
            line == "id_$(i),$(i % 50)" || return false
        end
        return true
    end,
),

]
