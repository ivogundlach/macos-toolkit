#!/usr/bin/env python3
"""Fork a legacy Codex task after temporarily restoring its missing response."""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"
DB = os.path.expanduser("~/.codex/state_5.sqlite")


def retained_output(job):
    text = open(job["log"], errors="replace").read()
    if "=== attempt " in text:
        text = text[text.rfind("=== attempt "):].split("\n", 1)[1]
    if "\ntokens used\n" in text:
        text = text.rsplit("\ntokens used\n", 1)[0]
    return ("Recovered Usage Queue output\n\n" + text.strip() +
            "\n\n— Recovered from the retained CLI log; earlier output may have "
            "been truncated by the legacy 8,000-character limit.")


def rpc(process, request_id, method, params):
    process.stdin.write(json.dumps({"id": request_id, "method": method,
                                    "params": params}) + "\n")
    process.stdin.flush()
    while True:
        event = json.loads(process.stdout.readline())
        if event.get("id") != request_id:
            continue
        if event.get("error"):
            raise RuntimeError(event["error"])
        return event["result"]


def corrected_lines(path, response):
    lines = open(path, errors="replace").readlines()
    output = []
    inserted = False
    for line in lines:
        obj = json.loads(line)
        payload = obj.get("payload") or {}
        if (not inserted and obj.get("type") == "event_msg" and
                payload.get("type") == "task_complete"):
            timestamp = obj.get("timestamp")
            turn_id = payload.get("turn_id")
            output.append(json.dumps({
                "timestamp": timestamp,
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": response,
                            "phase": "final_answer", "memory_citation": None},
            }) + "\n")
            output.append(json.dumps({
                "timestamp": timestamp,
                "type": "response_item",
                "payload": {"type": "message", "id": "msg_" + uuid.uuid4().hex,
                            "role": "assistant",
                            "content": [{"type": "output_text", "text": response}],
                            "phase": "final_answer",
                            "internal_chat_message_metadata_passthrough": {
                                "turn_id": turn_id}},
            }) + "\n")
            payload["last_agent_message"] = response
            obj["payload"] = payload
            line = json.dumps(obj) + "\n"
            inserted = True
        output.append(line)
    if not inserted:
        raise RuntimeError("task_complete record not found")
    return output


def main(job_path, original_thread_id, response_path=None):
    job = json.load(open(job_path))
    con = sqlite3.connect(DB)
    row = con.execute("SELECT rollout_path FROM threads WHERE id=?",
                      (original_thread_id,)).fetchone()
    if not row:
        raise RuntimeError("original thread not found")
    rollout = row[0]
    backup = rollout + ".usagequeue-recovery-backup"
    shutil.copy2(rollout, backup)
    try:
        response = (open(response_path, errors="replace").read().strip()
                    if response_path else retained_output(job))
        fixed = corrected_lines(rollout, response)
        temp = rollout + ".tmp"
        with open(temp, "w") as handle:
            handle.writelines(fixed)
        os.replace(temp, rollout)

        process = subprocess.Popen(
            [CODEX, "app-server", "--stdio"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        try:
            rpc(process, 1, "initialize", {"clientInfo": {
                "name": "UsageQueueRecovery", "version": "1"}})
            result = rpc(process, 2, "thread/fork", {
                "threadId": original_thread_id, "threadSource": "user",
                "approvalPolicy": "never", "sandbox": "danger-full-access",
                "ephemeral": False})
            new_id = result["thread"]["id"]
            read = rpc(process, 3, "thread/read", {
                "threadId": new_id, "includeTurns": True})
        finally:
            process.terminate()
            process.wait(timeout=5)
    finally:
        os.replace(backup, rollout)

    items = [item for turn in read["thread"].get("turns", [])
             for item in turn.get("items", [])]
    if not any(item.get("type") == "agentMessage" for item in items):
        raise RuntimeError("fork has no renderable agentMessage")
    print(new_id)


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit("usage: recover_renderable_codex_thread.py JOB.json ORIGINAL_THREAD_ID [RESPONSE.txt]")
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
