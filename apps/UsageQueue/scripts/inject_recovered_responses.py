#!/usr/bin/env python3
"""Import retained UsageQueue CLI output as historical Codex responses."""
import json
import subprocess
import sys

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"


def retained_output(job):
    text = open(job["log"], errors="replace").read()
    marker = "=== attempt "
    if marker in text:
        text = text[text.rfind(marker):]
        text = text.split("\n", 1)[1] if "\n" in text else text
    suffix = "\ntokens used\n"
    if suffix in text:
        text = text.rsplit(suffix, 1)[0]
    return text.strip()


def main(job_paths):
    jobs = [json.load(open(path)) for path in job_paths]
    process = subprocess.Popen(
        [CODEX, "app-server", "--stdio"], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    def send(request_id, method, params):
        process.stdin.write(json.dumps({"id": request_id, "method": method,
                                        "params": params}) + "\n")
        process.stdin.flush()

    send(1, "initialize", {"clientInfo": {"name": "UsageQueueRecovery",
                                            "title": "UsageQueue Recovery",
                                            "version": "1"}})
    request_id = 2
    try:
      for job in jobs:
        send(request_id, "thread/resume", {"threadId": job["thread_id"]})
        while True:
            event = json.loads(process.stdout.readline())
            if event.get("id") == request_id:
                if event.get("error"):
                    raise RuntimeError("%s: %s" % (job["id"], event["error"]))
                break
        request_id += 1
        recovered = retained_output(job)
        note = ("Recovered Usage Queue output\n\n" + recovered +
                "\n\n— Imported from the retained CLI log; earlier output may have been "
                "truncated by the legacy 8,000-character log limit.")
        send(request_id, "thread/inject_items", {
            "threadId": job["thread_id"],
            "items": [{"type": "message", "role": "assistant",
                       "content": [{"type": "output_text", "text": note}],
                       "phase": "final_answer"}],
        })
        while True:
            event = json.loads(process.stdout.readline())
            if event.get("id") != request_id:
                continue
            if event.get("error"):
                raise RuntimeError("%s: %s" % (job["id"], event["error"]))
            else:
                break
        request_id += 1
    finally:
        process.terminate()
        process.wait(timeout=5)
    print("recovered %d response(s)" % len(jobs))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: inject_recovered_responses.py JOB.json...")
    main(sys.argv[1:])
