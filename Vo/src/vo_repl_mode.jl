"""
REPL integration for Vo.

This implements a custom REPL mode where:
- Type `>` at column 0 to enter vo mode
- Prompt is `vo> ` with standard editing (word nav, backspace, multi-line)
- Ctrl+C clears input but stays in vo mode; Backspace on empty exits to julia mode
- Enter submits; a spinner appears while thinking; response streams above the prompt
- User can type next prompt while response streams (but can't submit until done)
- Ctrl+C during response cancels evaluation and returns to clean prompt
- Duration line shows after response completes

Layout during response:
    [previous output]
    vo> submitted prompt

    ⠋ thinking...        ← or streaming response text

    vo> typing next      ← user can type here

State machine:
    IDLE ──Enter──→ THINKING ──first output──→ STREAMING ──done──→ IDLE
      ↑                 │                           │
      └────Ctrl+C───────┴───────────Ctrl+C──────────┘
"""

const VO_PROMPT = "vo> "

using REPL
using REPL.LineEdit
import REPL: outstream
using Markdown
using Term: Term

# ----------------------------
# Global state
# ----------------------------

# Lazily-initialized assistant instance
const repl_assistant_ref = Ref{Any}(nothing)

# Response state: :idle, :thinking, :streaming
const response_state = Ref{Symbol}(:idle)

# Active REPL state and IO for rendering
const active_repl_state = Ref{Any}(nothing)
const active_repl_io = Ref{Any}(nothing)

# Current evaluation task (for cancellation)
const current_eval_task = Ref{Union{Task,Nothing}}(nothing)

# Timing for duration display
const response_start_time = Ref{Float64}(0.0)

# Output reader task
const output_reader_task = Ref{Union{Task,Nothing}}(nothing)

# Flag to signal reader to stop gracefully
const reader_stop_flag = Ref{Bool}(false)

# Spinner state
const spinner_task = Ref{Union{Task,Nothing}}(nothing)
const spinner_running = Ref{Bool}(false)

# Lines printed in current response (for cursor management)
const output_line_count = Ref{Int}(0)
const partial_line = Ref{String}("")

# Lock for terminal operations
const render_lock = ReentrantLock()

# Cancellation flag
const cancel_requested = Ref{Bool}(false)

# ----------------------------
# Terminal escape codes
# ----------------------------

const SAVE_CURSOR = "\e[s"
const RESTORE_CURSOR = "\e[u"
const MOVE_UP = "\e[A"
const MOVE_DOWN = "\e[B"
const CLEAR_LINE = "\e[2K"
const MOVE_TO_COL1 = "\e[1G"
const CLEAR_TO_END = "\e[J"

# ----------------------------
# Helper: get underlying buffer for reading
# ----------------------------

"""
Get the readable buffer from an IO, handling IOContext wrapping.
"""
function get_readable_buffer(io::IO)
    if io isa IOContext
        return io.io
    end
    return io
end

# ----------------------------
# Assistant lifecycle
# ----------------------------

promptf() = VO_PROMPT

function ensure_assistant()
    assistant = repl_assistant_ref[]
    if assistant === nothing
        data_dir = get(ENV, "VO_DATA_DIR", nothing)
        # Use PipeBuffer for streaming output; wrap in IOContext for display settings
        output = IOContext(PipeBuffer(), :displaysize => (24, typemax(Int)))
        assistant = AgentAssistant(; data_dir, output)
        run!(assistant)
        repl_assistant_ref[] = assistant
        start_output_reader!(assistant)
    end
    return assistant
end

function shutdown_assistant()
    assistant = repl_assistant_ref[]
    assistant === nothing && return

    # Cancel any active response
    cancel_current_response()

    # Stop output reader gracefully
    stop_output_reader!()

    # Close assistant
    try
        close(assistant)
    catch err
        @debug "Error closing assistant" exception=(err, catch_backtrace())
    finally
        repl_assistant_ref[] = nothing
        response_state[] = :idle
    end
    return
