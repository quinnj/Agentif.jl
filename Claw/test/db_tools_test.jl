module DBToolsTests

using Test
using Agentif
using Dates
using SQLite
using Claw

mutable struct DBMockChannel <: Agentif.AbstractChannel
    id::String
    _is_private::Bool
    _is_group::Bool
    user::Union{Nothing, Agentif.ChannelUser}
    post_id::Union{Nothing, String}
end

DBMockChannel(id; is_private::Bool=true, is_group::Bool=false, user=nothing, post_id=nothing) =
    DBMockChannel(id, is_private, is_group, user, post_id)

Agentif.channel_id(ch::DBMockChannel) = ch.id
Agentif.is_private(ch::DBMockChannel) = ch._is_private
Agentif.is_group(ch::DBMockChannel) = ch._is_group
Agentif.get_current_user(ch::DBMockChannel) = ch.user
Agentif.entry_id(ch::DBMockChannel) = ch.post_id
Agentif.start_streaming(::DBMockChannel) = nothing
Agentif.append_to_stream(::DBMockChannel, ::AbstractString) = nothing
Agentif.finish_streaming(::DBMockChannel) = nothing
Agentif.send_message(::DBMockChannel, ::Any) = nothing
Agentif.close_channel(::DBMockChannel) = nothing

function make_assistant()
    return AgentAssistant(":memory:"; search_options=(embed=nothing,),
        provider = "openai-completions",
        model_id = "gpt-4o-mini",
        apikey = "test-key",
        timezone = "UTC",
    )
end

function has_row(db::SQLite.DB, sql::String, params=())
    return iterate(SQLite.DBInterface.execute(db, sql, params)) !== nothing
end

@testset "DB tools visibility and lifecycle" begin
    assistant = make_assistant()
    Claw.CURRENT_ASSISTANT[] = assistant

    dm_a = DBMockChannel("dm:a"; is_private=true, is_group=false, user=Agentif.ChannelUser("U1", "Alice"), post_id="post-a")
    dm_b = DBMockChannel("dm:b"; is_private=true, is_group=false, user=Agentif.ChannelUser("U2", "Bob"), post_id="post-b")
    public_ch = DBMockChannel("chan:general"; is_private=false, is_group=true, user=Agentif.ChannelUser("U3", "Casey"), post_id="post-c")

    @test Agentif.with_channel(dm_a) do
        occursin("Stored 'dm-a-note'", Claw.db_store("dm-a-note", "alice secret note", "private,alice"))
    end
    @test Agentif.with_channel(dm_b) do
        occursin("Stored 'dm-b-note'", Claw.db_store("dm-b-note", "bob secret note", "private,bob"))
    end
    @test Agentif.with_channel(public_ch) do
        occursin("Stored 'public-note'", Claw.db_store("public-note", "shared status update", "status,shared"))
    end

    dm_a_secret = Agentif.with_channel(dm_a) do
        Claw.db_search("alice secret")
    end
    @test occursin("[dm-a-note]", dm_a_secret)

    dm_a_other_secret = Agentif.with_channel(dm_a) do
        Claw.db_search("bob secret")
    end
    @test !occursin("[dm-b-note]", dm_a_other_secret)

    dm_a_public = Agentif.with_channel(dm_a) do
        Claw.db_search("shared status")
    end
    @test occursin("[public-note]", dm_a_public)

    dm_a_keys = Agentif.with_channel(dm_a) do
        Claw.db_list_keys()
    end
    @test occursin("dm-a-note", dm_a_keys)
    @test occursin("public-note", dm_a_keys)
    @test !occursin("dm-b-note", dm_a_keys)

    tags_list = Claw.db_list_tags()
    @test occursin("alice", tags_list)
    @test occursin("shared", tags_list)

    removed = Claw.db_remove("dm-b-note")
    @test occursin("Removed 'dm-b-note'", removed)
    @test !has_row(assistant.db, "SELECT 1 FROM claw_agent_data WHERE key = ?", ("dm-b-note",))

    before_scrub = Agentif.with_channel(dm_a) do
        Claw.db_search("alice secret")
    end
    @test occursin("[dm-a-note]", before_scrub)

    Claw.scrub_post!(assistant, "post-a")
    @test !has_row(assistant.db, "SELECT 1 FROM claw_agent_data WHERE key = ?", ("dm-a-note",))

    after_scrub = Agentif.with_channel(dm_a) do
        Claw.db_search("alice secret")
    end
    @test !occursin("[dm-a-note]", after_scrub)

    Claw.shutdown!(assistant; timeout_s=5)
