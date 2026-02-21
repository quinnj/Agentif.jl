# Post deletion + scrub test
# JULIA_SSL_NO_VERIFY_HOSTS="**" julia --project=Vo -t4 Vo/examples/smoke_test_3.jl

using Mattermost, Vo, SQLite

const VoMM = Base.get_extension(Vo, :VoMattermostExt)

as_user(f) = Mattermost.with_mattermost(ENV["MATTERMOST_PAT"], ENV["MATTERMOST_URL"]) do; f(); end

bot_user_id = Mattermost.with_mattermost(ENV["MATTERMOST_TOKEN"], ENV["MATTERMOST_URL"]) do
    me = Mattermost.get_me()
    println("Bot: @$(me.username)")
    me.id
end

user_me = as_user() do; Mattermost.get_me(); end
dm_ch = as_user() do; Mattermost.create_direct_channel(user_me.id, bot_user_id); end
println("DM: $(dm_ch.id)")

db_path = joinpath(mktempdir(), "scrub_test.sqlite")
assistant = Vo.init!(db_path;
    name = "Vo",
    event_sources = Vo.EventSource[VoMM.MattermostEventSource()],
)
sleep(5)

# ─── Send a message, wait for bot reply, then delete ───
println("\n--- Sending message to create session entries ---")
p1 = as_user() do
    Mattermost.create_post(dm_ch.id, "Remember this secret: the code is ALPHA-7.")
end
global post_id = string(p1.id)
println("  Posted: $post_id")

# Wait for bot to process and reply
function wait_for_reply(ch_id, after_post, buid)
    for i in 1:15
        sleep(3)
        pr = as_user() do; Mattermost.get_channel_posts(ch_id; per_page=5); end
        for pid in pr.order
            p = pr.posts[pid]
            if p.user_id == buid && p.create_at > after_post.create_at
                return string(p.message)
            end
        end
    end
    return nothing
end

reply = wait_for_reply(dm_ch.id, p1, bot_user_id)
if reply !== nothing
    println("  Bot replied: \"$(first(reply, 100))\"")
else
    println("  WARN: No bot reply after 45s, continuing anyway...")
end

# Give session middleware time to fully commit the entry
println("  Waiting 5s for session entry to be committed...")
sleep(5)

# Helper: query entries by post_id (iterate directly to avoid collect issues)
function query_entries_by_post(db, pid)
    results = NamedTuple{(:id, :post_id, :is_deleted), Tuple{Any, Any, Any}}[]
    for r in SQLite.DBInterface.execute(db, "SELECT id, post_id, is_deleted FROM session_entries WHERE post_id = '$pid'")
        push!(results, (id=r.id, post_id=r.post_id, is_deleted=r.is_deleted))
    end
    return results
end

# Check session entries before deletion
println("\n--- Before deletion ---")
rows_before = query_entries_by_post(assistant.db, post_id)
println("  Entries with post_id=$post_id: $(length(rows_before))")
for r in rows_before
    println("    #$(r.id) deleted=$(r.is_deleted)")
end

total_before = first(SQLite.DBInterface.execute(assistant.db,
    "SELECT COUNT(*) as n FROM session_entries")).n
println("  Total entries: $total_before")

# Delete the post
println("\n--- Deleting post $post_id ---")
as_user() do; Mattermost.delete_post(post_id); end
println("  Deleted. Waiting 5s for scrub_post! to fire...")
sleep(5)

# Check session entries after deletion
println("\n--- After deletion ---")
rows_after = query_entries_by_post(assistant.db, post_id)
println("  Entries with post_id=$post_id: $(length(rows_after))")
for r in rows_after
    println("    #$(r.id) deleted=$(r.is_deleted)")
end

total_after = first(SQLite.DBInterface.execute(assistant.db,
    "SELECT COUNT(*) as n FROM session_entries")).n
println("  Total entries: $total_after (should be same as before)")

# Verify is_deleted was set
_is_del(r) = (r.is_deleted !== missing && r.is_deleted == 1)
global all_deleted = !isempty(rows_after) && all(_is_del, rows_after)
if all_deleted
    println("\n  OK scrub_post! marked entries as deleted")
else
    if isempty(rows_after)
        println("\n  WARN No entries found with that post_id (bot may not have stored it)")
    else
        println("\n  FAIL Some entries not marked as deleted")
    end
end

println("\nAll sessions:")
for r in SQLite.DBInterface.execute(assistant.db, "SELECT session_key, session_id FROM vo_sessions")
    println("  $(r.session_key) -> $(r.session_id)")
end

println("\nAll session entries:")
for r in SQLite.DBInterface.execute(assistant.db, "SELECT id, session_id, post_id, is_deleted, channel_id FROM session_entries ORDER BY id")
    pid = r.post_id === missing ? "-" : r.post_id
    cid = r.channel_id === missing ? "-" : r.channel_id
    del = (r.is_deleted !== missing && r.is_deleted == 1) ? " [DELETED]" : ""
    println("  #$(r.id) sid=$(r.session_id) post=$pid ch=$cid$del")
end

println("\nDone!")