end

# ----------------------------
# Response cancellation
# ----------------------------

function cancel_current_response()
    response_state[] == :idle && return

    cancel_requested[] = true

    # Stop spinner
    stop_spinner()

    # Interrupt eval task
    task = current_eval_task[]
    if task !== nothing && !istaskdone(task)
        try
            Base.throwto(task, InterruptException())
        catch
        end
    end
    current_eval_task[] = nothing

    # Drain any pending output
    assistant = repl_assistant_ref[]
    if assistant !== nothing
        buf = get_readable_buffer(assistant.output)
        try
            readavailable(buf)
        catch
        end
    end

    # Reset state
    response_state[] = :idle
    output_line_count[] = 0
    partial_line[] = ""

    # Redraw clean prompt
    io = active_repl_io[]
    s = active_repl_state[]
    if io !== nothing && s !== nothing
        lock(render_lock) do
            print(io, "\r", CLEAR_LINE, "\n", VO_PROMPT)
            flush(io)
        end
        # Clear input buffer
        buf = LineEdit.buffer(s)
        truncate(buf, 0)
    end

    cancel_requested[] = false
end

# ----------------------------
# Spinner
# ----------------------------

function start_spinner(io::IO, s)
    @debug "[vo] Starting spinner" io_type=typeof(io)
    spinner_running[] = true
    frames = ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
    spinner_task[] = @async begin
        @debug "[vo] Spinner task started"
        idx = 1
        while spinner_running[] && response_state[] == :thinking
            lock(render_lock) do
                spinner_text = "$(frames[idx]) thinking..."
                # Simple in-place update: go to start of line, clear, print spinner
                print(io, "\r", CLEAR_LINE, spinner_text)
                flush(io)
            end
            idx = idx == length(frames) ? 1 : idx + 1
            sleep(0.08)
        end
    end
end