end

@testset "DB tools filters and time parsing" begin
    assistant = make_assistant()
    Claw.CURRENT_ASSISTANT[] = assistant

    dm = DBMockChannel("dm:filters"; is_private=true, is_group=false, user=Agentif.ChannelUser("U9", "Nina"), post_id="post-f")
    public_ch = DBMockChannel("chan:pub"; is_private=false, is_group=true, user=Agentif.ChannelUser("U8", "Pat"), post_id="post-p")

    Agentif.with_channel(dm) do
        Claw.db_store("and-match", "shared query token alpha beta", "alpha,beta")
        Claw.db_store("alpha-only", "shared query token alpha only", "alpha")
    end
    Agentif.with_channel(public_ch) do
        Claw.db_store("public-filter", "shared query token public", "alpha,beta,public")
    end

    and_search = Agentif.with_channel(dm) do
        Claw.db_search("shared query token", "alpha,beta")
    end
    @test occursin("[and-match]", and_search)
    @test !occursin("[alpha-only]", and_search)
    @test occursin("[public-filter]", and_search)

    recent_keys = Agentif.with_channel(dm) do
        Claw.db_list_keys(nothing, "1m", nothing, 20)
    end
    @test occursin("and-match", recent_keys)
    @test occursin("public-filter", recent_keys)

    old_keys = Agentif.with_channel(dm) do
        Claw.db_list_keys(nothing, nothing, "1m", 20)
    end
    @test old_keys == "No stored entries"

    recent_search = Agentif.with_channel(dm) do
        Claw.db_search("shared query token", nothing, "1m", nothing, 20)
    end
    @test occursin("[and-match]", recent_search)

    old_search = Agentif.with_channel(dm) do
        Claw.db_search("shared query token", nothing, nothing, "1m", 20)
    end
    @test old_search == "No results found matching filters for: shared query token"

    # Absolute and relative parsing coverage
    ts_abs = Claw._parse_time_filter("2026-01-15")
    @test ts_abs !== nothing
    @test abs(ts_abs - Dates.datetime2unix(Dates.DateTime(2026, 1, 15))) < 1
    ts_z = Claw._parse_time_filter("2026-01-15T12:00:00Z")
    ts_offset = Claw._parse_time_filter("2026-01-15T12:00:00-07:00")
    @test ts_z !== nothing
    @test ts_offset !== nothing
    @test abs((ts_offset - ts_z) - (7 * 3600)) < 1
    ts_utc = Claw._parse_time_filter("2026-01-15T12:00:00"; timezone = "UTC")
    ts_denver = Claw._parse_time_filter("2026-01-15T12:00:00"; timezone = "America/Denver")
    @test ts_utc !== nothing
    @test ts_denver !== nothing
    @test abs((ts_denver - ts_utc) - (7 * 3600)) < 1
    ts_rel = Claw._parse_time_filter("24h")
    @test ts_rel !== nothing
    @test ts_rel <= time()
    @test Claw._parse_time_filter("not-a-time") === nothing

    Claw.shutdown!(assistant; timeout_s=5)
end

