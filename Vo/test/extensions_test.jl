module ExtensionTests

using Test
using Agentif
using Mattermost
using MSTeams
using Signal
using Slack
using Vo

@testset "VoSlackExt event mapping" begin
    ext = Base.get_extension(Vo, :VoSlackExt)
    @test ext !== nothing

    source = ext.SlackEventSource(; app_token="xapp-test", bot_token="xoxb-test")
    event_types = Set(et.name for et in Vo.get_event_types(source))
    @test "slack_message" in event_types
    @test "slack_reaction" in event_types
    handlers = Vo.get_event_handlers(source)
    @test any(h -> h.id == "slack_message_default", handlers)
    @test any(h -> h.id == "slack_reaction_default", handlers)

    web_client = Slack.WebClient(; token="xoxb-test")
    channel_type_cache = Dict("C123" => "channel", "C555" => "group", "C999" => "group")

    msg = Slack.SlackMessageEvent(
        type="message",
        channel="C123",
        channel_type="channel",
        user="U123",
        text="hello",
        ts="1700000000.123",
    )
    msg_event = ext._extract_message_event(msg, web_client, "", "", nothing, nothing, channel_type_cache)
    @test msg_event !== nothing
    @test Vo.get_name(msg_event) == "slack_message"
    @test Agentif.channel_id(Vo.get_channel(msg_event)) == "slack:C123:1700000000.123"
    @test !msg_event.direct_ping
    @test Agentif.source_message_id(Vo.get_channel(msg_event)) == "1700000000.123"
    @test Vo.event_content(msg_event) == "[U123]: hello"

    private_msg = Slack.SlackMessageEvent(
        type="message",
        channel="C555",
        channel_type="private_channel",
        user="U555",
        text="private hello",
        ts="1700000000.777",
    )
    private_msg_event = ext._extract_message_event(private_msg, web_client, "", "", nothing, nothing, channel_type_cache)
    @test private_msg_event !== nothing
    @test Agentif.is_group(Vo.get_channel(private_msg_event))
    @test Agentif.is_private(Vo.get_channel(private_msg_event))

    mention = Slack.SlackAppMentionEvent(
        type="app_mention",
        channel="C123",
        user="U123",
        text="<@UBOT> hi",
        ts="1700000001.456",
    )
    mention_event = ext._extract_message_event(mention, web_client, "UBOT", "vo", nothing, nothing, channel_type_cache)
    @test mention_event !== nothing
    @test mention_event.direct_ping

    bot_msg = Slack.SlackMessageEvent(
        type="message",
        channel="C123",
        channel_type="channel",
        bot_id="B999",
        text="ignore me",
        ts="1700000002.789",
    )
    @test ext._extract_message_event(bot_msg, web_client, "", "", nothing, nothing, channel_type_cache) === nothing

    reaction_payload = Slack.JSON.Object(
        "type" => "reaction_added",
        "user" => "U234",
        "reaction" => "thumbsup",
        "item" => Slack.JSON.Object(
            "type" => "message",
            "channel" => "C123",
            "ts" => "1700000000.123",
        ),
    )
    reaction_event = ext._extract_reaction_event(reaction_payload, web_client, "", nothing, nothing, channel_type_cache)
    @test reaction_event !== nothing
    @test Vo.get_name(reaction_event) == "slack_reaction"
    @test occursin("thumbsup", Vo.event_content(reaction_event))
    @test !Agentif.is_private(Vo.get_channel(reaction_event))

    private_reaction_payload = Slack.JSON.Object(
        "type" => "reaction_added",
        "user" => "U333",
        "reaction" => "eyes",
        "item" => Slack.JSON.Object(
            "type" => "message",
            "channel" => "C999",
            "ts" => "1700000010.999",
        ),
    )
    private_reaction = ext._extract_reaction_event(private_reaction_payload, web_client, "", nothing, nothing, channel_type_cache)
    @test private_reaction !== nothing
    @test Agentif.is_group(Vo.get_channel(private_reaction))
    @test Agentif.is_private(Vo.get_channel(private_reaction))

    @test ext._channel_type_from_info(Dict("is_im" => true)) == "im"
    @test ext._channel_type_from_info(Dict("is_channel" => true, "is_private" => false)) == "channel"
    @test ext._channel_type_from_info(Dict("is_channel" => true, "is_private" => true)) == "group"
    @test ext._channel_type_from_info(Dict("is_mpim" => true)) == "mpim"
    @test ext._channel_type_from_info(Dict("is_group" => true)) == "group"
    @test ext._channel_type_from_info(nothing) === nothing

    assistant = Vo.AgentAssistant(":memory:";
        provider="openai-completions",
        model_id="gpt-4o-mini",
        apikey="test-key",
    )

    # Group non-mention message should enqueue; group prompt decides whether to stay silent.
    group_request = Slack.SocketModeRequest(
        type="events_api",
        envelope_id="env-1",
        payload=Slack.SlackEventsApiPayload(
            type="event_callback",
            event_id="evt-group-1",
            event=Slack.SlackMessageEvent(
                type="message",
                channel="C123",
                channel_type="channel",
                user="U123",
                text="hello everyone",
                ts="1700000003.111",
            ),
        ),
    )
    ext._handle_request(group_request, web_client, "", "", nothing, nothing, assistant, channel_type_cache)
    @test isready(assistant.event_queue)
    ev_group = take!(assistant.event_queue)
    @test ev_group isa ext.SlackMessageEvent
    @test !ev_group.direct_ping

    # Mention in channel should also enqueue.
    mention_request = Slack.SocketModeRequest(
        type="events_api",
        envelope_id="env-2",
        payload=Slack.SlackEventsApiPayload(
            type="event_callback",
            event_id="evt-mention-1",
            event=Slack.SlackAppMentionEvent(
                type="app_mention",
                channel="C123",
                user="U123",
                text="<@UBOT> hi",
                ts="1700000004.222",
            ),
        ),
    )
    ext._handle_request(mention_request, web_client, "UBOT", "", nothing, nothing, assistant, channel_type_cache)
    @test isready(assistant.event_queue)
    ev = take!(assistant.event_queue)
    @test ev isa ext.SlackMessageEvent
    @test ev.direct_ping

    # Re-delivery of same mention is still a processable event.
    ext._handle_request(mention_request, web_client, "UBOT", "", nothing, nothing, assistant, channel_type_cache)
    @test isready(assistant.event_queue)
    ev2 = take!(assistant.event_queue)
    @test ev2 isa ext.SlackMessageEvent

    close(assistant.db)
