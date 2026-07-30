# subprocess_env_test.jl — subprocess environment scrubbing (hardening §2.4)
#
# The attack: a prompt injection gets the model to run `echo $ANTHROPIC_API_KEY` (or
# `env`, or `remote_eval(w, :(ENV))`) in a PTY/worker/codex child, and the key comes
# straight back as tool output. Children now receive an allowlist, not the parent's
# environment.

using Test
using LLMTools

const SECRET_VARS = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CLAW_AGENT_API_KEY",
    "GITHUB_WEBHOOK_SECRET", "MSTEAMS_APP_PASSWORD", "JMAP_API_TOKEN"]
const SENTINEL = "sk-sentinel-a1b2c3-do-not-leak"

function with_secrets(f)
    saved = Dict{String, Union{Nothing, String}}(v => get(ENV, v, nothing) for v in SECRET_VARS)
    try
        for v in SECRET_VARS
            ENV[v] = SENTINEL * "-" * lowercase(v)
        end
        return f()
    finally
        for (v, old) in saved
            old === nothing ? Base.delete!(ENV, v) : (ENV[v] = old)
        end
    end
end

@testset "subprocess environment scrubbing" begin

    @testset "the allowlist excludes credentials and keeps the basics" begin
        with_secrets() do
            env = LLMTools.subprocess_env()
            for v in SECRET_VARS
                @test !haskey(env, v)
            end
            @test !any(v -> occursin(SENTINEL, v), values(env))
            # Enough to actually run something.
            haskey(ENV, "PATH") && @test env["PATH"] == ENV["PATH"]
            haskey(ENV, "HOME") && @test env["HOME"] == ENV["HOME"]
        end
    end

    @testset "the operator can opt a variable back in" begin
        with_secrets() do
            # Programmatic allowlist.
            previous = copy(LLMTools.SUBPROCESS_ENV_EXTRA[])
            try
                LLMTools.set_subprocess_env_allowlist!(["GITHUB_WEBHOOK_SECRET"])
                env = LLMTools.subprocess_env()
                @test haskey(env, "GITHUB_WEBHOOK_SECRET")
                @test !haskey(env, "ANTHROPIC_API_KEY")
            finally
                LLMTools.set_subprocess_env_allowlist!(previous)
            end
            # Environment-driven allowlist, so it works without touching code.
            saved = get(ENV, "LLMTOOLS_ENV_ALLOWLIST", nothing)
            try
                ENV["LLMTOOLS_ENV_ALLOWLIST"] = "OPENAI_API_KEY, JMAP_API_TOKEN"
                env = LLMTools.subprocess_env()
                @test haskey(env, "OPENAI_API_KEY")
                @test haskey(env, "JMAP_API_TOKEN")
                @test !haskey(env, "ANTHROPIC_API_KEY")
            finally
                saved === nothing ? Base.delete!(ENV, "LLMTOOLS_ENV_ALLOWLIST") : (ENV["LLMTOOLS_ENV_ALLOWLIST"] = saved)
            end
            # Per-call additions and explicit overrides.
            env = LLMTools.subprocess_env(; extra_allow = ["CLAW_AGENT_API_KEY"],
                overrides = Dict("MY_VAR" => "1"))
            @test haskey(env, "CLAW_AGENT_API_KEY")
            @test env["MY_VAR"] == "1"
            @test !haskey(env, "ANTHROPIC_API_KEY")
        end
    end

    @testset "worker env keeps what a Julia process needs and nothing else" begin
        with_secrets() do
            env = LLMTools._worker_env()
            # Blanked rather than absent: `Worker` merges with `addenv`, so a denied
            # name has to be shadowed with "" to actually be gone in the child.
            for v in SECRET_VARS
                @test get(env, v, "") == ""
            end
            @test !any(v -> occursin(SENTINEL, v), values(env))
            @test haskey(env, "JULIA_PROJECT")     # set explicitly from ACTIVE_PROJECT
            haskey(ENV, "PATH") && @test env["PATH"] == ENV["PATH"]
        end
    end

    if !Sys.iswindows()
        @testset "a PTY subprocess cannot read ANTHROPIC_API_KEY" begin
            with_secrets() do
                tools = Dict(t.name => t.func for t in LLMTools.create_terminal_tools(pwd()))
                exec_command = tools["exec_command"]
                # `bash -l` re-sources the user's profile, which on a developer
                # machine may itself export a real key; the sentinel is what proves
                # inheritance from *this* process was cut.
                out = exec_command("echo \"KEY=[\$ANTHROPIC_API_KEY]\"; echo \"CLAW=[\$CLAW_AGENT_API_KEY]\"",
                    nothing, nothing, 4000, nothing, nothing)
                @test !occursin(SENTINEL, out)
                @test occursin("KEY=[", out)       # the command really ran
            end
        end

        @testset "a Julia worker cannot read ANTHROPIC_API_KEY" begin
            with_secrets() do
                tools = Dict(t.name => t.func for t in LLMTools.create_worker_tools())
                exec_code = tools["exec_code"]
                out = exec_code("get(ENV, \"ANTHROPIC_API_KEY\", \"<absent>\")", 180)
                @test !occursin(SENTINEL, out)
                @test occursin("<absent>", out)
            end
        end
    end

    @testset "the login-shell flag is honored" begin
        saved = get(ENV, "LLMTOOLS_SUBPROCESS_LOGIN_SHELL", nothing)
        try
            ENV["LLMTOOLS_SUBPROCESS_LOGIN_SHELL"] = "1"
            @test "-l" in LLMTools.subprocess_shell_command("bash", "echo hi").exec
            ENV["LLMTOOLS_SUBPROCESS_LOGIN_SHELL"] = "0"
            @test !("-l" in LLMTools.subprocess_shell_command("bash", "echo hi").exec)
        finally
            saved === nothing ? Base.delete!(ENV, "LLMTOOLS_SUBPROCESS_LOGIN_SHELL") :
                (ENV["LLMTOOLS_SUBPROCESS_LOGIN_SHELL"] = saved)
        end
    end
end