@testset "DB tools reject NUL bytes and repair invalid UTF-8" begin
    assistant = make_assistant()
    Claw.CURRENT_ASSISTANT[] = assistant

    dm = DBMockChannel("dm:hostile"; is_private=true, is_group=false, user=Agentif.ChannelUser("U7", "Hedy"), post_id="post-h")
    nul = "a\0b"

    # NUL bytes cannot cross into the search backend's tokenizer, so every tool
    # names the offending argument instead of throwing an opaque C string error.
    Agentif.with_channel(dm) do
        @test occursin("db_store: `key` contains NUL bytes", Claw.db_store(nul, "nul value", "nul-tag"))
        @test occursin("db_store: `value` contains NUL bytes", Claw.db_store("nul-key", nul, "nul-tag"))
        @test occursin("db_store: `tags` contains NUL bytes", Claw.db_store("nul-key", "nul value", nul))
        @test occursin("db_search: `query` contains NUL bytes", Claw.db_search(nul))
        @test occursin("db_search: `tags` contains NUL bytes", Claw.db_search("nul value", nul))
        @test occursin("db_search: `after` contains NUL bytes", Claw.db_search("nul value", nothing, nul))
        @test occursin("db_search: `before` contains NUL bytes", Claw.db_search("nul value", nothing, nothing, nul))
        @test occursin("db_list_keys: `tags` contains NUL bytes", Claw.db_list_keys(nul))
        @test occursin("db_list_keys: `after` contains NUL bytes", Claw.db_list_keys(nothing, nul))
        @test occursin("db_list_keys: `before` contains NUL bytes", Claw.db_list_keys(nothing, nothing, nul))
        @test occursin("db_remove: `key` contains NUL bytes", Claw.db_remove(nul))
    end
    # A rejected store writes nothing at all, not a row missing its search index.
    @test !has_row(assistant.db, "SELECT 1 FROM claw_agent_data WHERE key = ?", ("nul-key",))

    # Invalid and truncated UTF-8 are repaired rather than rejected: the entry
    # stores, round-trips under the same argument, and every tool returns a
    # string the model can read back.
    for (name, bad) in (("invalid", String(UInt8[0xff, 0xfe, 0x80, 0x80]) * "tail"),
                        ("truncated", "ok" * String(UInt8[0xe2, 0x9c])))
        stored = Agentif.with_channel(dm) do
            Claw.db_store("bad-$name-$bad", "hostile payload $bad", "$bad,hostile")
        end
        @test occursin("Stored 'bad-$name-", stored)
        @test isvalid(String, stored)

        row = Claw._fetch_one(assistant.db, "SELECT key, value FROM claw_agent_data WHERE value LIKE ?", ("hostile payload%",))
        @test row !== nothing
        @test isvalid(String, row.key)
        @test isvalid(String, row.value)

        found = Agentif.with_channel(dm) do
            Claw.db_search(bad)
        end
        @test isvalid(String, found)
        tag_filtered = Agentif.with_channel(dm) do
            Claw.db_search("hostile payload", bad)
        end
        @test occursin("[bad-$name-", tag_filtered)
        listed = Agentif.with_channel(dm) do
            Claw.db_list_keys(bad)
        end
        @test occursin("bad-$name-", listed)
        @test isvalid(String, listed)
        @test isvalid(String, Claw.db_list_tags())

        # Repair is deterministic, so the same hostile key removes what it stored.
        removed = Agentif.with_channel(dm) do
            Claw.db_remove("bad-$name-$bad")
        end
        @test occursin("Removed 'bad-$name-", removed)
        @test isvalid(String, removed)
    end

    Claw.shutdown!(assistant; timeout_s=5)
end

@testset "DB tools concurrent writes are stable" begin
    assistant = make_assistant()
    Claw.CURRENT_ASSISTANT[] = assistant

    errors = Channel{Any}(64)
    @sync for i in 1:32
        @async begin
            try
                Claw.db_store("race-key", "value-$i", "race")
            catch e
                put!(errors, e)
            end
        end
    end
    @test !isready(errors)
    latest = Claw.db_search("value-", "race")
    @test occursin("[race-key]", latest)

    Claw.shutdown!(assistant; timeout_s=5)
end

end # module DBToolsTests
