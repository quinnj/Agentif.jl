module OpenAIResponses

using StructUtils, JSON, JSONSchema

import ..Model

schema(::Type{T}) where {T} = JSONSchema.schema(T; all_fields_required = true, additionalProperties = false)

@omit_null @kwarg struct InputTextContent
    type::String = "input_text"
    text::String
end

@omit_null @kwarg struct InputImageContent
    type::String = "input_image"
    detail::String = "auto" # high, low, auto
    image_url::Union{Nothing, String} = nothing
    file_id::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct InputFileContent
    type::String = "input_file"
    file_data::Union{Nothing, String} = nothing
    file_id::Union{Nothing, String} = nothing
    file_url::Union{Nothing, String} = nothing
    filename::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct InputAudio
    data::String # base64-encoded audio data
    format::String # mp3, wav
end

@omit_null @kwarg struct InputAudioContent
    type::String = "input_audio"
    input_audio::InputAudio
end

const InputContent = Union{InputTextContent, InputImageContent, InputFileContent, InputAudioContent}

@omit_null @kwarg struct OutputTextContent
    type::String = "output_text"
    text::String
    annotations::Vector{Any} = []
    logprobs::Union{Nothing, Vector{Any}} = nothing
end

@omit_null @kwarg struct Refusal
    refusal::String
    type::String = "refusal"
end

@omit_null @kwarg struct ReasoningText
    text::Union{Nothing, String} = nothing
    type::String = "reasoning_text"
end

const OutputContent = Union{OutputTextContent, Refusal, ReasoningText}

JSON.@choosetype OutputContent x -> begin
    type = x.type[]
    if type == "output_text"
        return OutputTextContent
    elseif type == "refusal"
        return Refusal
    elseif type == "reasoning_text"
        return ReasoningText
    else
        return error("Invalid output content type: $type")
    end
end

const Content = Union{InputContent, OutputContent}

JSON.@choosetype Content x -> begin
    type = x.type[]
    if type == "input_text"
        return InputTextContent
    elseif type == "input_image"
        return InputImageContent
    elseif type == "input_file"
        return InputFileContent
    elseif type == "input_audio"
        return InputAudioContent
    elseif type == "output_text"
        return OutputTextContent
    elseif type == "refusal"
        return Refusal
    elseif type == "reasoning_text"
        return ReasoningText
    else
        return error("Invalid content type: $type")
    end
end

@omit_null @kwarg struct Message
    id::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # in_progress, completed, incomplete
    content::Union{String, Vector{Content}} & (json = (choosetype = x -> x[] isa String ? String : Vector{Content},),)
    role::String # user, assistant, developer, system
    type::String = "message"
end

@omit_null @kwarg struct FunctionToolCallOutput
    type::String = "function_call_output"
    call_id::String # from FunctionToolCall
    output::Union{String, Vector{InputContent}} & (json = (choosetype = x -> x[] isa String ? String : Vector{InputContent},),)
    id::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # "in_progress", "completed", "incomplete"
end


const Item = Union{Message, FunctionToolCallOutput} # TODO: add other item types here: Function tool call, Function tool call output, etc.

@omit_null @kwarg struct ItemReference
    id::String
    type::String = "item_reference"
end

const InputItem = Union{Message, Item, ItemReference}

@omit_null @kwarg struct Prompt
    id::String
    variables::Union{Nothing, Dict{String, Any}} = nothing
    version::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct Reasoning
    effort::Union{Nothing, String} = nothing # "none", "minimal", "low", "medium", "high", "xhigh"
    summary::Union{Nothing, String} = nothing # "auto", "concise", "detailed"
end


@omit_null @kwarg struct TextFormatText
    type::String = "text"
end

@omit_null @kwarg struct TextFormatJSONSchema{T}
    type::String = "json_schema"
    name::String
    description::Union{Nothing, String} = nothing
    # the JSONSchema.Schema *must* have all fields be required, and additionalProperties: false
    # allOf, not, dependentRequired, dependentSchemas, if, then, else are not supported
    # root schema must be an object
    schema::JSONSchema.Schema{T}
    strict::Union{Nothing, Bool} = nothing
end

@omit_null @kwarg struct TextFormatJSONObject
    type::String = "json_object"
end

const TextFormat = Union{TextFormatText, TextFormatJSONSchema, TextFormatJSONObject}

JSON.@choosetype TextFormat x -> begin
    type = x.type[]
    if type == "text"
        return TextFormatText
    elseif type == "json_schema"
        return TextFormatJSONSchema
    elseif type == "json_object"
        return TextFormatJSONObject
    else
        return Any
    end
end

@omit_null @kwarg struct Text
    format::TextFormat
    verbosity::Union{Nothing, String} = nothing # low, medium, high
end

@omit_null @kwarg struct FunctionTool{T}
    name::String
    strict::Bool = true
    type::String = "function"
    description::Union{Nothing, String} = nothing
    parameters::JSONSchema.Schema{T}
end


@omit_null @kwarg struct WebSearchFilters
    allowed_domains::Union{Nothing, Vector{String}} = nothing
end

