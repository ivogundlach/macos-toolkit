#!/usr/bin/env python3
"""Fork legacy headless Codex threads into native app-visible threads."""
import json
import subprocess
import sys

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"


def main(thread_ids):
    process = subprocess.Popen(
        [CODEX, "app-server", "--stdio"], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    def send(request_id, method, params):
        process.stdin.write(json.dumps({"id": request_id, "method": method,
                                        "params": params}) + "\n")
        process.stdin.flush()

    send(1, "initialize", {"clientInfo": {"name": "UsageQueueMigration",
                                            "title": "UsageQueue Migration",
                                            "version": "1"}})
    pending = {}
    for request_id, thread_id in enumerate(thread_ids, 2):
        pending[request_id] = thread_id
        send(request_id, "thread/fork", {
            "threadId": thread_id,
            "threadSource": "user",
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "ephemeral": False,
        })

    migrated = {}
    try:
        for line in process.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            request_id = event.get("id")
            if request_id not in pending:
                continue
            if event.get("error"):
                raise RuntimeError("%s: %s" % (pending[request_id], event["error"]))
            new_id = ((event.get("result") or {}).get("thread") or {}).get("id")
            if not new_id:
                raise RuntimeError("%s: missing forked thread id" % pending[request_id])
            migrated[pending.pop(request_id)] = new_id
            if not pending:
                break
    finally:
        process.terminate()
        process.wait(timeout=5)

    print(json.dumps(migrated, indent=2, sort_keys=True))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: promote_codex_threads.py THREAD_ID...")
    main(sys.argv[1:])
