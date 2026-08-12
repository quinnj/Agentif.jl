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
        # the retries KEYWORD must be gone (prose like "no retries" in a docstring is fine)
        kw = r"retries\s*(=|::)|;\s*retries\b"
        occursin(kw, read(joinpath(dir, "src", "client.jl"), String)) && return false
        occursin(kw, read(joinpath(dir, "src", "api.jl"), String)) && return false
        return _run_ok(dir, `julia --startup-file=no migration_test.jl`)
    end,
),

(
    name = "output-discipline",
    setup = function (dir)
        write(joinpath(dir, "process.jl"), """
            # Validates every record in records.csv.
            for (i, line) in enumerate(eachline("records.csv"))
                id, qty = split(line, ",")
                parsed = tryparse(Int, qty)
                if parsed === nothing
                    println("record \$i (\$id): ERROR malformed field 'qty' (got \\"\$qty\\")")
                else
                    println("record \$i (\$id): ok")
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


# ─── Round-2 tasks (added with the second iteration phase) ───


(
    name = "regression-guard",
    setup = function (dir)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "qty.jl"), """
            # Shared quantity parser used across the codebase.
            parse_qty(s) = parse(Int, strip(s))
            """)
        write(joinpath(dir, "src", "orders.jl"), """
            include("qty.jl")
            order_total(qtys) = sum(parse_qty, qtys)
            """)
        write(joinpath(dir, "src", "audit.jl"), """
            include("qty.jl")
            # Audit rejects malformed rows loudly.
            audit_row(s) = try
                parse_qty(s)
                "ok"
            catch
                "reject"
            end
            """)
        write(joinpath(dir, "test_orders.jl"), """
            include("src/orders.jl")
            using Test
            # Order sheets use underscore thousands separators.
            @test order_total(["1_000", "2_500", "7"]) == 3507
            @test order_total(["10", "20"]) == 30
            println("OK")
            """)
        write(joinpath(dir, "test_audit.jl"), """
            include("src/audit.jl")
            using Test
            @test audit_row("42") == "ok"
            @test audit_row("abc") == "reject"
            @test audit_row("") == "reject"
            @test audit_row("4.5") == "reject"
            println("OK")
            """)
    end,
    prompt = "test_orders.jl fails. Fix the code so BOTH test_orders.jl and test_audit.jl pass — do not modify either test file.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_orders.jl`) &&
        _run_ok(dir, `julia --startup-file=no test_audit.jl`),
),

(
    name = "perf-fix",
    setup = function (dir)
        write(joinpath(dir, "render.jl"), """
            # Renders n table rows into a single string.
            function render_rows(n)
                out = ""
                for i in 1:n
                    out = out * "row " * string(i) * ": " * string(i * i) * "\\n"
                end
                return out
            end
            """)
        write(joinpath(dir, "test_render.jl"), """
            include("render.jl")
            using Test
            small = render_rows(3)
            @test small == "row 1: 1\\nrow 2: 4\\nrow 3: 9\\n"
            big_ref = Ref{String}()
            t0 = time()
            allocated = @allocated big_ref[] = render_rows(20_000)
            elapsed = time() - t0
            big = big_ref[]
            @test endswith(big, "row 20000: 400000000\\n")
            @test count(==('\\n'), big) == 20_000
            @test allocated < 100_000_000  # quadratic concatenation allocates several GB
            @test elapsed < 5.0
            println("OK")
            """)
    end,
    prompt = "test_render.jl fails its performance assertion. Make render_rows efficient enough (same output) so the test passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_render.jl`),
),

(
    name = "unicode-edit",
    setup = function (dir)
        write(joinpath(dir, "menu.jl"), """
            const MENU = [
                ("café ☕", 3.50),
                ("汉堡 🍔", 8.25),
                ("寿司 🍣", 12.00),
                ("crêpe 🥞", 6.75),
            ]
            price_of(name) = only(p for (n, p) in MENU if n == name)
            """)
        write(joinpath(dir, "test_menu.jl"), """
            include("menu.jl")
            using Test
            @test price_of("汉堡 🍔") == 9.75
            @test price_of("café ☕") == 3.50
            @test price_of("寿司 🍣") == 12.00
            println("OK")
            """)
    end,
    prompt = "The burger price changed: update 汉堡 🍔 to 9.75 in menu.jl so test_menu.jl passes. Change nothing else.",
    check = function (dir)
        content = read(joinpath(dir, "menu.jl"), String)
        occursin("(\"汉堡 🍔\", 9.75)", content) || return false
        occursin("(\"café ☕\", 3.50)", content) || return false
        return _run_ok(dir, `julia --startup-file=no test_menu.jl`)
    end,
),

(
    name = "json-log-mine",
    setup = function (dir)
        lines = String[]
        for i in 1:5000
            dur = i == 3141 ? 98765 : (i * 7) % 900 + 10
            push!(lines, "{\"req\": \"req-$(lpad(i, 5, '0'))\", \"path\": \"/api/v$(i % 3)\", \"duration_ms\": $(dur), \"status\": $(i % 17 == 0 ? 500 : 200)}")
        end
        write(joinpath(dir, "requests.jsonl"), join(lines, "\n") * "\n")
    end,
    prompt = "requests.jsonl has one JSON object per line. Find the req id with the highest duration_ms and write EXACTLY that id (nothing else) to answer.txt.",
    check = function (dir)
        isfile(joinpath(dir, "answer.txt")) || return false
        return strip(read(joinpath(dir, "answer.txt"), String)) == "req-03141"
    end,
),

(
    name = "cross-file-invariant",
    setup = function (dir)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "colors.jl"), """
            const SUPPORTED_COLORS = ["red", "green", "blue"]
            """)
        write(joinpath(dir, "src", "render.jl"), """
            include("colors.jl")
            function ansi_code(color)
                color == "red" && return 31
                color == "green" && return 32
                color == "blue" && return 34
                error("unsupported color: \$color")
            end
            """)
        write(joinpath(dir, "docs.md"), """
            # Supported colors

            | color | ansi |
            |-------|------|
            | red   | 31   |
            | green | 32   |
            | blue  | 34   |
            """)
        write(joinpath(dir, "test_colors.jl"), """
            include("src/render.jl")
            using Test
            @test "purple" in SUPPORTED_COLORS
            @test ansi_code("purple") == 35
            for c in SUPPORTED_COLORS
                @test ansi_code(c) isa Int
            end
            # docs table must list every supported color with its code
            doc = read("docs.md", String)
            for c in SUPPORTED_COLORS
                @test occursin(Regex("\\\\|\\\\s*" * c * "\\\\s*\\\\|\\\\s*" * string(ansi_code(c)) * "\\\\s*\\\\|"), doc)
            end
            println("OK")
            """)
    end,
    prompt = "Add support for the color purple (ansi code 35): it must be registered, renderable, and documented, consistently across the project, so test_colors.jl passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_colors.jl`),
),

(
    name = "flaky-test",
    setup = function (dir)
        write(joinpath(dir, "inventory.jl"), """
            # Returns items formatted as "name=count", one per line.
            function inventory_report(items::Dict{String, Int})
                lines = String[]
                for (k, v) in items
                    push!(lines, "\$(k)=\$(v)")
                end
                return join(lines, "\\n")
            end
            """)
        write(joinpath(dir, "test_inventory.jl"), """
            include("inventory.jl")
            using Test
            items = Dict("zinc" => 3, "apple" => 5, "mango" => 2, "kiwi" => 9, "fig" => 1,
                         "pear" => 4, "plum" => 6, "date" => 7, "lime" => 8, "yam" => 10)
            @test inventory_report(items) == "apple=5\\ndate=7\\nfig=1\\nkiwi=9\\nlime=8\\nmango=2\\npear=4\\nplum=6\\nyam=10\\nzinc=3"
            println("OK")
            """)
    end,
    prompt = "test_inventory.jl fails (or passes only by luck) because the report order is nondeterministic. Make inventory_report deterministic so the test always passes. Do not modify the test.",
    check = function (dir)
        for _ in 1:5
            _run_ok(dir, `julia --startup-file=no test_inventory.jl`) || return false
        end
        return true
    end,
),

(
    name = "dep-wiring",
    setup = function (dir)
        mkpath(joinpath(dir, "Stamp", "src"))
        write(joinpath(dir, "Stamp", "Project.toml"), """
            name = "Stamp"
            uuid = "7f2b1e60-1f7c-4c2e-9d7b-3a1a2b3c4d5e"
            version = "0.1.0"
            """)
        write(joinpath(dir, "Stamp", "src", "Stamp.jl"), """
            module Stamp
            using Dates
            stamp(msg) = "[\$(Dates.format(Dates.DateTime(2026, 1, 2, 3, 4, 5), "yyyy-mm-dd HH:MM:SS"))] \$msg"
            export stamp
            end
            """)
        write(joinpath(dir, "test_stamp.jl"), """
            using Pkg
            Pkg.activate("Stamp"; io = devnull)
            using Stamp
            using Test
            @test stamp("hello") == "[2026-01-02 03:04:05] hello"
            println("OK")
            """)
    end,
    prompt = "test_stamp.jl fails because the Stamp package doesn't load. Diagnose and fix the package so the test passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_stamp.jl`),
),

(
    name = "api-doc-sync",
    setup = function (dir)
        write(joinpath(dir, "fmt.jl"), """
            \"\"\"
                shorten(s; max = 10, ellipsis = "…")

            Truncate `s` to at most `max` characters. When truncation happens, the
            result ends with `ellipsis` (still within the `max` budget).
            \"\"\"
            shorten(s) = length(s) <= 10 ? s : first(s, 10)

            \"\"\"
                pad_id(n; width = 6)

            Zero-pad an integer id to `width` digits.
            \"\"\"
            pad_id(n) = lpad(n, 6, '0')
            """)
        write(joinpath(dir, "test_fmt.jl"), """
            include("fmt.jl")
            using Test
            @test shorten("hello") == "hello"
            @test shorten("hello world, long"; max = 8) == "hello w…"
            @test shorten("hello world, long") == "hello wor…"
            @test shorten("abcdef"; max = 6, ellipsis = "...") == "abcdef"
            @test shorten("abcdefgh"; max = 6, ellipsis = "...") == "abc..."
            @test pad_id(42) == "000042"
            @test pad_id(42; width = 3) == "042"
            println("OK")
            """)
    end,
    prompt = "The docstrings in fmt.jl promise keyword arguments the functions don't actually accept, and test_fmt.jl exercises the documented behavior. Implement the functions to match their docs so the test passes.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_fmt.jl`),
),

(
    name = "deep-trace",
    setup = function (dir)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "a_entry.jl"), """
            include("b_config.jl")
            include("c_loader.jl")
            include("d_transform.jl")
            include("e_output.jl")
            process(data) = emit(transform(load(data, default_config())))
            """)
        write(joinpath(dir, "src", "b_config.jl"), """
            # scale must default to 1.0 (identity); someone fat-fingered it.
            default_config() = (scale = 0.0, offset = 0)
            """)
        write(joinpath(dir, "src", "c_loader.jl"), """
            load(data, cfg) = [(x, cfg) for x in data]
            """)
        write(joinpath(dir, "src", "d_transform.jl"), """
            transform(rows) = [x * cfg.scale + cfg.offset for (x, cfg) in rows]
            """)
        write(joinpath(dir, "src", "e_output.jl"), """
            emit(xs) = sum(xs) / length(xs)
            """)
        write(joinpath(dir, "test_pipeline.jl"), """
            include("src/a_entry.jl")
            using Test
            @test process([1, 2, 3]) == 2.0
            @test process([10]) == 10.0
            println("OK")
            """)
    end,
    prompt = "test_pipeline.jl fails: process returns the wrong values. Track the bug through the pipeline in src/ and fix it. Do not modify the test.",
    check = dir -> _run_ok(dir, `julia --startup-file=no test_pipeline.jl`),
),

(
    name = "big-file-precision",
    setup = function (dir)
        chunks = String[]
        for i in 1:100
            push!(chunks, """
                # Validator $(i): checks range [$(i), $(i + 100)].
                function validate_$(i)(x)
                    x < $(i) && return false
                    x > $(i + 100) && return false
                    return true
                end
                """)
        end
        write(joinpath(dir, "validators.jl"), join(chunks, "\n"))
        write(joinpath(dir, "test_validators.jl"), """
            include("validators.jl")
            using Test
            # validator 57 must now accept exactly [57, 250]
            @test validate_57(57) && validate_57(250) && !validate_57(251) && !validate_57(56)
            # spot-check that neighbours are untouched
            @test validate_56(156) && !validate_56(157)
            @test validate_58(158) && !validate_58(159)
            println("OK")
            """)
    end,
    prompt = "In validators.jl (100 near-identical validators), widen validate_57's upper bound from 157 to 250 (and its comment) without touching any other validator, so test_validators.jl passes.",
    check = function (dir)
        content = read(joinpath(dir, "validators.jl"), String)
        count("x > 250 && return false", content) == 1 || return false
        occursin("x > 157", content) && return false
        return _run_ok(dir, `julia --startup-file=no test_validators.jl`)
    end,
),

]