@omit_null @kwarg struct WebSearchUserLocation
    type::String = "approximate"
    city::Union{Nothing, String} = nothing
    country::Union{Nothing, String} = nothing
    region::Union{Nothing, String} = nothing
    timezone::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct WebSearchTool
    type::String = "web_search" # also: web_search_2025_08_26
    filters::Union{Nothing, WebSearchFilters} = nothing
    search_context_size::Union{Nothing, String} = nothing # low, medium, high
    user_location::Union{Nothing, WebSearchUserLocation} = nothing
end

@omit_null @kwarg struct WebSearchPreviewTool
    type::String = "web_search_preview" # also: web_search_preview_2025_03_11
    search_context_size::Union{Nothing, String} = nothing # low, medium, high
    user_location::Union{Nothing, WebSearchUserLocation} = nothing
end

@omit_null @kwarg struct FileSearchTool
    type::String = "file_search"
    vector_store_ids::Vector{String}
    filters::Any = nothing
    max_num_results::Union{Nothing, Int} = nothing
    ranking_options::Any = nothing
end

@omit_null @kwarg struct ComputerTool
    display_height::Int
    display_width::Int
    environment::String # windows, mac, linux, ubuntu, browser
    type::String = "computer_use_preview"
end

@omit_null @kwarg struct CodeInterpreterContainerAuto
    type::String = "auto"
    file_ids::Union{Nothing, Vector{String}} = nothing
    memory_limit::Union{Nothing, String} = nothing # 1g, 4g, 16g, 64g
end

@omit_null @kwarg struct CodeInterpreterTool
    container::Union{String, CodeInterpreterContainerAuto} & (json = (choosetype = x -> x[] isa String ? String : CodeInterpreterContainerAuto,),)
    type::String = "code_interpreter"
end

@omit_null @kwarg struct ImageGenerationInputImageMask
    file_id::Union{Nothing, String} = nothing
    image_url::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ImageGenerationTool
    type::String = "image_generation"
    background::Union{Nothing, String} = nothing # transparent, opaque, auto
    input_fidelity::Union{Nothing, String} = nothing # high, low
    input_image_mask::Union{Nothing, ImageGenerationInputImageMask} = nothing
    model::Union{Nothing, String} = nothing # gpt-image-1, gpt-image-1-mini
    moderation::Union{Nothing, String} = nothing # auto, low
    output_compression::Union{Nothing, Int} = nothing
    output_format::Union{Nothing, String} = nothing # png, webp, jpeg
    partial_images::Union{Nothing, Int} = nothing
    quality::Union{Nothing, String} = nothing # low, medium, high, auto
    size::Union{Nothing, String} = nothing # 1024x1024, 1024x1536, 1536x1024, auto
end

@omit_null @kwarg struct LocalShellTool
    type::String = "local_shell"
end

@omit_null @kwarg struct ShellTool
    type::String = "shell"
end

@omit_null @kwarg struct ApplyPatchTool
    type::String = "apply_patch"
end

@omit_null @kwarg struct MCPTool
    server_label::String
    type::String = "mcp"
    allowed_tools::Any = nothing
    authorization::Union{Nothing, String} = nothing
    connector_id::Union{Nothing, String} = nothing
    headers::Union{Nothing, Dict{String, String}} = nothing
    require_approval::Any = nothing
    server_description::Union{Nothing, String} = nothing
    server_url::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct CustomToolInputFormatText
    type::String = "text"
end

@omit_null @kwarg struct CustomToolInputFormatGrammar
    definition::String
    syntax::String # lark, regex
    type::String = "grammar"
end

const CustomToolInputFormat = Union{CustomToolInputFormatText, CustomToolInputFormatGrammar}

JSON.@choosetype CustomToolInputFormat x -> begin
    type = x.type[]
    if type == "text"
        return CustomToolInputFormatText
    elseif type == "grammar"
        return CustomToolInputFormatGrammar
    else
        return Any
    end
end

@omit_null @kwarg struct CustomTool
    name::String
    type::String = "custom"
    description::Union{Nothing, String} = nothing
    format::Union{Nothing, CustomToolInputFormat} = nothing
end

const Tool = Union{
    FunctionTool,
    FileSearchTool,
    ComputerTool,
    WebSearchTool,
    WebSearchPreviewTool,
    MCPTool,
    CodeInterpreterTool,
    ImageGenerationTool,
    LocalShellTool,
    ShellTool,
    ApplyPatchTool,
    CustomTool,
}