function stop_spinner()
    spinner_running[] = false
    task = spinner_task[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end
    spinner_task[] = nothing
end

# ----------------------------
# Output rendering (simplified)
# ----------------------------

# Flag to track if we've printed anything yet (to clear thinking indicator)
const first_output_done = Ref{Bool}(false)

"""
Render a chunk of output text.
Simple approach: just print the text directly, clearing thinking indicator on first output.
"""
function render_output_chunk(text::String)
    @debug "[vo] render_output_chunk called" text_len=length(text) first_output=first_output_done[]
    isempty(text) && return

    io = active_repl_io[]
    if io === nothing
        @debug "[vo] render_output_chunk: no io available"
        return
    end

    lock(render_lock) do
        # On first output, clear the thinking/spinner line and start fresh
        if !first_output_done[]
            @debug "[vo] render_output_chunk: first output, clearing thinking indicator"
            # Clear the spinner line (we're on the line after it, so move up, clear, then back to col 1)
            print(io, "\r", CLEAR_LINE)  # Clear current position first
            first_output_done[] = true
        end

        # Simply print the text
        print(io, text)
        flush(io)
    end
end

"""
Print the duration line after response completes.
"""
function print_duration_line(io::IO, s, duration_secs::Float64)
    lock(render_lock) do
        # Get terminal width
        term_width = try
            displaysize(io)[2]
        catch
            80
        end

        # Format duration
        duration_str = if duration_secs < 60
            "$(round(Int, duration_secs))s"
        else
            mins = floor(Int, duration_secs / 60)
            secs = round(Int, duration_secs % 60)
            "$(mins)m $(secs)s"
        end

        # Build duration line: ─ Worked for Xs ────────
        prefix = "─ Worked for $duration_str "
        remaining = term_width - length(prefix)
        line = prefix * repeat("─", max(0, remaining))

        # Print the duration line, then a newline for separation
        println(io)  # Ensure we're on a new line
        println(io, line)
        flush(io)
    end
end

# ----------------------------
# Output reader loop
# ----------------------------

function start_output_reader!(assistant)
    task = output_reader_task[]
    if task !== nothing && !istaskdone(task)
        @debug "[vo] Output reader already running"
        return  # Already running
    end

    @debug "[vo] Starting output reader"
    reader_stop_flag[] = false
    output_reader_task[] = @async begin
        buf = get_readable_buffer(assistant.output)
        @debug "[vo] Output reader started" buf_type=typeof(buf)
        total_bytes = 0
        while !reader_stop_flag[]
            data = try
                readavailable(buf)
            catch err
                isa(err, InterruptException) && break
                @debug "[vo] Output reader error" exception=(err, catch_backtrace())
                break
            end

            if !isempty(data) && !cancel_requested[]
                total_bytes += length(data)
                @debug "[vo] Output reader got data" bytes=length(data) total=total_bytes state=response_state[]

                # First output transitions from thinking to streaming
                if response_state[] == :thinking
                    @debug "[vo] Transitioning from thinking to streaming"
                    stop_spinner()
                    response_state[] = :streaming
                end

                render_output_chunk(String(data))
            else
                sleep(0.02)
            end
        end
        @debug "[vo] Output reader exiting" total_bytes=total_bytes
    end
end

# ----------------------------
# Input processing
# ----------------------------

"""
Process user input: send to assistant, manage response lifecycle.
"""
function process_input!(assistant, io::IO, s, input::String, repl=nothing)
    @debug "[vo] process_input! starting" input_len=length(input)

    # Record start time
    response_start_time[] = time()
    response_state[] = :thinking
    output_line_count[] = 0
    first_output_done[] = false  # Reset for new response
    cancel_requested[] = false

    # Print newline and start spinner (spinner will show "thinking...")
    lock(render_lock) do
        println(io)  # Newline after input
        flush(io)
    end

    # Start spinner - it will print the thinking indicator
    start_spinner(io, s)

    # Drain any stale output
    buf = get_readable_buffer(assistant.output)
    try
        readavailable(buf)
    catch
    end

    # Start evaluation - evaluate! returns a Future, so we need to wait for it
    current_eval_task[] = @async begin
        try
            future = Agentif.evaluate!(assistant, input)
            # Wait for the Future to complete (this is where the actual API call happens)
            wait(future)
        catch err
            if !isa(err, InterruptException)
                # Show error
                render_output_chunk("\n[Error] $(sprint(showerror, err))\n")
            end
        finally
            # Evaluation complete
            if !cancel_requested[]
                stop_spinner()

                # Give a moment for final output to arrive
                sleep(0.2)

                # Print duration line
                duration = time() - response_start_time[]
                print_duration_line(io, s, duration)

                response_state[] = :idle
                current_eval_task[] = nothing

                # Show new prompt for next input (with blank line for spacing)
                lock(render_lock) do
                    print(io, "\n", VO_PROMPT)  # Blank line then prompt, no trailing newline
                    flush(io)
                end

                # Prepare REPL for next input - this resets the line buffer
                if repl !== nothing && s !== nothing
                    try
                        # Clear any leftover input and refresh
                        buf = LineEdit.buffer(s)
                        truncate(buf, 0)
                        LineEdit.refresh_line(s)
                    catch
                        # Ignore errors in REPL state manipulation
                    end
                end
            end
        end
    end
end

# ----------------------------
# REPL mode callbacks
# ----------------------------

function on_done(s, buf, ok, repl, main_mode)
    @debug "[vo] on_done called" ok=ok response_state=response_state[]
    ok || return REPL.transition(s, :abort)

    # Block submission if response in progress - put the input back
    if response_state[] != :idle
        @debug "[vo] Blocked - response in progress, restoring input"
        # Restore the input to the buffer so user doesn't lose it
        input = String(take!(buf))
        write(buf, input)
        seekstart(buf)
        return REPL.prepare_next(repl)
    end

    input = String(take!(buf))
    @debug "[vo] Input received" input=repr(input) len=length(input)

    if !isempty(strip(input))
        io = outstream(repl)
        active_repl_state[] = s
        active_repl_io[] = io

        # Don't reprint the prompt - REPL already showed it
        @debug "[vo] Calling ensure_assistant"
        assistant = ensure_assistant()
        @debug "[vo] Got assistant, calling process_input!" output_type=typeof(assistant.output)
        process_input!(assistant, io, s, input, repl)  # Pass repl for post-response prompt
        @debug "[vo] process_input! returned"
        # Don't call REPL.prepare_next here - process_input! will handle it when done
    else
        @debug "[vo] Empty input, skipping"
        # Only prepare next for empty input
        REPL.prepare_next(repl)
        REPL.reset_state(s)
    end
    return
end

function create_mode(repl::REPL.LineEditREPL, main_mode::LineEdit.Prompt)
    vo_mode = LineEdit.Prompt(
        promptf;
        prompt_prefix = repl.hascolor ? Base.text_colors[:cyan] : "",
        prompt_suffix = "",
        complete = REPL.REPLCompletionProvider(),
        sticky = true,
    )

    vo_mode.repl = repl
    hp = main_mode.hist
    hp.mode_mapping[:vo] = vo_mode
    vo_mode.hist = hp

    search_prompt, skeymap = LineEdit.setup_search_keymap(hp)
    prefix_prompt, prefix_keymap = LineEdit.setup_prefix_keymap(hp, vo_mode)

    vo_mode.on_done = (s, buf, ok) -> begin
        @debug "[vo] on_done callback triggered" ok=ok
        Base.@invokelatest(on_done(s, buf, ok, repl, main_mode))
    end

    mk = REPL.mode_keymap(main_mode)

    # Backspace handler: exit mode on empty, otherwise normal backspace
    backspace_handler = function (s, args...)
        buf = LineEdit.buffer(s)
        if buf.size == 0 && response_state[] == :idle
            shutdown_assistant()
            LineEdit.transition(s, main_mode)
            active_repl_state[] = nothing
            active_repl_io[] = nothing
        else
            LineEdit.edit_backspace(s)
            LineEdit.check_show_hint(s)
        end
        return
    end

    # Ctrl+C handler: cancel response or clear input
    ctrl_c_handler = function (s, args...)
        if response_state[] != :idle
            # Cancel active response
            cancel_current_response()
        else
            # Clear input buffer but stay in vo mode
            buf = LineEdit.buffer(s)
            truncate(buf, 0)
            LineEdit.refresh_line(s)
        end
        return
    end

    # Enter handler: only submit if idle
    enter_handler = function (s, args...)
        @debug "[vo] enter_handler called" response_state=response_state[]
        if response_state[] != :idle
            @debug "[vo] enter_handler: blocked, response in progress"
            # Ignore enter during response
            return
        end
        # Normal enter behavior
        @debug "[vo] enter_handler: calling commit_line"
        LineEdit.commit_line(s)
        @debug "[vo] enter_handler: commit_line returned"
        return
    end

    vo_keymap = Dict{Any,Any}(
        '\b' => backspace_handler,           # Backspace
        Char(0x7f) => backspace_handler,     # Delete
        Char(0x03) => ctrl_c_handler,        # Ctrl+C
        # Don't override Enter - let default behavior trigger on_done
        # We'll handle response-in-progress blocking in on_done itself
    )

    b = Dict{Any,Any}[
        skeymap,
        vo_keymap,
        mk,
        prefix_keymap,
        LineEdit.history_keymap,
        LineEdit.default_keymap,
        LineEdit.escape_defaults,
    ]
    vo_mode.keymap_dict = LineEdit.keymap(b)
    return vo_mode
end

function repl_init(repl::REPL.LineEditREPL)
    main_mode = repl.interface.modes[1]
    vo_mode = create_mode(repl, main_mode)
    push!(repl.interface.modes, vo_mode)

    keymap = Dict{Any,Any}(
        '>' => function (s, args...)
            @debug "[vo] '>' key pressed" is_empty=isempty(s) cursor_pos=position(LineEdit.buffer(s))
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                @debug "[vo] Transitioning to vo mode"
                ensure_assistant()
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, vo_mode) do
                    LineEdit.state(s, vo_mode).input_buffer = buf
                end
                @debug "[vo] Transitioned to vo mode"
            else
                LineEdit.edit_insert(s, '>')
                LineEdit.check_show_hint(s)
            end
            return
        end,
    )
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, keymap)
    return
