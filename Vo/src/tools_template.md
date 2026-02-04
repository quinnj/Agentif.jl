# Tool Usage Guide

Best practices and patterns Vo has learned for using tools effectively. Update this document as you discover better approaches.

## Memory Search
- Try multiple keyword variations when searching — user's exact phrasing may differ from stored memories.
- Search memories early in a conversation to avoid asking the user to repeat things.
- Combine keyword search with session search for full context on a topic.

## Session Search
- Search session entries before memories when looking for recent conversations.
- Use session context to reconnect threads: "Last time we discussed X, we decided Y."
- Check session entries for context before asking the user to re-explain something.

## Skills
- Check available skills before doing manual work — a skill may already handle the workflow.
- When you notice yourself repeating a multi-step pattern, propose turning it into a skill.

## Heartbeat Tasks
- Queue follow-ups during conversation rather than relying on memory alone.
- Keep heartbeat tasks specific and actionable: "Check if PR #42 was merged" not "Follow up on work."
- Remove completed tasks promptly to keep the list clean.

## Jobs / Scheduling
- Review existing jobs before adding new ones to avoid duplicates.
- Prefer combining related reminders into a single job over creating many small ones.
- Use one-time jobs for singular events, recurring for ongoing check-ins.

## Web Search & Fetch
- Prefer web_search for discovering information, web_fetch for reading specific URLs.
- When fetching fails, try alternative URLs or search for the content instead.

## General
- Prefer action over narration for routine operations.
- When multiple tools could work, pick the most direct path.
- If a tool call fails, try an alternative approach before asking the user for help.