# this struct is meant to *exactly* match the OpenAI API reference:
# https://platform.openai.com/docs/api-reference/responses/create
@omit_null @kwarg struct Request
    background::Union{Nothing, Bool} = nothing
    conversation::Union{Nothing, String, @NamedTuple{id::String}} = nothing
    include::Union{Nothing, Vector{String}} = nothing
    input::Union{Nothing, String, Vector{InputItem}} = nothing
    instructions::Union{Nothing, String} = nothing # for stateful, instructions from previous response will be used if not provided
    max_output_tokens::Union{Nothing, Int} = nothing
    max_tool_calls::Union{Nothing, Int} = nothing
    model::String
    parallel_tool_calls::Union{Nothing, Bool} = nothing
    previous_response_id::Union{Nothing, String} = nothing
    prompt::Union{Nothing, Prompt} = nothing
    prompt_cache_key::Union{Nothing, String} = nothing
    prompt_cache_retention::Union{Nothing, String} = nothing
    reasoning::Union{Nothing, Reasoning} = nothing
    safety_identifier::Union{Nothing, String} = nothing
    service_tier::Union{Nothing, String} = nothing
    store::Union{Nothing, Bool} = nothing
    stream::Union{Nothing, Bool} = nothing
    stream_options::Union{Nothing, @NamedTuple{include_obfuscation::Union{Nothing, Bool}}} = nothing
    temperature::Union{Nothing, Float64} = nothing
    text::Union{Nothing, Text} = nothing
    tool_choice::Union{Nothing, String} = nothing # "none", "auto", "required"; TODO: can be more specific on tool types to be required
    tools::Union{Nothing, Vector{Tool}} = nothing
    top_logprobs::Union{Nothing, Int} = nothing
    top_p::Union{Nothing, Float64} = nothing
    truncation::Union{Nothing, String} = nothing # "auto", "disabled"
end

@omit_null @kwarg struct Error
    code::Union{Nothing, String} = nothing
    message::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ReasoningSummary
    text::Union{Nothing, String} = nothing
    type::String = "summary_text"
end

@omit_null @kwarg struct ReasoningOutput
    id::Union{Nothing, String} = nothing
    summary::Union{Nothing, Vector{ReasoningSummary}} = nothing
    type::String = "reasoning"
    content::Union{Nothing, Vector{ReasoningText}} = nothing
    encrypted_content::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # completed, in_progress, incomplete
end

@omit_null @kwarg struct FunctionToolCall
    type::String = "function_call"
    arguments::String
    call_id::String
    name::String
    id::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # "in_progress", "completed", "incomplete"
end

@omit_null @kwarg struct WebSearchCallActionSearchSource
    type::String = "url"
    url::String
end

@omit_null @kwarg struct WebSearchCallActionSearch
    query::String
    type::String = "search"
    sources::Union{Nothing, Vector{WebSearchCallActionSearchSource}} = nothing
end

@omit_null @kwarg struct WebSearchCallActionOpenPage
    type::String = "open_page"
    url::String
end

@omit_null @kwarg struct WebSearchCallActionFind
    pattern::String
    type::String = "find"
    url::String
end

const WebSearchCallAction = Union{WebSearchCallActionSearch, WebSearchCallActionOpenPage, WebSearchCallActionFind}

JSON.@choosetype WebSearchCallAction x -> begin
    type = x.type[]
    if type == "search"
        return WebSearchCallActionSearch
    elseif type == "open_page"
        return WebSearchCallActionOpenPage
    elseif type == "find"
        return WebSearchCallActionFind
    else
        return Any
    end
end

@omit_null @kwarg struct WebSearchCall
    id::String
    action::WebSearchCallAction
    status::String # in_progress, searching, completed, failed
    type::String = "web_search_call"
end

@omit_null @kwarg struct FileSearchResult
    attributes::Any = nothing
    file_id::Union{Nothing, String} = nothing
    filename::Union{Nothing, String} = nothing
    score::Union{Nothing, Float64} = nothing
    text::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct FileSearchCall
    id::String
    queries::Vector{String}
    status::String # in_progress, searching, completed, incomplete, failed
    type::String = "file_search_call"
    results::Union{Nothing, Vector{FileSearchResult}} = nothing
end

@omit_null @kwarg struct ComputerActionClick
    button::String # left, right, wheel, back, forward
    type::String = "click"
    x::Int
    y::Int
end

@omit_null @kwarg struct ComputerActionDoubleClick
    type::String = "double_click"
    x::Int
    y::Int
end

@omit_null @kwarg struct ComputerActionDragPath
    x::Int
    y::Int
end

@omit_null @kwarg struct ComputerActionDrag
    path::Vector{ComputerActionDragPath}
    type::String = "drag"
end

@omit_null @kwarg struct ComputerActionKeypress
    keys::Vector{String}
    type::String = "keypress"
end

@omit_null @kwarg struct ComputerActionMove
    type::String = "move"
    x::Int
    y::Int
end

@omit_null @kwarg struct ComputerActionScreenshot
    type::String = "screenshot"
end

@omit_null @kwarg struct ComputerActionScroll
    scroll_x::Int
    scroll_y::Int
    type::String = "scroll"
    x::Int
    y::Int
end

@omit_null @kwarg struct ComputerActionType
    text::String
    type::String = "type"
end

@omit_null @kwarg struct ComputerActionWait
    type::String = "wait"
end

const ComputerAction = Union{
    ComputerActionClick,
    ComputerActionDoubleClick,
    ComputerActionDrag,
    ComputerActionKeypress,
    ComputerActionMove,
    ComputerActionScreenshot,
    ComputerActionScroll,
    ComputerActionType,
    ComputerActionWait,
}

JSON.@choosetype ComputerAction x -> begin
    type = x.type[]
    if type == "click"
        return ComputerActionClick
    elseif type == "double_click"
        return ComputerActionDoubleClick
    elseif type == "drag"
        return ComputerActionDrag
    elseif type == "keypress"
        return ComputerActionKeypress
    elseif type == "move"
        return ComputerActionMove
    elseif type == "screenshot"
        return ComputerActionScreenshot
    elseif type == "scroll"
        return ComputerActionScroll
    elseif type == "type"
        return ComputerActionType
    elseif type == "wait"
        return ComputerActionWait
    else
        return Any
    end
