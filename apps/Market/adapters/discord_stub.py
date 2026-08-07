"""Discord stub adapter — placeholder until premium server access (~2026-07).

Drop-in steps when access arrives:
1. Install DiscordChatExporter CLI (read-only export tool).
2. Put the user token in ~/Projects/Market/secrets.env as DISCORD_TOKEN (0600).
3. Add channel IDs to config.json sources.discord.channels and set enabled=true.
4. Replace this stub: export channel JSON since the last watermark, then for each message
   call store.insert_event(source="discord", native_id=message_id, rank=1, type_="alert", ...).
   Dedup, JSONL export, ranking, synthesis, dashboard, and email need no changes (see schema.md).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pipeline"))
import store
import util


def main():
    cfg = store.config()
    if not cfg["sources"]["discord"].get("enabled"):
        util.log("discord_stub", "disabled (awaiting access ~2026-07); nothing to do")
        return
    util.log("discord_stub", "ERROR: enabled but stub not replaced with DiscordChatExporter wrapper")
    sys.exit(1)


if __name__ == "__main__":
    main()