end

const INSTALLED = Ref(false)

function maybe_install(repl::REPL.LineEditREPL)
    INSTALLED[] && return
    isdefined(repl, :interface) || (repl.interface = REPL.setup_interface(repl))
    repl_init(repl)
    INSTALLED[] = true
    return
end

function init_repl_mode!()
    if isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL
        maybe_install(Base.active_repl)
    end
    atreplinit() do repl
        if isinteractive() && repl isa REPL.LineEditREPL
            maybe_install(repl)
        end
    end
    return
end

# ----------------------------
# Non-REPL API (for tests)
# ----------------------------

"""
Stop the output reader task temporarily (used by non-REPL processing).
Returns true if a reader was running and stopped, false otherwise.
"""
function stop_output_reader!()
    reader = output_reader_task[]
    if reader !== nothing && !istaskdone(reader)
        reader_stop_flag[] = true
        # Give it time to notice the flag (max 0.5s)
        for _ in 1:25
            istaskdone(reader) && break
            sleep(0.02)
        end
        output_reader_task[] = nothing
        return true
    end
    return false
end

"""
Synchronous input processing for non-REPL contexts (tests).
"""
function process_input!(assistant::AgentAssistant, io::IO, input::String;
                        show_spinner::Bool=false,
                        min_wait::Float64=30.0,
                        idle_timeout::Float64=2.0,
                        max_timeout::Float64=300.0)
    # Stop the background output reader to prevent it from consuming our data
    # This is needed because ensure_assistant() starts a reader that would
    # otherwise consume all output before we can read it in this function
    had_reader = stop_output_reader!()

    buf = get_readable_buffer(assistant.output)

    # Drain stale output
    try
        readavailable(buf)
    catch
    end

    # Simple spinner for non-REPL
    spinner_stop = Ref(false)
    if show_spinner
        @async begin
            frames = ('|', '/', '-', '\\')
            idx = 1
            while !spinner_stop[]
                print(io, "\r[vo] $(frames[idx]) working...")
                flush(io)
                idx = idx == length(frames) ? 1 : idx + 1
                sleep(0.1)
            end
            print(io, "\r", " "^20, "\r")
            flush(io)
        end
    end

    # Start evaluation - evaluate! returns a Future immediately
    eval_future = Agentif.evaluate!(assistant, input)

    start_time = time()
    last_output = time()
    received_any = false

    # Helper to check if Future is done
    future_done() = (@atomic eval_future.set) != 0

    try
        while true
            elapsed = time() - start_time
            idle_time = time() - last_output

            elapsed > max_timeout && break

            data = try
                readavailable(buf)
            catch
                UInt8[]
            end

            if !isempty(data)
                received_any = true
                spinner_stop[] = true
                print(io, String(data))
                flush(io)
                last_output = time()
            end

            if future_done()
                # Future completed, but wait a bit for any final data
                received_any || (elapsed > min_wait && break)
                idle_time > idle_timeout && break
            end

            sleep(0.02)
        end
    finally
        spinner_stop[] = true
        # Wait for future to complete (should already be done, but just in case)
        try
            wait(eval_future)
        catch
        end
        # Restart the output reader if it was running before
        if had_reader
            start_output_reader!(assistant)
        end
    end

    return received_any
end
