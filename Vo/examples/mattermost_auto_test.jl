# Automated Mattermost live integration test for tree-structured sessions
#
# Requires env vars (from ~/.zshrc):
#   MATTERMOST_URL, MATTERMOST_TOKEN (bot token), MATTERMOST_PAT (personal access token)
#   VO_AGENT_PROVIDER, VO_AGENT_MODEL, VO_AGENT_API_KEY
#
# Usage:
#   JULIA_SSL_NO_VERIFY_HOSTS="**" julia --project=Vo -t4 Vo/examples/mattermost_auto_test.jl

using Mattermost
using Vo
using SQLite
using Test

# SQLite.Row is a forward-only iterator; materialize to NamedTuples.
function sql_rows(db, sql, params=())
    return SQLite.DBInterface.execute(db, sql, params) |> SQLite.rowtable
end

const VoMM = Base.get_extension(Vo, :VoMattermostExt)

# ─── Helpers: post as the human user (PAT) ───

const PAT = ENV["MATTERMOST_PAT"]
const MM_URL = ENV["MATTERMOST_URL"]

function as_user(f)
    Mattermost.with_mattermost(PAT, MM_URL) do
        f()
    end
end

function user_post(channel_id::String, message::String; root_id::String="")
    as_user() do
        kwargs = isempty(root_id) ? (;) : (; root_id)
        Mattermost.create_post(channel_id, message; kwargs...)
    end
end

function user_delete(post_id::String)
    as_user() do
        Mattermost.delete_post(post_id)
    end
end

function find_dm_channel(bot_user_id::String)
    as_user() do
        me = Mattermost.get_me()
        Mattermost.create_direct_channel(me.id, bot_user_id)
    end
end

function wait_for_entry(db, entry_id; timeout=30, interval=0.5)
    local elapsed = 0.0
    while elapsed < timeout
        rows = sql_rows(db, "SELECT entry_id FROM session_entries WHERE entry_id = ?", (entry_id,))
        !isempty(rows) && return true
        sleep(interval)
        elapsed += interval
    end
    return false
end

function wait_for_branch(db, branch_id; timeout=30, interval=0.5)
    local elapsed = 0.0
    while elapsed < timeout
        rows = sql_rows(db, "SELECT leaf_entry_id FROM session_branches WHERE branch_id = ?", (branch_id,))
        if !isempty(rows) && rows[1].leaf_entry_id !== missing
            return String(rows[1].leaf_entry_id)
        end
        sleep(interval)
        elapsed += interval
    end
    return nothing
end

function count_entries(db, channel_id)
    rows = sql_rows(db, "SELECT COUNT(*) as cnt FROM session_entries WHERE channel_id = ? AND is_deleted = 0", (channel_id,))
    return rows[1].cnt
end

function dump_state(db, label)
    println("\n--- $label ---")
    println("Branches:")
    for r in sql_rows(db, "SELECT branch_id, leaf_entry_id FROM session_branches")
        println("  $(r.branch_id) → $(r.leaf_entry_id)")
    end
    println("Entries (last 10):")
    for r in sql_rows(db, "SELECT rowid, entry_id, parent_id, is_deleted, is_compaction, channel_id, search_channel_id FROM session_entries ORDER BY rowid DESC LIMIT 10")
        del = r.is_deleted == 1 ? " [DEL]" : ""
        comp = r.is_compaction == 1 ? " [COMP]" : ""
        pid = r.parent_id === missing ? "-" : r.parent_id
        println("  #$(r.rowid) eid=$(r.entry_id) parent=$(pid) ch=$(r.channel_id)$(del)$(comp)")
    end
    println("---\n")
end

# ─── Boot the assistant ───

println("Starting Vo with MattermostEventSource...")
assistant = Vo.init!(
    joinpath(mktempdir(), "vo_auto_test.sqlite");
    name = "Vo",
    event_sources = Vo.EventSource[VoMM.MattermostEventSource()],
)

bot_user_id = Mattermost.with_mattermost(ENV["MATTERMOST_TOKEN"], MM_URL) do
    me = Mattermost.get_me()
    println("Bot: @$(me.username) ($(me.id))")
    me.id
end

dm_ch = find_dm_channel(bot_user_id)
println("DM channel: $(dm_ch.id)")

db = assistant.db
dm_branch_id = "mattermost:$(dm_ch.id)"

# Give event loop a moment to connect
sleep(3)

# ═══════════════════════════════════════════════════════
# Test 1: DM basic message → entry created with correct branch
# ═══════════════════════════════════════════════════════

println("\n== Test 1: DM basic message ==")
post1 = user_post(dm_ch.id, "Hey Vo, what's 2+2?")
println("  Sent post: $(post1.id)")
println("  Waiting for bot to process...")