end

@omit_null @kwarg struct PendingSafetyCheck
    id::String
    code::Union{Nothing, String} = nothing
    message::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ComputerCall
    id::String
    action::ComputerAction
    call_id::String
    pending_safety_checks::Vector{PendingSafetyCheck} = []
    status::String # in_progress, completed, incomplete
    type::String = "computer_call"
end

@omit_null @kwarg struct CodeInterpreterOutputLogs
    logs::String
    type::String = "logs"
end

@omit_null @kwarg struct CodeInterpreterOutputImage
    type::String = "image"
    url::String
end

const CodeInterpreterOutput = Union{CodeInterpreterOutputLogs, CodeInterpreterOutputImage}

JSON.@choosetype CodeInterpreterOutput x -> begin
    type = x.type[]
    if type == "logs"
        return CodeInterpreterOutputLogs
    elseif type == "image"
        return CodeInterpreterOutputImage
    else
        return Any
    end
end

@omit_null @kwarg struct CodeInterpreterCall
    id::String
    code::Union{Nothing, String} = nothing
    container_id::String
    outputs::Union{Nothing, Vector{CodeInterpreterOutput}} = nothing
    status::String # in_progress, completed, incomplete, interpreting, failed
    type::String = "code_interpreter_call"
end

@omit_null @kwarg struct ShellCallAction
    commands::Vector{String}
    max_output_length::Union{Nothing, Int} = nothing
    timeout_ms::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct ShellCall
    id::String
    action::ShellCallAction
    call_id::String
    status::String # in_progress, completed, incomplete
    type::String = "shell_call"
    created_by::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ShellCallOutputOutcomeTimeout
    type::String = "timeout"
end

@omit_null @kwarg struct ShellCallOutputOutcomeExit
    exit_code::Int
    type::String = "exit"
end

const ShellCallOutputOutcome = Union{ShellCallOutputOutcomeTimeout, ShellCallOutputOutcomeExit}

JSON.@choosetype ShellCallOutputOutcome x -> begin
    type = x.type[]
    if type == "timeout"
        return ShellCallOutputOutcomeTimeout
    elseif type == "exit"
        return ShellCallOutputOutcomeExit
    else
        return Any
    end
end

@omit_null @kwarg struct ShellCallOutputContent
    outcome::ShellCallOutputOutcome
    stderr::String
    stdout::String
    created_by::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ShellCallOutput
    id::String
    call_id::String
    max_output_length::Union{Nothing, Int} = nothing
    output::Vector{ShellCallOutputContent}
    type::String = "shell_call_output"
    created_by::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ApplyPatchOperationCreateFile
    diff::String
    path::String
    type::String = "create_file"
end

@omit_null @kwarg struct ApplyPatchOperationDeleteFile
    path::String
    type::String = "delete_file"
end

@omit_null @kwarg struct ApplyPatchOperationUpdateFile
    diff::String
    path::String
    type::String = "update_file"
end

const ApplyPatchOperation = Union{ApplyPatchOperationCreateFile, ApplyPatchOperationDeleteFile, ApplyPatchOperationUpdateFile}

JSON.@choosetype ApplyPatchOperation x -> begin
    type = x.type[]
    if type == "create_file"
        return ApplyPatchOperationCreateFile
    elseif type == "delete_file"
        return ApplyPatchOperationDeleteFile
    elseif type == "update_file"
        return ApplyPatchOperationUpdateFile
    else
        return Any
    end
end

@omit_null @kwarg struct ApplyPatchCall
    id::String
    call_id::String
    operation::ApplyPatchOperation
    status::String # in_progress, completed
    type::String = "apply_patch_call"
    created_by::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ApplyPatchCallOutput
    id::String
    call_id::String
    status::String # completed, failed
    type::String = "apply_patch_call_output"
    created_by::Union{Nothing, String} = nothing
    output::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ImageGenerationCall
    id::String
    result::Union{Nothing, String} = nothing
    status::String # in_progress, completed, generating, failed
    type::String = "image_generation_call"
end

@omit_null @kwarg struct LocalShellCallAction
    command::Vector{String}
    env::Dict{String, String}
    type::String = "exec"
    timeout_ms::Union{Nothing, Int} = nothing
    user::Union{Nothing, String} = nothing
    working_directory::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct LocalShellCall
    id::String
    action::LocalShellCallAction
    call_id::String
    status::String # in_progress, completed, incomplete
    type::String = "local_shell_call"
end

@omit_null @kwarg struct McpListToolsTool
    input_schema::Any
    name::String
    annotations::Any = nothing
    description::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct McpListTools
    id::String
    server_label::String
    tools::Vector{McpListToolsTool}
    type::String = "mcp_list_tools"
    error::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct McpApprovalRequest
    id::String
    arguments::String
    name::String
    server_label::String
    type::String = "mcp_approval_request"
end

@omit_null @kwarg struct McpCall
    id::String
    arguments::String
    name::String
    server_label::String
    type::String = "mcp_call"
    approval_request_id::Union{Nothing, String} = nothing
    error::Union{Nothing, String} = nothing
    output::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # in_progress, completed, incomplete, calling, failed
