"""
Juco — an uber-minimal pure-Julia coding agent built on Agentif.

Three coding tools (bash, read, edit — where edit also creates files) plus one
memory tool (remember). A single SQLite file persists both session history and
memories; memories are auto-injected into the system prompt each session.

Usage:
    Juco.main()                      # CLI (see juco --help)
    Juco.repl()                      # interactive session
    Juco.evaluate("fix the bug")     # one programmatic turn
"""
module Juco

using Dates
using JSON
using Markdown
using REPL.TerminalMenus
using Agentif
using LLMTools
using LLMProviders
using LLMOAuth
using SQLite
using LocalSearch

include("db.jl")
include("tools.jl")
include("prompt.jl")
include("skills.jl")
include("display.jl")
include("modes.jl")
include("agent.jl")

export repl

end
