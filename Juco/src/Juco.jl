"""
Juco.jl - A coding assistant app built on top of Agentif and LLMTools

This package provides a ready-to-use coding assistant agent with predefined
tools for common coding tasks like reading, writing, and editing files,
running shell commands, and more.
"""
module Juco

using Agentif
using LLMTools

# Include coding assistant functionality
# For now, this is a minimal scaffold - you can expand with your specific coding assistant code
include("coding_assistant.jl")

# Exports
export coding_agent, default_coding_prompt

end