end

@omit_null @kwarg struct CompactionItem
    id::String
    encrypted_content::String
    type::String = "compaction"
    created_by::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct CustomToolCall
    call_id::String
    input::String
    name::String
    type::String = "custom_tool_call"
    id::Union{Nothing, String} = nothing
end

const Output = Union{
    Message,
    ReasoningOutput,
    FunctionToolCall,
    WebSearchCall,
    FileSearchCall,
    ComputerCall,
    CodeInterpreterCall,
    ShellCall,
    ShellCallOutput,
    ApplyPatchCall,
    ApplyPatchCallOutput,
    ImageGenerationCall,
    LocalShellCall,
    McpCall,
    McpListTools,
    McpApprovalRequest,
    CompactionItem,
    CustomToolCall,
} # TODO: add other output types here as needed

JSON.@choosetype Output x -> begin
    type = x.type[]
    if type == "message"
        return Message
    elseif type == "reasoning"
        return ReasoningOutput
    elseif type == "function_call"
        return FunctionToolCall
    elseif type == "web_search_call"
        return WebSearchCall
    elseif type == "file_search_call"
        return FileSearchCall
    elseif type == "computer_call"
        return ComputerCall
    elseif type == "code_interpreter_call"
        return CodeInterpreterCall
    elseif type == "shell_call"
        return ShellCall
    elseif type == "shell_call_output"
        return ShellCallOutput
    elseif type == "apply_patch_call"
        return ApplyPatchCall
    elseif type == "apply_patch_call_output"
        return ApplyPatchCallOutput
    elseif type == "image_generation_call"
        return ImageGenerationCall
    elseif type == "local_shell_call"
        return LocalShellCall
    elseif type == "mcp_call"
        return McpCall
    elseif type == "mcp_list_tools"
        return McpListTools
    elseif type == "mcp_approval_request"
        return McpApprovalRequest
    elseif type == "compaction"
        return CompactionItem
    elseif type == "custom_tool_call"
        return CustomToolCall
    else
        return error("Invalid output type: $type")
    end
end

@omit_null @kwarg struct Usage
    input_tokens::Union{Nothing, Int} = nothing
    input_tokens_details::Union{Nothing, @NamedTuple{cached_tokens::Union{Nothing, Int}}} = nothing
    output_tokens::Union{Nothing, Int} = nothing
    output_tokens_details::Union{Nothing, @NamedTuple{reasoning_tokens::Union{Nothing, Int}}} = nothing
    total_tokens::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct Response
    background::Union{Nothing, Bool} = nothing
    conversation::Union{Nothing, @NamedTuple{id::String}} = nothing
    created_at::Union{Nothing, Float64} = nothing
    error::Union{Nothing, Error} = nothing
    id::String
    incomplete_details::Union{Nothing, @NamedTuple{reason::Union{Nothing, String}}} = nothing
    # instructions::Union{Nothing,String} = nothing
    max_output_tokens::Union{Nothing, Int} = nothing
    max_tool_calls::Union{Nothing, Int} = nothing
    model::String
    output::Union{Nothing, Vector{Output}} = nothing
    output_text::Union{Nothing, String} = nothing
    parallel_tool_calls::Union{Nothing, Bool} = nothing
    previous_response_id::Union{Nothing, String} = nothing
    prompt::Union{Nothing, Prompt} = nothing
    prompt_cache_key::Union{Nothing, String} = nothing
    prompt_cache_retention::Union{Nothing, String} = nothing
    reasoning::Union{Nothing, Reasoning} = nothing
    safety_identifier::Union{Nothing, String} = nothing
    service_tier::Union{Nothing, String} = nothing
    status::Union{Nothing, String} = nothing # completed, failed, in_progress, cancelled, queued, incomplete
    temperature::Union{Nothing, Float64} = nothing
    # text::Union{Nothing,Text} = nothing
    # tool_choice::Union{Nothing,ToolChoice} = nothing
    # tools::Union{Nothing,Vector{Tool}} = nothing
    top_logprobs::Union{Nothing, Int} = nothing
    top_p::Union{Nothing, Float64} = nothing
    truncation::Union{Nothing, String} = nothing # "auto", "disabled"
    usage::Union{Nothing, Usage} = nothing
end

abstract type StreamEvent end
abstract type StreamDeltaEvent <: StreamEvent end
abstract type StreamDoneEvent <: StreamEvent end
abstract type StreamOutputDoneEvent <: StreamEvent end

@omit_null @kwarg struct StreamResponseCreatedEvent <: StreamEvent
    type::String = "response.created"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct StreamResponseInProgressEvent <: StreamEvent
    type::String = "response.in_progress"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

@omit_null @kwarg struct StreamResponseCompletedEvent <: StreamDoneEvent
    type::String = "response.completed"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

# failed
@omit_null @kwarg struct StreamResponseFailedEvent <: StreamDoneEvent
    type::String = "response.failed"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

# incomplete
@omit_null @kwarg struct StreamResponseIncompleteEvent <: StreamDoneEvent
    type::String = "response.incomplete"
    response::Response
    sequence_number::Union{Nothing, Int} = nothing
end

