# Live Mattermost integration test
#
# Requires env vars (from ~/.zshrc):
#   MATTERMOST_URL, MATTERMOST_TOKEN (bot token), MATTERMOST_PAT (personal access token)
#   VO_AGENT_PROVIDER, VO_AGENT_MODEL, VO_AGENT_API_KEY
#
# Usage:
#   JULIA_SSL_NO_VERIFY_HOSTS="**" julia --project=Vo -t4 Vo/examples/mattermost_live_test.jl

using Mattermost  # triggers VoMattermostExt
using Vo

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

function user_react(post_id::String, emoji::String)
    as_user() do
        Mattermost.add_reaction(post_id, emoji)
    end
end

function user_delete(post_id::String)
    as_user() do
        Mattermost.delete_post(post_id)
    end
end

function find_channel(team_name::String, channel_name::String)
    as_user() do
        team = Mattermost.get_team_by_name(team_name)
        Mattermost.get_channel_by_name(team.id, channel_name)
    end
end

function find_dm_channel(bot_user_id::String)
    as_user() do
        me = Mattermost.get_me()
        Mattermost.create_direct_channel(me.id, bot_user_id)
    end
end

# ─── Boot the assistant ───

println("🚀 Starting Vo with MattermostEventSource...")
assistant = Vo.init!(
    joinpath(mktempdir(), "vo_live_test.sqlite");
    name = "Vo",
    event_sources = Vo.EventSource[VoMM.MattermostEventSource(), Vo.ReplEventSource()],
)

# Get bot identity
bot_user_id = Mattermost.with_mattermost(ENV["MATTERMOST_TOKEN"], MM_URL) do
    me = Mattermost.get_me()
    println("🤖 Bot: @$(me.username) ($(me.id))")
    me.id
end

# ─── Discover channels ───

println("\n📋 Finding test channels...")
# Adjust these to match your Mattermost server
public_ch = find_channel("andavo", "town-square")
println("  Public channel: $(public_ch.display_name) ($(public_ch.id))")

dm_ch = find_dm_channel(bot_user_id)
println("  DM channel: $(dm_ch.id)")

# ─── Interactive test menu ───

function run_tests()
    println("""

    ╔══════════════════════════════════════════╗
    ║     Vo Mattermost Live Test Runner       ║
    ╠══════════════════════════════════════════╣
    ║  1. DM: basic message                    ║
    ║  2. DM: follow-up (session continuity)   ║
    ║  3. Public: @mention in town-square      ║
    ║  4. Public: message without @mention      ║
    ║  5. Reaction: thumbsup on bot's last msg ║
    ║  6. Delete: post a msg then delete it    ║
    ║  7. REPL: test a"..." macro              ║
    ║  8. Agent data: store + search           ║
    ║  9. Show sessions table                  ║
    ║  0. Quit                                 ║
    ╚══════════════════════════════════════════╝
    """)

    bot_username = Mattermost.with_mattermost(ENV["MATTERMOST_TOKEN"], MM_URL) do
        me = Mattermost.get_me()
        me.username
    end

    last_bot_post_id = ""

    while true
        print("\nChoice> ")
        choice = strip(readline())

        if choice == "1"
            println("📨 Sending DM: 'Hey Vo, what's 2+2?'")
            user_post(dm_ch.id, "Hey Vo, what's 2+2?")
            println("   ✅ Sent. Watch Mattermost for bot reply.")

        elseif choice == "2"
            println("📨 Sending DM follow-up: 'And what's that times 10?'")
            user_post(dm_ch.id, "And what's that times 10?")
            println("   ✅ Sent. Bot should use session context to know 'that' = 4.")

        elseif choice == "3"
            println("📨 Posting @mention in public channel...")
            user_post(public_ch.id, "@$(bot_username) what day of the week is it?")
            println("   ✅ Sent. Bot should reply (direct ping in group).")

        elseif choice == "4"
            println("📨 Posting in public channel WITHOUT @mention...")
            user_post(public_ch.id, "I wonder what the weather is like today")
            println("   ✅ Sent. Bot should stay silent (NO_REPLY / ∅ sentinel).")

        elseif choice == "5"
            println("👍 Finding bot's last post to react to...")
            posts = as_user() do
                Mattermost.get_channel_posts(dm_ch.id; per_page=5)
            end
            # Find the most recent post by the bot
            found = false
            for pid in posts.order
                post = posts.posts[pid]
                if post.user_id == bot_user_id
                    last_bot_post_id = pid
                    println("   Reacting 👍 to: \"$(first(post.message, 50))...\"")
                    user_react(pid, "thumbsup")
                    println("   ✅ Reaction sent. Bot should acknowledge.")
                    found = true
                    break
                end
            end
            found || println("   ❌ No bot posts found in DM.")

        elseif choice == "6"
            println("📨 Posting a message, then deleting it after 3 seconds...")
            post = user_post(dm_ch.id, "This message will self-destruct! Remember the secret code is 42.")
            post_id = post.id
            println("   Posted: $(post_id)")
            println("   Waiting 3 seconds for bot to process...")
            sleep(3)
            println("   🗑️ Deleting post $(post_id)...")
            user_delete(post_id)
            println("   ✅ Deleted. scrub_post! should have fired.")
            # Verify
            sleep(1)
            rows = collect(SQLite.DBInterface.execute(assistant.db,
                "SELECT is_deleted FROM session_entries WHERE post_id = ?", (post_id,)))
            if !isempty(rows)
                println("   📊 Session entries with post_id=$(post_id): $(length(rows)), is_deleted=$(rows[1].is_deleted)")
            else
                println("   📊 No session entries found for post_id=$(post_id) (may not have been stored yet)")
            end

        elseif choice == "7"
            println("🖥️ Testing REPL macro...")
            a"Hello from the REPL! Tell me a one-line joke."
            println("   ✅ Done.")

        elseif choice == "8"
            println("📨 Sending DM to trigger agent data store...")
            user_post(dm_ch.id, "Please store a note with key 'test-note' and value 'This is a live test of the db_store tool' using the db_store tool.")
            println("   ✅ Sent. Wait for bot to use db_store, then check:")
            println("   After bot replies, send choice 8b to verify.")

        elseif choice == "9"
            println("\n📊 Sessions table:")
            rows = collect(SQLite.DBInterface.execute(assistant.db,
                "SELECT session_key, session_id FROM vo_sessions"))
            if isempty(rows)
                println("   (empty)")
            else
                for r in rows
                    println("   $(r.session_key) → $(r.session_id)")
                end
            end
            println("\n📊 Session entries (last 10):")
            rows = collect(SQLite.DBInterface.execute(assistant.db,
                "SELECT id, session_id, post_id, is_deleted, channel_id FROM session_entries ORDER BY id DESC LIMIT 10"))
            if isempty(rows)
                println("   (empty)")
            else
                for r in rows
                    del = r.is_deleted == 1 ? " [DELETED]" : ""
                    pid = r.post_id === missing ? "-" : r.post_id
                    println("   #$(r.id) session=$(r.session_id) post=$(pid) ch=$(r.channel_id)$(del)")
                end
            end

        elseif choice == "0" || choice == "q"
            println("👋 Bye!")
            break

        else
            println("❓ Unknown choice: $choice")
        end
    end
end

# Need SQLite for inspection queries
using SQLite

println("\n✅ Assistant ready. Event loop running.")
run_tests()
