# Terminal Tools Examples

This directory contains examples demonstrating `LLMTools.create_terminal_tools()`, which provides `exec_command` and `write_stdin` for interactive and persistent terminal sessions.

## Tool Overview

The terminal tools are modeled after Codex's UnifiedExec tool and provide:
- **exec_command**: Start shell commands in a PTY session and get a structured JSON response
- **write_stdin**: Interact with running sessions by sending input and polling for output
- **kill_session**: Explicitly terminate a running session
- **list_sessions**: Inspect active sessions with metadata

## Examples

### Basic Examples

1. **01_simple_echo.jl** - Simple command execution
   - Demonstrates basic `exec_command` usage
   - Shows how to run a simple command and get output

2. **06_multiline_output.jl** - Handling multi-line output
   - Shows how to process commands that produce multiple lines
   - Useful for scripts and loops

### Interactive Process Examples

3. **03_python_repl.jl** - Python REPL interaction
   - Starts an interactive Python session
   - Uses `write_stdin` to send commands
   - Demonstrates proper session cleanup with `exit()`

4. **04_cat_echo.jl** - Interactive echo test
   - Uses the `cat` command which echoes input back
   - Shows how to send text and EOF (Ctrl+D)
   - Good test for bidirectional communication

### Long-Running Process Examples

5. **02_delayed_output.jl** - Handling delayed output
   - Starts a process with a delay
   - Demonstrates polling with `write_stdin`
   - Shows how to wait for slow processes

6. **08_progressive_output.jl** - Watching process progress
   - Monitors a long-running process over time
   - Multiple polls to see incremental updates
   - Useful pattern for progress tracking

### Configuration Examples

7. **05_working_directory.jl** - Working directory control
   - Shows how to use the `workdir` parameter
   - Runs commands in different directories
   - Verifies directory changes work correctly

8. **09_environment_vars.jl** - Environment variables
   - Demonstrates environment variable access
   - Shows how shell environments work in PTY

### Advanced Examples

9. **07_bash_script.jl** - Complex bash scripts
   - Runs multi-line bash scripts
   - Shows functions and variables
   - Demonstrates complex command patterns

10. **10_error_handling.jl** - Error handling
    - Shows both successful and failing commands
    - Demonstrates stderr/stdout capture
    - Important for robust error handling

## Running the Examples

You can run any example with:

```bash
cd /Users/jacob.quinn/.julia/dev/Agentif
julia --project examples/terminal_tools/01_simple_echo.jl
```

Or run all examples:

```bash
for f in examples/terminal_tools/*.jl; do
    echo "Running $f"
    julia --project "$f"
    echo ""
done
```

## Tool Parameters

### exec_command

- `cmd` (required): Shell command to execute
- `workdir` (optional): Working directory for the command
- `shell` (optional): Shell to use (defaults to bash on Unix, powershell on Windows)
- `yield_time_ms` (optional): How long to wait for output before returning (default: 10000ms)
- `max_output_lines` (optional): Smart head/tail line truncation limit
- `max_output_tokens` (optional): Token-estimate truncation limit

### write_stdin

- `session_id` (required): The session ID returned by exec_command
- `chars` (optional): Characters to send to stdin (can be empty to just poll)
- `yield_time_ms` (optional): How long to wait for output (default: 250ms)
- `max_output_lines` (optional): Smart head/tail line truncation limit
- `max_output_tokens` (optional): Token-estimate truncation limit

## Key Patterns

### Starting a Long-Running Process

```julia
# Process that won't exit immediately returns a session_id
result = exec_command(cmd="python3 -i", yield_time_ms=1000)
# Extract session_id from result to use with write_stdin
```

### Polling for Output

```julia
# Send empty string to just poll for new output
result = write_stdin(session_id=1, chars="", yield_time_ms=500)
```

### Sending Commands to REPL

```julia
# Send command with newline to execute it
result = write_stdin(session_id=1, chars="print('hello')\\n", yield_time_ms=500)
```

### Exiting Cleanly

```julia
# Send EOF (Ctrl+D) to exit many interactive programs
result = write_stdin(session_id=1, chars="\\x04", yield_time_ms=500)
# Or use program-specific exit commands
result = write_stdin(session_id=1, chars="exit()\\n", yield_time_ms=500)
```

## Testing Notes

These examples are designed for live evaluation with AI agents. The agent should:
- Choose appropriate yield times based on expected command duration
- Poll for output when processes take longer than the initial yield time
- Handle both fast-completing and long-running processes
- Properly clean up interactive sessions

## Comparison with Codex UnifiedExec

This tool is modeled after Codex's background terminal feature with similar:
- PTY-based execution for true terminal emulation
- Session management for long-running processes
- Ability to interact with REPLs and interactive programs
- Support for both quick commands and persistent sessions

Key differences:
- Simpler Julia implementation using PtySessions package
- No built-in sandbox/security features (yet)
- Structured JSON responses with status/events/truncation metadata
- Output line and token-estimate truncation controls
- Session IDs are simple integers (Codex uses process IDs)