# output_item.added
@omit_null @kwarg struct StreamOutputItemAddedEvent <: StreamEvent
    type::String = "response.output_item.added"
    sequence_number::Union{Nothing, Int} = nothing
    output_index::Union{Nothing, Int} = nothing
    item::Output
end

# output_item.done
@omit_null @kwarg struct StreamOutputItemDoneEvent <: StreamEvent
    type::String = "response.output_item.done"
    sequence_number::Union{Nothing, Int} = nothing
    output_index::Union{Nothing, Int} = nothing
    item::Output
end

# content_part.added
@omit_null @kwarg struct StreamContentPartAddedEvent <: StreamEvent
    type::String = "response.content_part.added"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    part::OutputContent
end

# content_part.done
@omit_null @kwarg struct StreamContentPartDoneEvent <: StreamEvent
    type::String = "response.content_part.done"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    part::OutputContent
end

# output_text.delta
@omit_null @kwarg struct StreamOutputTextDeltaEvent <: StreamDeltaEvent
    type::String = "response.output_text.delta"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    logprobs::Vector{Any} = []
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# output_text.done
@omit_null @kwarg struct StreamOutputTextDoneEvent <: StreamOutputDoneEvent
    type::String = "response.output_text.done"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    logprobs::Vector{Any} = []
    output_index::Union{Nothing, Int} = nothing
    text::String
end

# refusal.delta
@omit_null @kwarg struct StreamRefusalDeltaEvent <: StreamDeltaEvent
    type::String = "response.refusal.delta"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# refusal.done
@omit_null @kwarg struct StreamRefusalDoneEvent <: StreamOutputDoneEvent
    type::String = "response.refusal.done"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    refusal::String
end

# output_text.annotation.added
@omit_null @kwarg struct StreamOutputTextAnnotationAddedEvent <: StreamEvent
    type::String = "response.output_text.annotation.added"
    sequence_number::Union{Nothing, Int} = nothing
    annotation::Any = nothing
    annotation_index::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.reasoning_summary_part.added
@omit_null @kwarg struct StreamReasoningSummaryPartAddedEvent <: StreamEvent
    type::String = "response.reasoning_summary_part.added"
    sequence_number::Union{Nothing, Int} = nothing
    summary_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    part::ReasoningSummary
end

# response.reasoning_summary_part.done
@omit_null @kwarg struct StreamReasoningSummaryPartDoneEvent <: StreamEvent
    type::String = "response.reasoning_summary_part.done"
    sequence_number::Union{Nothing, Int} = nothing
    summary_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    part::ReasoningSummary
end

# response.reasoning_summary_text.delta
@omit_null @kwarg struct StreamReasoningSummaryTextDeltaEvent <: StreamDeltaEvent
    type::String = "response.reasoning_summary_text.delta"
    sequence_number::Union{Nothing, Int} = nothing
    summary_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.reasoning_summary_text.done
@omit_null @kwarg struct StreamReasoningSummaryTextDoneEvent <: StreamOutputDoneEvent
    type::String = "response.reasoning_summary_text.done"
    sequence_number::Union{Nothing, Int} = nothing
    summary_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    text::String
end

# response.reasoning_text.delta
@omit_null @kwarg struct StreamReasoningTextDeltaEvent <: StreamDeltaEvent
    type::String = "response.reasoning_text.delta"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.reasoning_text.done
@omit_null @kwarg struct StreamReasoningTextDoneEvent <: StreamOutputDoneEvent
    type::String = "response.reasoning_text.done"
    sequence_number::Union{Nothing, Int} = nothing
    content_index::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    text::String
end

# response.function_call_arguments.delta
@omit_null @kwarg struct StreamFunctionCallArgumentsDeltaEvent <: StreamDeltaEvent
    type::String = "response.function_call_arguments.delta"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.function_call_arguments.done
@omit_null @kwarg struct StreamFunctionCallArgumentsDoneEvent <: StreamOutputDoneEvent
    type::String = "response.function_call_arguments.done"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    name::Union{Nothing, String} = nothing
    arguments::String
end

# response.mcp_call.completed
@omit_null @kwarg struct StreamMCPCallCompletedEvent <: StreamEvent
    type::String = "response.mcp_call.completed"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.mcp_call.failed
@omit_null @kwarg struct StreamMCPCallFailedEvent <: StreamEvent
    type::String = "response.mcp_call.failed"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.mcp_call.in_progress
@omit_null @kwarg struct StreamMCPCallInProgressEvent <: StreamEvent
    type::String = "response.mcp_call.in_progress"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.mcp_list_tools.in_progress
@omit_null @kwarg struct StreamMCPListToolsInProgressEvent <: StreamEvent
    type::String = "response.mcp_list_tools.in_progress"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.mcp_list_tools.completed
@omit_null @kwarg struct StreamMCPListToolsCompletedEvent <: StreamEvent
    type::String = "response.mcp_list_tools.completed"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.mcp_list_tools.failed
@omit_null @kwarg struct StreamMCPListToolsFailedEvent <: StreamEvent
    type::String = "response.mcp_list_tools.failed"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.mcp_call_arguments.delta
@omit_null @kwarg struct StreamMCPCallArgumentsDeltaEvent <: StreamDeltaEvent
    type::String = "response.mcp_call_arguments.delta"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.mcp_call_arguments.done