end

@testset "VoMattermostExt channel buffering" begin
    ext = Base.get_extension(Vo, :VoMattermostExt)
    @test ext !== nothing

    source = ext.MattermostEventSource()
    event_types = Set(et.name for et in Vo.get_event_types(source))
    @test "mattermost_message" in event_types
    @test "mattermost_reaction" in event_types
    handlers = Vo.get_event_handlers(source)
    @test any(h -> h.id == "mattermost_message_default", handlers)
    @test any(h -> h.id == "mattermost_reaction_default", handlers)

    client = Mattermost.Client("test-token", "https://example.invalid/api/v4/")
    ch = ext.MattermostChannel("chan-1", "root-1", "post-1", client, nothing, "user-1", "alice", "D", "Test Channel")

    @test Agentif.channel_id(ch) == "mattermost:chan-1:root-1"
    @test Agentif.source_message_id(ch) == "post-1"
    @test !Agentif.is_group(ch)
    @test Agentif.is_private(ch)
    user = Agentif.get_current_user(ch)
    @test user !== nothing
    @test user.id == "user-1"
    @test user.name == "alice"

    Agentif.start_streaming(ch)
    @test ch.io !== nothing
    Agentif.append_to_stream(ch, "Hello")
    Agentif.append_to_stream(ch, " world")
    Agentif.finish_streaming(ch)
    @test String(take!(ch.io)) == "Hello world"

    # Empty buffer on close should do nothing and clear channel state.
    ch.io = IOBuffer()
    Agentif.close_channel(ch)
    @test ch.io === nothing
end

@testset "VoSignalExt event mapping" begin
    ext = Base.get_extension(Vo, :VoSignalExt)
    @test ext !== nothing

    source = ext.SignalEventSource(; number="+15550000000", base_url="http://127.0.0.1:8080", auto_reconnect=false)
    event_types = Set(et.name for et in Vo.get_event_types(source))
    @test event_types == Set(["signal_message"])
    handlers = Vo.get_event_handlers(source)
    @test any(h -> h.id == "signal_message_default", handlers)

    client = Signal.Client("+15550000000", "http://127.0.0.1:8080")

    dm = Signal.DataMessage(message="hello signal", timestamp=Int64(1700000000000))
    envelope = Signal.Envelope(sourceNumber="+12223334444", sourceName="Alice", dataMessage=dm)
    msg_event = ext._envelope_to_message_event(envelope, client, "+15550000000")
    @test msg_event !== nothing
    @test Vo.get_name(msg_event) == "signal_message"
    @test Vo.event_content(msg_event) == "hello signal"
    ch = Vo.get_channel(msg_event)
    @test Agentif.channel_id(ch) == "signal:+12223334444"
    @test Agentif.source_message_id(ch) == "1700000000000"
    @test !Agentif.is_group(ch)
    @test Agentif.is_private(ch)
    tools = Agentif.create_channel_tools(ch)
    @test length(tools) == 1
    @test tools[1].name == "react_to_message"

    group_dm = Signal.DataMessage(
        message="group hello",
        timestamp=Int64(1700000001000),
        groupInfo=Signal.GroupInfo(groupId="abc123"),
    )
    group_envelope = Signal.Envelope(sourceNumber="+19998887777", sourceName="Bob", dataMessage=group_dm)
    group_event = ext._envelope_to_message_event(group_envelope, client, "+15550000000")
    @test group_event !== nothing
    group_channel = Vo.get_channel(group_event)
    @test startswith(group_channel.recipient, "group.")
    @test Agentif.is_group(group_channel)
    @test Vo.event_content(group_event) == "[Bob]: group hello"

    self_dm = Signal.DataMessage(message="self", timestamp=Int64(1700000002000))
    self_envelope = Signal.Envelope(sourceNumber="+15550000000", dataMessage=self_dm)
    @test ext._envelope_to_message_event(self_envelope, client, "+15550000000") === nothing
