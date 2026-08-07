import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
from datetime import datetime

NOTES_DIR = "/Users/YOUR_USERNAME/Files"
IMPORT_DIR = os.path.join(NOTES_DIR, "Notebook LM Inbox")
SYNC_DIR = "/Users/YOUR_USERNAME/.local/state/notebooklm-sync"
SYNC_HISTORY_FILE = os.path.join(SYNC_DIR, ".notebooklm_sync_history.json")
LOCK_FILE = os.path.join(SYNC_DIR, ".notebooklm_sync.lock")
NOTEBOOKLM_BIN = os.environ.get("NOTEBOOKLM_BIN", "/opt/homebrew/bin/notebooklm")

os.makedirs(IMPORT_DIR, exist_ok=True)
os.makedirs(SYNC_DIR, exist_ok=True)

parser = argparse.ArgumentParser(description="Sync NotebookLM notebooks, sources, and chats into local markdown files.")
parser.add_argument("--notebook-title", help="Sync only one notebook title. Default: sync all notebooks.")
args = parser.parse_args()


def slug_name(value):
    value = re.sub(r'[\\/:*?"<>|]+', "_", value.strip())
    value = re.sub(r"\s+", " ", value)
    return value[:120] or "Untitled"


def load_history():
    if not os.path.exists(SYNC_HISTORY_FILE):
        return {"version": 2, "notebooks": {}}

    try:
        with open(SYNC_HISTORY_FILE, "r") as f:
            data = json.load(f)
    except json.JSONDecodeError:
        return {"version": 2, "notebooks": {}}

    if isinstance(data, list):
        return {"version": 2, "notebooks": {"legacy": {"sources": data, "chat_count": 0}}}

    if "notebooks" not in data:
        sources = data.get("sources", [])
        chat_count = data.get("chat_count", 0)
        return {"version": 2, "notebooks": {"legacy": {"sources": sources, "chat_count": chat_count}}}

    data["version"] = 2
    return data


def save_history(history):
    with open(SYNC_HISTORY_FILE, "w") as f:
        json.dump(history, f, indent=2, sort_keys=True)


def run_cmd(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Command failed: {' '.join(cmd)}")
        if result.stderr:
            print(result.stderr.strip())
        return None

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"Command returned invalid JSON: {' '.join(cmd)}")
        if result.stdout:
            print(result.stdout.strip())
        if result.stderr:
            print(result.stderr.strip())
        return None


def notebook_state(history, notebook_id):
    state = history["notebooks"].setdefault(notebook_id, {})
    state.setdefault("sources", [])
    state.setdefault("chat_count", 0)
    return state


def write_notebook_index(notebook_dir, notebook):
    index_path = os.path.join(notebook_dir, "Notebook.md")
    created_at = notebook.get("created_at", "")
    title = notebook.get("title", "Untitled")
    notebook_id = notebook.get("id", "")
    with open(index_path, "w") as f:
        f.write(
            "---\n"
            "tags: [notebooklm/notebook, notebooklm/sync]\n"
            f"notebooklm_id: {notebook_id}\n"
            f"created_at: {created_at}\n"
            f"last_synced_at: {datetime.now().isoformat(timespec='seconds')}\n"
            "---\n\n"
            f"# {title}\n"
        )