@omit_null @kwarg struct StreamMCPCallArgumentsDoneEvent <: StreamOutputDoneEvent
    type::String = "response.mcp_call_arguments.done"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    arguments::String
end

# response.web_search_call.searching
@omit_null @kwarg struct StreamWebSearchCallSearchingEvent <: StreamEvent
    type::String = "response.web_search_call.searching"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.web_search_call.in_progress
@omit_null @kwarg struct StreamWebSearchCallInProgressEvent <: StreamEvent
    type::String = "response.web_search_call.in_progress"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.web_search_call.completed
@omit_null @kwarg struct StreamWebSearchCallCompletedEvent <: StreamEvent
    type::String = "response.web_search_call.completed"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.file_search_call.searching
@omit_null @kwarg struct StreamFileSearchCallSearchingEvent <: StreamEvent
    type::String = "response.file_search_call.searching"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.file_search_call.in_progress
@omit_null @kwarg struct StreamFileSearchCallInProgressEvent <: StreamEvent
    type::String = "response.file_search_call.in_progress"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.file_search_call.completed
@omit_null @kwarg struct StreamFileSearchCallCompletedEvent <: StreamEvent
    type::String = "response.file_search_call.completed"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.code_interpreter_call.in_progress
@omit_null @kwarg struct StreamCodeInterpreterCallInProgressEvent <: StreamEvent
    type::String = "response.code_interpreter_call.in_progress"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.code_interpreter_call.interpreting
@omit_null @kwarg struct StreamCodeInterpreterCallInterpretingEvent <: StreamEvent
    type::String = "response.code_interpreter_call.interpreting"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.code_interpreter_call.completed
@omit_null @kwarg struct StreamCodeInterpreterCallCompletedEvent <: StreamEvent
    type::String = "response.code_interpreter_call.completed"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.code_interpreter_call_code.delta
@omit_null @kwarg struct StreamCodeInterpreterCallCodeDeltaEvent <: StreamDeltaEvent
    type::String = "response.code_interpreter_call_code.delta"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.code_interpreter_call_code.done
@omit_null @kwarg struct StreamCodeInterpreterCallCodeDoneEvent <: StreamOutputDoneEvent
    type::String = "response.code_interpreter_call_code.done"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    code::String
end

# response.image_generation_call.in_progress
@omit_null @kwarg struct StreamImageGenerationCallInProgressEvent <: StreamEvent
    type::String = "response.image_generation_call.in_progress"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.image_generation_call.generating
@omit_null @kwarg struct StreamImageGenerationCallGeneratingEvent <: StreamEvent
    type::String = "response.image_generation_call.generating"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.image_generation_call.partial_image
@omit_null @kwarg struct StreamImageGenerationCallPartialImageEvent <: StreamEvent
    type::String = "response.image_generation_call.partial_image"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    partial_image_b64::String
    partial_image_index::Int
end

# response.image_generation_call.completed
@omit_null @kwarg struct StreamImageGenerationCallCompletedEvent <: StreamEvent
    type::String = "response.image_generation_call.completed"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
end

# response.audio.delta
@omit_null @kwarg struct StreamAudioDeltaEvent <: StreamDeltaEvent
    type::String = "response.audio.delta"
    sequence_number::Union{Nothing, Int} = nothing
    delta::String
end

# response.audio.done
@omit_null @kwarg struct StreamAudioDoneEvent <: StreamOutputDoneEvent
    type::String = "response.audio.done"
    sequence_number::Union{Nothing, Int} = nothing
end

# response.audio.transcript.delta
@omit_null @kwarg struct StreamAudioTranscriptDeltaEvent <: StreamDeltaEvent
    type::String = "response.audio.transcript.delta"
    sequence_number::Union{Nothing, Int} = nothing
    delta::String
end

# response.audio.transcript.done
@omit_null @kwarg struct StreamAudioTranscriptDoneEvent <: StreamOutputDoneEvent
    type::String = "response.audio.transcript.done"
    sequence_number::Union{Nothing, Int} = nothing
end

# response.custom_tool_call_input.delta
@omit_null @kwarg struct StreamCustomToolCallInputDeltaEvent <: StreamDeltaEvent
    type::String = "response.custom_tool_call_input.delta"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    delta::String
end

# response.custom_tool_call_input.done
@omit_null @kwarg struct StreamCustomToolCallInputDoneEvent <: StreamOutputDoneEvent
    type::String = "response.custom_tool_call_input.done"
    sequence_number::Union{Nothing, Int} = nothing
    item_id::Union{Nothing, String} = nothing
    output_index::Union{Nothing, Int} = nothing
    input::String
end

# repsonse.queued
@omit_null @kwarg struct StreamResponseQueuedEvent <: StreamEvent
    type::String = "response.queued"
    sequence_number::Union{Nothing, Int} = nothing
    response::Response
end

# error
@omit_null @kwarg struct StreamErrorEvent <: StreamEvent
    type::String = "error"
    sequence_number::Union{Nothing, Int} = nothing
    code::Union{Nothing, String} = nothing
    message::String
    param::Union{Nothing, String} = nothing
end