end

@testset "VoMSTeamsExt event mapping" begin
    ext = Base.get_extension(Vo, :VoMSTeamsExt)
    @test ext !== nothing

    source = ext.MSTeamsEventSource(; app_id="app-id", app_password="secret")
    event_types = Set(et.name for et in Vo.get_event_types(source))
    @test "msteams_message" in event_types
    @test "msteams_reaction" in event_types
    handlers = Vo.get_event_handlers(source)
    @test any(h -> h.id == "msteams_message_default", handlers)
    @test any(h -> h.id == "msteams_reaction_default", handlers)

    client = MSTeams.BotClient(; app_id="app-id", app_password="secret")

    message_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-1",
        "text" => "hello teams",
        "from" => Dict("id" => "user-1", "name" => "Alice"),
        "recipient" => Dict("id" => "bot-1", "name" => "Vo"),
        "conversation" => Dict("id" => "conv-1", "conversationType" => "channel"),
    )
    message_events = ext._activity_to_events(message_activity, client)
    @test length(message_events) == 1
    msg_event = only(message_events)
    @test msg_event isa ext.MSTeamsMessageEvent
    msg_channel = Vo.get_channel(msg_event)
    @test Agentif.channel_id(msg_channel) == "msteams:conv-1"
    @test Agentif.is_group(msg_channel)
    @test !Agentif.is_private(msg_channel)
    @test Agentif.source_message_id(msg_channel) == "activity-1"
    @test Vo.event_content(msg_event) == "[Alice]: hello teams"

    dm_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-2",
        "text" => "dm ping",
        "from" => Dict("id" => "user-2", "name" => "Dana"),
        "recipient" => Dict("id" => "bot-1", "name" => "Vo"),
        "conversation" => Dict("id" => "conv-2", "conversationType" => "personal"),
    )
    dm_event = only(ext._activity_to_events(dm_activity, client))
    @test dm_event.direct_ping

    mention_activity = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-3",
        "text" => "<at>Vo</at> hello",
        "from" => Dict("id" => "user-3", "name" => "Morgan"),
        "recipient" => Dict("id" => "bot-1", "name" => "Vo"),
        "conversation" => Dict("id" => "conv-3", "conversationType" => "channel"),
        "entities" => [Dict(
            "type" => "mention",
            "mentioned" => Dict("id" => "bot-1"),
        )],
    )
    mention_event = only(ext._activity_to_events(mention_activity, client))
    @test mention_event.direct_ping

    reaction_activity = Dict{String, Any}(
        "type" => "messageReaction",
        "id" => "reaction-1",
        "replyToId" => "activity-1",
        "from" => Dict("id" => "user-4", "name" => "Riley"),
        "conversation" => Dict("id" => "conv-1", "conversationType" => "channel"),
        "reactionsAdded" => [Dict("type" => "like")],
        "reactionsRemoved" => [Dict("type" => "sad")],
    )
    reaction_events = ext._activity_to_events(reaction_activity, client)
    @test length(reaction_events) == 2
    @test count(ev -> ev isa ext.MSTeamsReactionEvent, reaction_events) == 2
    @test any(ev -> ev.action == "added" && ev.reaction == "like", reaction_events)
    @test any(ev -> ev.action == "removed" && ev.reaction == "sad", reaction_events)

    bot_message = Dict{String, Any}(
        "type" => "message",
        "id" => "activity-4",
        "text" => "bot text",
        "from" => Dict("id" => "bot-1", "name" => "Vo"),
        "recipient" => Dict("id" => "bot-1", "name" => "Vo"),
        "conversation" => Dict("id" => "conv-4", "conversationType" => "channel"),
    )
    @test isempty(ext._activity_to_events(bot_message, client))
end

end # module ExtensionTests
