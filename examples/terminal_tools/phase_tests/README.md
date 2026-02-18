# Phase Tests for terminal_tools

This directory contains comprehensive tests for all 3 phases of enhancements to the `terminal_tools`.

## Overview

These tests verify that all proposed features from the Codex analysis have been successfully implemented and work correctly.

## Phase 1: Critical Fixes ✅

### 01_test_session_metadata.jl
**Tests:** Session metadata tracking (created_at, last_used, command, workdir)

**Expected Results:**
- Sessions store complete metadata
- `list_sessions` displays all metadata fields
- Timestamps are tracked correctly

**Key Features:**
- `PtySessionMetadata` struct with all fields
- Metadata displayed in `list_sessions`

---

### 02_test_auto_cleanup.jl
**Tests:** Automatic cleanup of exited sessions

**Expected Results:**
- Short-lived commands don't leave sessions behind
- `write_stdin` to exited session auto-removes it
- `list_sessions` shows no lingering dead sessions

**Key Features:**
- Auto-cleanup in `exec_command` when process exits immediately
- Auto-cleanup in `write_stdin` when detecting exited process
- Clear notification when session is removed

---

### 03_test_grace_period.jl
**Tests:** 50ms grace period for capturing output from fast commands

**Expected Results:**
- Fast commands with short yield times still capture all output
- No lost output from commands that exit quickly
- Grace period is transparent to user

**Key Features:**
- 50ms sleep after detecting process exit
- Additional `readavailable()` call to capture final output
- Follows Codex's POST_EXIT_OUTPUT_GRACE pattern

---

### 04_test_session_limits.jl
**Tests:** Session limits (MAX=20) and LRU pruning

**Expected Results:**
- Warning at 15 sessions
- Auto-pruning at 20 sessions
- Oldest sessions pruned first
- Protected sessions (8 most recent) not pruned
- Exited sessions pruned before running ones

**Key Features:**
- `MAX_PTY_SESSIONS = 20`
- `WARNING_PTY_SESSIONS = 15`
- Smart LRU pruning algorithm
- Protection of 8 most recent sessions

---

## Phase 2: Quality of Life ✅

### 05_test_kill_session.jl
**Tests:** Explicit session termination with `kill_session`

**Expected Results:**
- Can terminate any session by ID
- Returns success message with command info
- Handles non-existent sessions gracefully
- Cleans up resources properly

**Key Features:**
- New `kill_session(session_id)` tool
- Explicit control over session lifecycle
- Helpful error messages

---

### 06_test_list_sessions.jl
**Tests:** Session visibility with `list_sessions`

**Expected Results:**
- Shows all active sessions when sessions exist
- Shows "No active sessions" when empty
- Displays: ID, status, command, created time, last used, workdir
- Updates "last used" when session is interacted with

**Key Features:**
- New `list_sessions()` tool
- Rich metadata display
- Sorted by session ID
- Total count with max limit shown

---

## Phase 3: Advanced Features ✅

### 07_test_max_output_lines.jl
**Tests:** `max_output_lines` parameter for limiting output

**Expected Results:**
- Without parameter: full output shown
- With parameter: output truncated smartly
- Truncation message indicates how many lines removed
- Both `exec_command` and `write_stdin` support it

**Key Features:**
- New `max_output_lines` parameter (default: 1000)
- HeadTailBuffer-based truncation
- Preserves beginning and end of output

---

### 08_test_head_tail_buffer.jl
**Tests:** HeadTailBuffer smart truncation algorithm

**Expected Results:**
- Large outputs show first N/2 and last N/2 lines
- Truncation indicator shows how many lines omitted
- Head and tail are both visible
- Works for both stdout and stdin interactions

**Key Features:**
- `HeadTailBuffer` struct
- `create_head_tail_buffer()` function
- `format_head_tail_buffer()` function
- Intelligent line-based truncation

---

### 09_test_integrated_workflow.jl
**Tests:** All features working together in realistic workflow

**Expected Results:**
- Multiple sessions managed simultaneously
- Auto-cleanup, manual cleanup both work
- Session limits enforced
- Output truncation helps with large outputs
- All tools (`exec_command`, `write_stdin`, `kill_session`, `list_sessions`) work together