def sync_sources(notebook_id, notebook_title, notebook_dir, state):
    sources_synced = 0
    sources_dir = os.path.join(notebook_dir, "Sources")
    os.makedirs(sources_dir, exist_ok=True)

    print(f"Checking sources: {notebook_title}")
    sources_data = run_cmd([NOTEBOOKLM_BIN, "source", "list", "-n", notebook_id, "--json"])
    if not sources_data or "sources" not in sources_data:
        return 0

    for src in sources_data["sources"]:
        src_id = src["id"]
        title = slug_name(src.get("title", "Untitled"))

        if src_id in state["sources"]:
            continue

        if src.get("status") != "ready":
            print(f" Skipping '{title}' (Status: {src.get('status')})")
            continue

        print(f" Importing source: {notebook_title} / {title}")
        fulltext_data = run_cmd([NOTEBOOKLM_BIN, "source", "fulltext", src_id, "-n", notebook_id, "--json"])
        content = fulltext_data.get("content", "") if fulltext_data else ""

        file_path = os.path.join(sources_dir, f"{title}.md")
        with open(file_path, "w") as f:
            f.write(
                "---\n"
                "tags: [notebooklm/source, notebooklm/sync]\n"
                f"notebooklm_id: {src_id}\n"
                f"notebook_title: {notebook_title}\n"
                f"source_status: {src.get('status', '')}\n"
                f"created_at: {src.get('created_at', '')}\n"
                f"last_synced_at: {datetime.now().isoformat(timespec='seconds')}\n"
                "---\n\n"
                f"# {src.get('title', 'Untitled')}\n\n"
                f"{content}\n"
            )

        state["sources"].append(src_id)
        sources_synced += 1

    return sources_synced


def sync_chat(notebook_id, notebook_title, notebook_dir, state):
    chats_synced = 0
    print(f"Checking chat: {notebook_title}")
    chat_data = run_cmd([NOTEBOOKLM_BIN, "history", "-n", notebook_id, "--json"])
    if not chat_data or "qa_pairs" not in chat_data:
        return 0

    qa_pairs = chat_data["qa_pairs"]
    current_count = len(qa_pairs)
    previous_count = state.get("chat_count", 0)

    if current_count <= previous_count:
        print(" No new chat messages.")
        return 0

    chat_file_path = os.path.join(notebook_dir, "Chat_History.md")
    mode = "a" if os.path.exists(chat_file_path) else "w"
    with open(chat_file_path, mode) as f:
        if mode == "w":
            f.write(
                "---\n"
                "tags: [notebooklm/chat, notebooklm/sync]\n"
                f"notebook_title: {notebook_title}\n"
                f"last_synced_at: {datetime.now().isoformat(timespec='seconds')}\n"
                "---\n\n"
                f"# {notebook_title} Chat History\n\n"
            )

        for pair in qa_pairs[previous_count:]:
            question = pair.get("question", "").strip()
            answer = pair.get("answer", "").strip()
            f.write(f"### User\n{question}\n\n### NotebookLM\n{answer}\n\n---\n\n")
            chats_synced += 1

    state["chat_count"] = current_count
    print(f" Appended {chats_synced} new chat messages.")
    return chats_synced


def main():
    with open(LOCK_FILE, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another NotebookLM sync is already running.")
            return 0

        print("Fetching NotebookLM notebooks...")
        notebooks_data = run_cmd([NOTEBOOKLM_BIN, "list", "--json"])
        if not notebooks_data or "notebooks" not in notebooks_data:
            print("Failed to fetch notebooks. Ensure NotebookLM CLI is authenticated.")
            return 1

        notebooks = notebooks_data["notebooks"]
        if args.notebook_title:
            notebooks = [nb for nb in notebooks if nb.get("title") == args.notebook_title]
            if not notebooks:
                print(f"Notebook '{args.notebook_title}' not found.")
                return 1

        history = load_history()
        total_sources = 0
        total_chats = 0
        notebooks_seen = 0

        for notebook in notebooks:
            notebook_id = notebook["id"]
            notebook_title = notebook.get("title", "Untitled")
            notebook_dir = os.path.join(IMPORT_DIR, slug_name(notebook_title))
            os.makedirs(notebook_dir, exist_ok=True)

            state = notebook_state(history, notebook_id)
            state["title"] = notebook_title
            state["last_seen_at"] = datetime.now().isoformat(timespec="seconds")
            write_notebook_index(notebook_dir, notebook)

            total_sources += sync_sources(notebook_id, notebook_title, notebook_dir, state)
            total_chats += sync_chat(notebook_id, notebook_title, notebook_dir, state)
            notebooks_seen += 1

        save_history(history)
        print(f"Sync complete. {notebooks_seen} notebooks checked, {total_sources} new sources, {total_chats} new chat messages imported.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
