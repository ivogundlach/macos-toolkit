#!/usr/bin/env python3

import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


BASE = Path.home() / ".config" / "smart-wake"
CONFIG = BASE / "config.env"
TOKEN_FILE = BASE / "discord-bot-token"
STATE_FILE = BASE / "state" / "discord-last-message-id"
LOG_FILE = Path.home() / ".local" / "state" / "smart-wake" / "discord.log"
HEALTH_FILE = Path.home() / ".local" / "state" / "smart-wake" / "discord-health.json"
CLI = Path.home() / ".local" / "bin" / "smart-wake"
API_BASE = "https://discord.com/api/v10"
DURATION_RE = re.compile(r"^([0-9]+)(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)$")


def log(message):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"{timestamp}: {message}\n")


def write_health(health):
    HEALTH_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = HEALTH_FILE.with_name(f".{HEALTH_FILE.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(health, separators=(",", ":"), sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, HEALTH_FILE)


def load_config():
    values = {}
    if not CONFIG.exists():
        return values
    for raw_line in CONFIG.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def parse_command(content):
    command = "".join(content.strip().lower().split())
    if command == "status":
        return ("status", None)
    if command in {"sleep", "off", "stop"}:
        return ("off", None)
    if DURATION_RE.fullmatch(command):
        return ("on", command)
    return None


class DiscordClient:
    def __init__(self, token):
        self.token = token

    def request(self, method, path, payload=None):
        data = None
        headers = {
            "Authorization": f"Bot {self.token}",
            "User-Agent": "SmartWake/1.0",
        }
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{API_BASE}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Discord HTTP {error.code}: {detail[:300]}") from error
        return json.loads(body) if body else None

    def messages_after(self, channel_id, after=None):
        query = {"limit": "100"}
        if after:
            query["after"] = after
        path = f"/channels/{channel_id}/messages?{urllib.parse.urlencode(query)}"
        return self.request("GET", path) or []

    def reply(self, channel_id, message_id, content):
        payload = {
            "content": content[:1900],
            "message_reference": {
                "message_id": message_id,
                "channel_id": channel_id,
                "fail_if_not_exists": False,
            },
            "allowed_mentions": {"parse": []},
        }
        self.request("POST", f"/channels/{channel_id}/messages", payload)


def execute_command(command):
    action, argument = command
    args = [str(CLI), action]
    if argument:
        args.append(argument)
    completed = subprocess.run(
        args,
        check=False,
        capture_output=True,
        text=True,
        timeout=20,
    )
    output = (completed.stdout or completed.stderr).strip()
    if completed.returncode != 0:
        raise RuntimeError(output or f"smart-wake exited {completed.returncode}")
    return output or "Smart Wake command completed."


def read_last_message_id():
    try:
        return STATE_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def write_last_message_id(message_id):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(f"{message_id}\n", encoding="utf-8")


def process_messages(client, channel_id, allowed_user_ids, last_message_id):
    messages = client.messages_after(channel_id, last_message_id or None)
    for message in sorted(messages, key=lambda item: int(item["id"])):
        message_id = message["id"]
        author = message.get("author", {})
        if not author.get("bot") and author.get("id") in allowed_user_ids:
            command = parse_command(message.get("content", ""))
            if command:
                try:
                    response = execute_command(command)
                    client.reply(channel_id, message_id, response)
                    log(f"Accepted Discord command {command[0]} from user {author.get('id')}")
                except Exception as error:
                    log(f"Discord command failed for message {message_id}: {error}")
                    try:
                        client.reply(channel_id, message_id, "Smart Wake command failed. Check the Mac logs.")
                    except Exception as reply_error:
                        log(f"Discord error reply failed: {reply_error}")
        write_last_message_id(message_id)
        last_message_id = message_id
    return last_message_id


def main():
    config = load_config()
    channel_id = config.get("DISCORD_CHANNEL_ID", "").strip()
    allowed_user_ids = {
        item.strip()
        for item in config.get("DISCORD_ALLOWED_USER_IDS", "").split(",")
        if item.strip()
    }
    poll_seconds = int(config.get("DISCORD_POLL_SECONDS", "5"))
    if not channel_id or not allowed_user_ids:
        raise SystemExit("Discord channel and allowed user ID must be configured")
    token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit("Discord bot token is empty")

    client = DiscordClient(token)
    current_time = time.time()
    health = {
        "schemaVersion": 1,
        "pid": os.getpid(),
        "startedAt": current_time,
        "updatedAt": current_time,
        "lastSuccessAt": None,
        "lastFailureAt": None,
        "consecutiveFailures": 0,
        "lastError": "",
    }
    write_health(health)
    last_health_write = current_time
    last_message_id = read_last_message_id()
    initialized = bool(last_message_id)

    while True:
        try:
            if not initialized:
                latest = client.messages_after(channel_id)
                if latest:
                    last_message_id = max(latest, key=lambda item: int(item["id"]))["id"]
                    write_last_message_id(last_message_id)
                initialized = True
                log("Discord command watcher initialized")
            else:
                last_message_id = process_messages(
                    client, channel_id, allowed_user_ids, last_message_id
                )
            recovered_failures = health["consecutiveFailures"]
            current_time = time.time()
            health.update({
                "updatedAt": current_time,
                "lastSuccessAt": current_time,
                "consecutiveFailures": 0,
                "lastError": "",
            })
            if recovered_failures or current_time - last_health_write >= 60:
                write_health(health)
                last_health_write = current_time
            if recovered_failures:
                log(f"Discord polling recovered after {recovered_failures} consecutive failures")
        except Exception as error:
            previous_error = health["lastError"]
            current_time = time.time()
            health.update({
                "updatedAt": current_time,
                "lastFailureAt": current_time,
                "consecutiveFailures": health["consecutiveFailures"] + 1,
                "lastError": str(error),
            })
            failure_count = health["consecutiveFailures"]
            if failure_count == 1 or failure_count % 12 == 0 or str(error) != previous_error:
                write_health(health)
                last_health_write = current_time
                log(f"Discord polling failed ({failure_count} consecutive): {error}")
        time.sleep(max(2, poll_seconds))


if __name__ == "__main__":
    main()