**Demonstrates:**
- Complete development workflow
- Session lifecycle management
- Resource limit enforcement
- Practical usage patterns

---

## Running the Tests

### Run Individual Test:
```bash
julia --project=/Users/jacob.quinn/.julia/dev/Agentif examples/terminal_tools/phase_tests/01_test_session_metadata.jl
```

### Run All Tests:
```bash
for f in examples/terminal_tools/phase_tests/*.jl; do
    echo "Running $f"
    julia --project "$f"
    echo ""
done
```

### Run Specific Phase:
```bash
# Phase 1 tests (critical fixes)
julia --project examples/terminal_tools/phase_tests/01_test_session_metadata.jl
julia --project examples/terminal_tools/phase_tests/02_test_auto_cleanup.jl
julia --project examples/terminal_tools/phase_tests/03_test_grace_period.jl
julia --project examples/terminal_tools/phase_tests/04_test_session_limits.jl

# Phase 2 tests (QoL features)
julia --project examples/terminal_tools/phase_tests/05_test_kill_session.jl
julia --project examples/terminal_tools/phase_tests/06_test_list_sessions.jl

# Phase 3 tests (advanced features)
julia --project examples/terminal_tools/phase_tests/07_test_max_output_lines.jl
julia --project examples/terminal_tools/phase_tests/08_test_head_tail_buffer.jl

# Integration test
julia --project examples/terminal_tools/phase_tests/09_test_integrated_workflow.jl
```

## Expected Test Behavior

All tests use AI agents to interact with the tools, so:
- Tests may take 30-60 seconds each (agent thinking + execution)
- Agents will adapt their approach based on tool responses
- Some variation in exact commands is expected
- All tests should complete successfully

## What Success Looks Like

For each test:
- ✅ Agent successfully executes all test steps
- ✅ No errors or exceptions
- ✅ Expected behavior matches implementation
- ✅ Output shows features working as designed

## Troubleshooting

### Session Limit Warnings
If you see warnings about too many sessions, this is expected in test 04. The test intentionally triggers warnings and pruning.

### Cleanup Messages
`@info` messages like "Session X has exited and been removed" are expected - they show auto-cleanup working.

### API Rate Limits
If tests fail with API errors, wait a few minutes between test runs or use a smaller test subset.

## Feature Verification Checklist

After running all tests, verify:

### Phase 1
- [ ] Session metadata tracked (created_at, last_used, command, workdir)
- [ ] Auto-cleanup of exited sessions works
- [ ] 50ms grace period captures fast command output
- [ ] Session limit (20) enforced with warnings
- [ ] LRU pruning works correctly
- [ ] Protected sessions (8 most recent) not pruned

### Phase 2
- [ ] `kill_session` terminates sessions
- [ ] `list_sessions` shows all metadata
- [ ] Session visibility is clear and helpful
- [ ] Manual cleanup works

### Phase 3
- [ ] `max_output_lines` parameter works
- [ ] HeadTailBuffer truncates smartly
- [ ] Head and tail of output visible
- [ ] Large outputs manageable

### Integration
- [ ] All tools work together
- [ ] Realistic workflows function correctly
- [ ] Resource management is automatic
- [ ] User experience is smooth

## Comparison with Original Implementation

| Feature | Original | Enhanced |
|---------|----------|----------|
| Session tracking | Simple Dict | Metadata struct |
| Cleanup | Manual only | Automatic + Manual |
| Output limits | None | HeadTailBuffer |
| Session limits | None | 20 max with pruning |
| Visibility | None | list_sessions |
| Grace period | No | 50ms |
| Last used tracking | No | Yes |
| Warnings | No | Yes at 15 sessions |
| Tools | 2 | 4 |

## Performance Notes

- Cleanup runs on every `exec_command` (minimal overhead)
- Pruning only triggered at limit (rare)
- HeadTailBuffer is O(n) in lines (fast)
- Metadata tracking adds ~100 bytes per session (negligible)

## Next Steps

After verifying all tests pass:
1. Update main README with new features
2. Add to API documentation
3. Create user guide with examples
4. Consider additional tests for edge cases