JSON.@choosetype StreamEvent x -> begin
    type = x.type[]
    if type == "response.created"
        return StreamResponseCreatedEvent
    elseif type == "response.in_progress"
        return StreamResponseInProgressEvent
    elseif type == "response.completed"
        return StreamResponseCompletedEvent
    elseif type == "response.failed"
        return StreamResponseFailedEvent
    elseif type == "response.incomplete"
        return StreamResponseIncompleteEvent
    elseif type == "response.output_item.added"
        return StreamOutputItemAddedEvent
    elseif type == "response.output_item.done"
        return StreamOutputItemDoneEvent
    elseif type == "response.content_part.added"
        return StreamContentPartAddedEvent
    elseif type == "response.content_part.done"
        return StreamContentPartDoneEvent
    elseif type == "response.output_text.delta"
        return StreamOutputTextDeltaEvent
    elseif type == "response.output_text.done"
        return StreamOutputTextDoneEvent
    elseif type == "response.output_text.annotation.added"
        return StreamOutputTextAnnotationAddedEvent
    elseif type == "response.refusal.delta"
        return StreamRefusalDeltaEvent
    elseif type == "response.refusal.done"
        return StreamRefusalDoneEvent
    elseif type == "response.reasoning_summary_part.added"
        return StreamReasoningSummaryPartAddedEvent
    elseif type == "response.reasoning_summary_part.done"
        return StreamReasoningSummaryPartDoneEvent
    elseif type == "response.reasoning_summary_text.delta"
        return StreamReasoningSummaryTextDeltaEvent
    elseif type == "response.reasoning_summary_text.done"
        return StreamReasoningSummaryTextDoneEvent
    elseif type == "response.reasoning_text.delta"
        return StreamReasoningTextDeltaEvent
    elseif type == "response.reasoning_text.done"
        return StreamReasoningTextDoneEvent
    elseif type == "response.function_call_arguments.delta"
        return StreamFunctionCallArgumentsDeltaEvent
    elseif type == "response.function_call_arguments.done"
        return StreamFunctionCallArgumentsDoneEvent
    elseif type == "response.mcp_call.completed"
        return StreamMCPCallCompletedEvent
    elseif type == "response.mcp_call.failed"
        return StreamMCPCallFailedEvent
    elseif type == "response.mcp_call.in_progress"
        return StreamMCPCallInProgressEvent
    elseif type == "response.mcp_list_tools.in_progress"
        return StreamMCPListToolsInProgressEvent
    elseif type == "response.mcp_list_tools.completed"
        return StreamMCPListToolsCompletedEvent
    elseif type == "response.mcp_list_tools.failed"
        return StreamMCPListToolsFailedEvent
    elseif type == "response.mcp_call_arguments.delta"
        return StreamMCPCallArgumentsDeltaEvent
    elseif type == "response.mcp_call_arguments.done"
        return StreamMCPCallArgumentsDoneEvent
    elseif type == "response.web_search_call.searching"
        return StreamWebSearchCallSearchingEvent
    elseif type == "response.web_search_call.in_progress"
        return StreamWebSearchCallInProgressEvent
    elseif type == "response.web_search_call.completed"
        return StreamWebSearchCallCompletedEvent
    elseif type == "response.file_search_call.searching"
        return StreamFileSearchCallSearchingEvent
    elseif type == "response.file_search_call.in_progress"
        return StreamFileSearchCallInProgressEvent
    elseif type == "response.file_search_call.completed"
        return StreamFileSearchCallCompletedEvent
    elseif type == "response.code_interpreter_call.in_progress"
        return StreamCodeInterpreterCallInProgressEvent
    elseif type == "response.code_interpreter_call.interpreting"
        return StreamCodeInterpreterCallInterpretingEvent
    elseif type == "response.code_interpreter_call.completed"
        return StreamCodeInterpreterCallCompletedEvent
    elseif type == "response.code_interpreter_call_code.delta"
        return StreamCodeInterpreterCallCodeDeltaEvent
    elseif type == "response.code_interpreter_call_code.done"
        return StreamCodeInterpreterCallCodeDoneEvent
    elseif type == "response.image_generation_call.in_progress"
        return StreamImageGenerationCallInProgressEvent
    elseif type == "response.image_generation_call.generating"
        return StreamImageGenerationCallGeneratingEvent
    elseif type == "response.image_generation_call.partial_image"
        return StreamImageGenerationCallPartialImageEvent
    elseif type == "response.image_generation_call.completed"
        return StreamImageGenerationCallCompletedEvent
    elseif type == "response.audio.delta"
        return StreamAudioDeltaEvent
    elseif type == "response.audio.done"
        return StreamAudioDoneEvent
    elseif type == "response.audio.transcript.delta"
        return StreamAudioTranscriptDeltaEvent
    elseif type == "response.audio.transcript.done"
        return StreamAudioTranscriptDoneEvent
    elseif type == "response.custom_tool_call_input.delta"
        return StreamCustomToolCallInputDeltaEvent
    elseif type == "response.custom_tool_call_input.done"
        return StreamCustomToolCallInputDoneEvent
    elseif type == "response.queued"
        return StreamResponseQueuedEvent
    elseif type == "error"
        return StreamErrorEvent
    else
        return error("Invalid stream event type: $type")
    end
end

end # module OpenAIResponses
