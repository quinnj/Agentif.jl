"""
    CODING_ASSISTANT_PROMPT

Default system prompt for the Juco coding assistant.
"""
const CODING_ASSISTANT_PROMPT = """
You are Juco, a helpful coding assistant. You have access to various tools for:
- Reading and writing files
- Searching code with grep
- Listing directory contents
- Running shell commands
- Web search and fetching

When helping users:
1. Always explore the codebase first to understand the structure
2. Make minimal, focused changes
3. Explain what you're doing and why
4. Ask for clarification if the request is ambiguous
"""

"""
    default_coding_prompt() -> String

Return the default coding assistant prompt.
"""
function default_coding_prompt()
    return CODING_ASSISTANT_PROMPT
end

"""
    coding_agent(base_dir::String = pwd(); 
                 model = nothing,
                 apikey::String = "",
                 prompt::String = CODING_ASSISTANT_PROMPT,
                 kwargs...) -> Agent

Create a coding assistant agent with the standard set of coding tools.

# Arguments
- `base_dir`: Base directory for file operations (defaults to current working directory)
- `model`: Model to use (defaults to getting from environment or first available)
- `apikey`: API key for the model provider
- `prompt`: System prompt for the agent
- `kwargs`: Additional keyword arguments passed to `Agent`

# Returns
An `Agent` configured with coding tools.
"""
function coding_agent(base_dir::String = pwd();
    model = nothing,
    apikey::String = "",
    prompt::String = CODING_ASSISTANT_PROMPT,
    kwargs...
)
    # Get default model if not provided
    if model === nothing
        # Try to get from environment or use a default
        providers = Agentif.getProviders()
        isempty(providers) && error("No models available. Please configure LLMProviders.")
        
        # Try to find a good default model
        models = Agentif.getModels(first(providers))
        isempty(models) && error("No models found for provider $(first(providers))")
        model = first(models)
    end

    # Create tools
    tools = LLMTools.coding_tools(base_dir)

    # Create agent
    return Agentif.Agent(
        ; prompt = prompt,
        model = model,
        apikey = apikey,
        tools = tools,
        kwargs...
    )
end