# Wait for branch to appear
leaf = wait_for_branch(db, dm_branch_id; timeout=45)
if leaf === nothing
    println("  FAIL: Branch $(dm_branch_id) not created after 45s")
    dump_state(db, "After Test 1 (FAIL)")
else
    println("  OK: Branch $(dm_branch_id) exists, leaf=$(leaf)")
    n = count_entries(db, dm_branch_id)
    println("  OK: $(n) entry(ies) for channel $(dm_branch_id)")
end

dump_state(db, "After Test 1")

# ═══════════════════════════════════════════════════════
# Test 2: DM follow-up → same branch, parent chain
# ═══════════════════════════════════════════════════════

println("\n== Test 2: DM follow-up (session continuity) ==")
leaf_before = wait_for_branch(db, dm_branch_id)
post2 = user_post(dm_ch.id, "And what's that times 10?")
println("  Sent follow-up: $(post2.id)")
println("  Waiting for bot to process...")

# Wait for leaf to change (bot processes msg 2)
let elapsed = 0.0
    while elapsed < 45
        new_leaf = wait_for_branch(db, dm_branch_id; timeout=1)
        if new_leaf !== nothing && new_leaf != leaf_before
            break
        end
        sleep(1)
        elapsed += 1
    end
end

leaf_after = wait_for_branch(db, dm_branch_id)
if leaf_after !== nothing && leaf_after != leaf_before
    println("  OK: Branch leaf updated: $(leaf_before) → $(leaf_after)")
else
    println("  WARN: Branch leaf unchanged: $(leaf_after)")
end
n2 = count_entries(db, dm_branch_id)
println("  Entries in branch: $(n2)")

# Check parent chain
rows = sql_rows(db,
    "SELECT entry_id, parent_id FROM session_entries WHERE channel_id = ? AND is_deleted = 0 ORDER BY rowid", (dm_branch_id,))
println("  Parent chain:")
for r in rows
    pid = r.parent_id === missing ? "ROOT" : r.parent_id
    println("    $(r.entry_id) ← parent=$(pid)")
end

dump_state(db, "After Test 2")

# ═══════════════════════════════════════════════════════
# Test 3: Thread reply → separate branch forked from parent
# ═══════════════════════════════════════════════════════

println("\n== Test 3: Thread reply (fork) ==")
# Reply to post1 in a thread
thread_post = user_post(dm_ch.id, "This is a thread reply to the first message!", root_id=post1.id)
println("  Sent thread reply: $(thread_post.id), root_id=$(post1.id)")
thread_branch_id = "mattermost:$(dm_ch.id):$(post1.id)"
println("  Expected thread branch: $(thread_branch_id)")
println("  Waiting for thread branch...")

thread_leaf = wait_for_branch(db, thread_branch_id; timeout=45)
if thread_leaf === nothing
    println("  FAIL: Thread branch not created after 45s")
    # Check if it ended up in the main branch instead
    println("  Checking main branch...")
    dump_state(db, "After Test 3 (FAIL)")
else
    println("  OK: Thread branch exists, leaf=$(thread_leaf)")
    thread_entries = count_entries(db, thread_branch_id)
    println("  OK: $(thread_entries) entry(ies) in thread branch")
end

dump_state(db, "After Test 3")

# ═══════════════════════════════════════════════════════
# Test 4: Delete message → scrub_post! marks entry deleted
# ═══════════════════════════════════════════════════════

println("\n== Test 4: Delete message (scrub_post!) ==")
post_del = user_post(dm_ch.id, "This message will self-destruct! Secret code is 42.")
println("  Sent: $(post_del.id)")
println("  Waiting for bot to process...")
sleep(8)  # give bot time to respond

# Check entry exists
rows_before = sql_rows(db,
    "SELECT entry_id, is_deleted FROM session_entries WHERE entry_id = ?", (post_del.id,))
if !isempty(rows_before)
    println("  OK: Entry exists, is_deleted=$(rows_before[1].is_deleted)")
else
    println("  WARN: Entry not found for $(post_del.id) (bot may not have stored it yet)")
end

println("  Deleting post...")
user_delete(post_del.id)
sleep(3)

rows_after = sql_rows(db,
    "SELECT entry_id, is_deleted FROM session_entries WHERE entry_id = ?", (post_del.id,))
if !isempty(rows_after)
    if rows_after[1].is_deleted == 1
        println("  OK: Entry marked as deleted")
    else
        println("  FAIL: Entry exists but is_deleted=$(rows_after[1].is_deleted)")
    end
else
    println("  INFO: No entry found (may not have been stored)")
end

dump_state(db, "After Test 4")

# ═══════════════════════════════════════════════════════
# Final summary
# ═══════════════════════════════════════════════════════

println("\n========================================")
println("  Live test complete. Review output above.")
println("========================================")

# Clean exit
println("\nShutting down...")
