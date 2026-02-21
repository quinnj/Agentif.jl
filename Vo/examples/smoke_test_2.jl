# Reaction + Public Channel Test
# JULIA_SSL_NO_VERIFY_HOSTS="**" julia --project=Vo -t4 Vo/examples/smoke_test_2.jl

using Mattermost, Vo, SQLite

const VoMM = Base.get_extension(Vo, :VoMattermostExt)

as_user(f) = Mattermost.with_mattermost(ENV["MATTERMOST_PAT"], ENV["MATTERMOST_URL"]) do; f(); end

bot_user_id, bot_username = Mattermost.with_mattermost(ENV["MATTERMOST_TOKEN"], ENV["MATTERMOST_URL"]) do
    me = Mattermost.get_me()
    println("Bot: @$(me.username)")
    me.id, string(me.username)
end

user_me = as_user() do; Mattermost.get_me(); end
dm_ch = as_user() do; Mattermost.create_direct_channel(user_me.id, bot_user_id); end
println("DM: $(dm_ch.id)")

# Find public channel
public_ch = try
    as_user() do
        team = Mattermost.get_team_by_name("andavo")
        Mattermost.get_channel_by_name(team.id, "town-square")
    end
catch e
    println("Could not find town-square: $e")
    nothing
end
if public_ch !== nothing
    println("Public: $(public_ch.display_name) ($(public_ch.id))")
end

db_path = joinpath(mktempdir(), "smoke2.sqlite")
assistant = Vo.init!(db_path;
    name = "Vo",
    event_sources = Vo.EventSource[VoMM.MattermostEventSource()],
)
sleep(5)

# ─── Test 1: Reaction on bot message ───
println("\n--- Test 1: Send DM then react to bot reply ---")
p1 = as_user() do; Mattermost.create_post(dm_ch.id, "Say hello!"); end
println("  Sent: $(p1.id)")

bot_reply_id = nothing
for i in 1:15
    sleep(3)
    pr = as_user() do; Mattermost.get_channel_posts(dm_ch.id; per_page=5); end
    for pid in pr.order
        p = pr.posts[pid]
        if p.user_id == bot_user_id && p.create_at > p1.create_at
            global bot_reply_id = pid
            println("  Bot replied: \"$(first(string(p.message), 80))\"")
            break
        end
    end
    bot_reply_id !== nothing && break
end

if bot_reply_id !== nothing
    println("  Reacting thumbsup to $(bot_reply_id)")
    as_user() do; Mattermost.add_reaction(bot_reply_id, "thumbsup"); end

    # Wait for reaction response
    sleep(20)
    pr = as_user() do; Mattermost.get_channel_posts(dm_ch.id; per_page=10); end
    reaction_reply = nothing
    for pid in pr.order
        p = pr.posts[pid]
        if p.user_id == bot_user_id && pid != bot_reply_id && p.create_at > pr.posts[bot_reply_id].create_at
            reaction_reply = string(p.message)
            break
        end
    end
    if reaction_reply !== nothing
        println("  OK Reaction reply: \"$(first(reaction_reply, 120))\"")
    else
        println("  WARN No reaction reply (may need more time or check event handler)")
    end
else
    println("  FAIL No bot reply to react to")
end

# ─── Test 2: Public channel @mention ───
if public_ch !== nothing
    println("\n--- Test 2: @mention in public channel ---")
    mention_msg = "@" * bot_username * " what is 2+2? reply with just the number"
    p2 = as_user() do
        Mattermost.create_post(public_ch.id, mention_msg)
    end
    println("  Sent: $(p2.id)")

    found_public_reply = false
    for i in 1:15
        sleep(3)
        pr = as_user() do; Mattermost.get_channel_posts(public_ch.id; per_page=5); end
        for pid in pr.order
            p = pr.posts[pid]
            if p.user_id == bot_user_id && p.create_at > p2.create_at
                println("  OK Public reply: \"$(first(string(p.message), 80))\"")
                global found_public_reply = true
                break
            end
        end
        found_public_reply && break
    end
    if !found_public_reply
        println("  WARN No public channel reply after 45s")
    end

    # ─── Test 3: Message without @mention (should NOT reply) ───
    println("\n--- Test 3: Public message WITHOUT @mention (expect silence) ---")
    p3 = as_user() do
        Mattermost.create_post(public_ch.id, "Just chatting about the weather today")
    end
    println("  Sent: $(p3.id)")
    sleep(15)
    pr = as_user() do; Mattermost.get_channel_posts(public_ch.id; per_page=5); end
    got_unwanted_reply = false
    for pid in pr.order
        p = pr.posts[pid]
        if p.user_id == bot_user_id && p.create_at > p3.create_at
            println("  FAIL Bot replied when it shouldn't have: \"$(first(string(p.message), 80))\"")
            got_unwanted_reply = true
            break
        end
    end
    if !got_unwanted_reply
        println("  OK Bot stayed silent (correct for no @mention)")
    end
end

println("\nSessions:")
for r in SQLite.DBInterface.execute(assistant.db, "SELECT session_key, session_id FROM vo_sessions")
    println("  $(r.session_key) -> $(r.session_id)")
end

println("\nDone!")
