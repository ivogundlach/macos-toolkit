#!/usr/bin/env python3
# SOURCE OF TRUTH. build.sh copies this file into
# "/Applications/Tool Dashboard.app" (or ~/.local/bin). The deployed copy is a
# build artifact: edit THIS file, then run Projects/ToolStatusDashboard/build.sh.
# Editing the deployed copy, or editing here without rebuilding, makes the dashboard
# report stale findings. The "Deployed source drift" check flags that divergence.
"""
tool-status-scan.py

Read-only status inventory for Ivo's local custom tools. By default it uses
local evidence only. Pass --live-auth to run bounded account-backed probes for
tools where "logged in" cannot be proven from disk alone.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


HOME = Path.home()
PATH = f"{HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
STATE = Path(os.environ.get("TOOL_STATUS_STATE", HOME / ".local/state/tool-status-dashboard"))
REGISTRY = STATE / "registry.json"
LOCAL_BIN = HOME / ".local/bin"
REGISTRY_CHECKS = {"exists", "version", "help"}
REGISTRY_DEFAULT_TIMEOUT_SECONDS = 5
REGISTRY_MIN_TIMEOUT_SECONDS = 5
REGISTRY_MAX_TIMEOUT_SECONDS = 30
# Upper bound on registry-driven subprocess checks per scan so registry growth
# cannot make the scan slow or battery-heavy. Entries over budget degrade to
# existence checks for that scan.
MAX_REGISTRY_EXEC_CHECKS = 40
# Count alone cannot bound runtime once individual entries may request longer
# checks. Stop starting registry probes after 90 seconds of actual elapsed time,
# leaving 30 seconds for the outer scan's built-in checks. Fast probes therefore
# do not consume their full theoretical timeout ceiling.
REGISTRY_EXEC_TIMEOUT_BUDGET_SECONDS = 90
# Binaries already covered by a built-in record. Registry entries and discovery
# must not duplicate them.
BUILTIN_BINARIES = {
    "agy", "gws", "codex", "claude", "gemini", "notebooklm", "apfel",
    "last30days", "semantic-corpus", "school-mail", "studykit", "swift-smoke",
    "codex-sync-verify", "codex-to-claude-sync", "semantic-index-status",
    "apple-mail-draft-runner", "quit-on-close",
    "smart-wake", "uv", "uvx",
}


def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def output_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def run(cmd: list[str], timeout: int = 8) -> tuple[int, str]:
    try:
        result = subprocess.run(
            cmd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
            env={**os.environ, "PATH": PATH},
        )
        text = (output_text(result.stdout) + "\n" + output_text(result.stderr)).strip()
        return result.returncode, text
    except subprocess.TimeoutExpired as exc:
        # Python can expose partial timeout output as bytes even with text=True.
        text = (output_text(exc.stdout) + "\n" + output_text(exc.stderr)).strip()
        return 124, f"Timed out after {timeout}s. {text}".strip()
    except FileNotFoundError:
        return 127, "Command not found"
    except Exception as exc:
        return 1, f"{type(exc).__name__}: {exc}"


def clip(text: str, limit: int = 420) -> str:
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= limit else text[: limit - 3] + "..."


def rec(
    rows: list[dict[str, Any]],
    name: str,
    category: str,
    state: str,
    headline: str,
    detail: str = "",
    evidence: str = "",
    fix: dict[str, Any] | None = None,
    cause_code: str | None = None,
    notification_policy: str = "consecutive",
    deadline_at: str | None = None,
    cause_params: dict[str, str] | None = None,
    record_id: str | None = None,
    self_healing: bool = False,
    owner: str | None = None,
    needs_ivo: bool = False,
) -> None:
    rows.append(
        {
            "id": record_id or f"{category}:{name}",
            "name": name,
            "category": category,
            "state": state,
            "headline": headline,
            "detail": detail,
            "evidence": evidence,
            "checkedAt": now_iso(),
            "fix": fix,
            "causeCode": cause_code or (f"generic.{state}" if state in {"warn", "fail"} else None),
            "causeParams": cause_params or {},
            "notificationPolicy": notification_policy,
            "deadlineAt": deadline_at,
            # True == a self-healing condition (usage limits, transient network /
            # timeout). Tracked and rendered for awareness but not escalated to
            # autonomous repair / push while it is still clearing; if it never
            # clears within the grace window it escalates like any real failure.
            "selfHealing": bool(self_healing),
            # Which project's source can actually remediate this row. The repair
            # worker derives write scope from the incident's display name, but a
            # self-check is named after what it inspects ("process scan"), not
            # after the code that owns it -- so the dashboard could never
            # autonomously repair its own checks and every one of them stalled
            # on a manual approval. Set this ONLY where the named project's
            # source is genuinely the fix; it grants write authority.
            "owner": owner,
            # True == no agent can resolve this; it records something that already
            # happened and only Ivo can close. Queuing such a row for autonomous
            # repair produces an endless retry against an unfixable past event and
            # an Approve button that cannot possibly work.
            "needsIvo": bool(needs_ivo),
        }
    )


def fix_auto(label: str, command: list[str], note: str = "") -> dict[str, Any]:
    """Safe, non-interactive remediation the app may run directly."""
    return {"label": label, "kind": "auto", "command": command, "note": note}


def fix_manual(label: str, note: str, command: list[str] | None = None) -> dict[str, Any]:
    """Guidance only — interactive, risky, or quota-consuming. Never auto-run."""
    return {"label": label, "kind": "manual", "command": command, "note": note}


def fix_launch(label: str, note: str, command: list[str], cwd: str | None = None) -> dict[str, Any]:
    """An interactive login the app opens in Terminal for Ivo to COMPLETE himself
    (OAuth / browser sign-in). One click, no copy-paste, no 'run this yourself'.
    The app only launches the flow; it never types credentials. command/cwd must be
    shell-safe (no quotes/spaces-in-paths) since they run from a generated script."""
    fix = {"label": label, "kind": "launch", "command": command, "note": note}
    if cwd:
        fix["cwd"] = cwd
    return fix


def which(name: str) -> str | None:
    return shutil.which(name, path=PATH)


def command_record(
    rows: list[dict[str, Any]],
    name: str,
    binary: str,
    version_cmd: list[str] | None = None,
    category: str = "CLI",
    missing_fix: dict[str, Any] | None = None,
) -> str | None:
    path = which(binary)
    if not path:
        fix = missing_fix or fix_manual(
            "Locate binary",
            f"{binary} is not on PATH. Expected in ~/.local/bin or Homebrew; restore or reinstall it, then Refresh.",
        )
        rec(rows, name, category, "fail", "Not installed", f"{binary} is not on PATH", fix=fix)
        return None
    detail = path
    if version_cmd:
        rc, out = run(version_cmd, timeout=5)
        if rc == 0 and out:
            detail = f"{path} - {clip(out, 140)}"
    rec(rows, name, category, "ok", "Installed", detail)
    return path


def auth_records(rows: list[dict[str, Any]], live_auth: bool) -> None:
    agy_path = command_record(rows, "AGY / Antigravity CLI", "agy", ["agy", "--help"], "Auth")
    if agy_path:
        if live_auth:
            rc, out = run(
                ["agy", "-p", "reply with the single word READY", "--print-timeout", "30s"],
                timeout=50,
            )
            bad = rc != 0 or not out.strip() or any(
                token in out.lower()
                for token in ("authentication required", "visit the url", "log in:")
            )
            rec(
                rows,
                "AGY live login",
                "Auth",
                "fail" if bad else "ok",
                "Not logged in" if bad else "Logged in",
                clip(out),
                "agy -p READY",
                fix=fix_launch(
                    "Log in to AGY",
                    "Opens the AGY interactive sign-in in Terminal. Finish it, then Refresh.",
                    ["agy", "-i"],
                ) if bad else None,
            )
        else:
            rec(
                rows,
                "AGY live login",
                "Auth",
                "unknown",
                "Live auth not probed",
                "Press Run Live Auth to test AGY without guessing from old logs.",
            )

    gws_path = command_record(rows, "Google Workspace CLI", "gws", ["gws", "--help"], "Auth")
    gws_login_helper = Path(__file__).with_name("gws-auth-login.py")
    gws_login_command = [
        "/usr/bin/python3",
        str(gws_login_helper),
        "--gws-bin",
        gws_path,
    ] if gws_path else ["gws", "auth", "login"]
    gws_dir = HOME / ".config" / "gws"
    gws_files = {
        "client_secret.json": (gws_dir / "client_secret.json").exists(),
        "credentials.enc": (gws_dir / "credentials.enc").exists(),
        "token_cache.json": (gws_dir / "token_cache.json").exists(),
    }
    if gws_path:
        if all(gws_files.values()):
            rec(rows, "GWS local credentials", "Auth", "ok", "Credential files present", ", ".join(gws_files))
        else:
            missing = [name for name, present in gws_files.items() if not present]
            rec(
                rows,
                "GWS local credentials",
                "Auth",
                "warn",
                "Credential files incomplete",
                ", ".join(missing),
                # Only the token cache missing = a plain re-login. A missing client
                # secret / encrypted credential means the OAuth client itself needs
                # setting up. Either way it is one click, never copy-paste guidance.
                fix=fix_launch(
                    "Set up Google access" if not (gws_files["client_secret.json"] and gws_files["credentials.enc"])
                    else "Log in to Google",
                    f"Missing in ~/.config/gws: {', '.join(missing)}. Opens the gws OAuth "
                    + ("setup" if not (gws_files["client_secret.json"] and gws_files["credentials.enc"]) else "sign-in")
                    + " in Terminal. Finish it, then Refresh.",
                    ["gws", "auth", "setup"]
                    if not (gws_files["client_secret.json"] and gws_files["credentials.enc"])
                    else gws_login_command,
                ),
            )
        if live_auth:
            rc, out = run(
                [
                    "gws",
                    "drive",
                    "files",
                    "list",
                    "--params",
                    '{"pageSize":1,"fields":"files(id)"}',
                ],
                timeout=25,
            )
            state = "ok" if rc == 0 else ("fail" if rc == 2 else "warn")
            rec(
                rows,
                "GWS live login",
                "Auth",
                state,
                "Logged in" if rc == 0 else f"Probe failed rc={rc}",
                clip(out),
                "gws drive files list pageSize=1",
                fix=fix_launch(
                    "Log in to Google",
                    "Opens Google sign-in in your browser. Finish it, then Refresh.",
                    gws_login_command,
                ) if rc != 0 else None,
            )
        else:
            rec(rows, "GWS live login", "Auth", "unknown", "Live auth not probed")

    command_record(rows, "Codex CLI", "codex", ["codex", "--version"], "Auth")
    codex_auth = (HOME / ".codex" / "auth.json").exists()
    rec(
        rows,
        "Codex local auth",
        "Auth",
        "ok" if codex_auth else "warn",
        "Auth file present" if codex_auth else "No auth file found",
        "~/.codex/auth.json",
        fix=None if codex_auth else fix_launch(
            "Log in to Codex", "Opens Codex sign-in in Terminal. Finish it, then Refresh.",
            ["codex", "login"],
        ),
    )

    command_record(rows, "Claude Code CLI", "claude", ["claude", "--version"], "Auth")
    rec(
        rows,
        "Claude local config",
        "Auth",
        "ok" if (HOME / ".claude" / "settings.json").exists() else "unknown",
        "Config present" if (HOME / ".claude" / "settings.json").exists() else "No config found",
        "~/.claude/settings.json",
    )

    command_record(rows, "Gemini CLI", "gemini", ["gemini", "--version"], "Auth")
    rec(
        rows,
        "Gemini local config",
        "Auth",
        "ok" if (HOME / ".gemini" / "config" / "config.json").exists() else "unknown",
        "Config present" if (HOME / ".gemini" / "config" / "config.json").exists() else "No config found",
        "~/.gemini/config/config.json",
    )

    command_record(rows, "NotebookLM CLI", "notebooklm", ["notebooklm", "--version"], "Auth")
    storage = HOME / ".notebooklm" / "profiles" / "default" / "storage_state.json"
    rec(
        rows,
        "NotebookLM local session",
        "Auth",
        "ok" if storage.exists() else "warn",
        "Storage state present" if storage.exists() else "No storage state found",
        str(storage),
        fix=None if storage.exists() else fix_launch(
            "Log in to NotebookLM",
            "Opens NotebookLM sign-in in your browser. Finish it, then Refresh.",
            ["notebooklm", "login"],
        ),
    )
    if live_auth and which("notebooklm"):
        rc, out = run(["notebooklm", "doctor", "--json"], timeout=20)
        state = "ok" if rc == 0 else "warn"
        rec(
            rows,
            "NotebookLM doctor",
            "Auth",
            state,
            "Doctor passed" if rc == 0 else f"Doctor rc={rc}",
            clip(out),
            fix=fix_auto(
                "Re-run doctor",
                ["notebooklm", "doctor"],
                "Doctor is a read-only diagnostic; a transient network blip can fail it (known: outages get mislabeled as auth expiry).",
            ) if rc != 0 else None,
        )
    elif which("notebooklm"):
        rec(rows, "NotebookLM doctor", "Auth", "unknown", "Live auth not probed")

    command_record(rows, "Apfel", "apfel", ["apfel", "--version"], "Auth")
    if which("apfel"):
        rc, out = run(["apfel", "--model-info"], timeout=10)
        rec(
            rows,
            "Apfel model availability",
            "Auth",
            "ok" if rc == 0 else "warn",
            "Apple Intelligence available" if rc == 0 else f"Model info rc={rc}",
            clip(out),
        )


def cli_records(rows: list[dict[str, Any]]) -> None:
    tools = [
        ("last30days", "last30days"),
        ("semantic-corpus", "semantic-corpus"),
        ("school-mail", "school-mail"),
        ("studykit", "studykit"),
        ("swift-smoke", "swift-smoke"),
        ("codex-sync-verify", "codex-sync-verify"),
        ("codex-to-claude-sync", "codex-to-claude-sync"),
        ("semantic-index-status", "semantic-index-status"),
        ("apple-mail-draft-runner", "apple-mail-draft-runner"),
        ("quit-on-close", "quit-on-close"),
        ("smart-wake", "smart-wake"),
        ("uv", "uv", ["uv", "--version"]),
        ("uvx", "uvx", ["uvx", "--version"]),
    ]
    uv_fix = fix_manual("Install uv", "Installs uv (provides uvx too).", ["brew", "install", "uv"])
    for item in tools:
        name, binary, *version = item
        command_record(
            rows,
            name,
            binary,
            version[0] if version else None,
            "Custom CLI",
            missing_fix=uv_fix if binary in ("uv", "uvx") else None,
        )


def executable_on_disk(binary: str) -> str | None:
    """Resolve a registered binary: PATH lookup first, then ~/.local/bin.

    Symlinks count when they resolve to an executable regular file.
    """
    found = which(binary)
    if found:
        return found
    candidate = LOCAL_BIN / binary
    try:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    except OSError:
        pass
    return None


# A tool that never implemented the probe flag exits nonzero for a reason that
# says nothing about its health. Crashes look different: a missing interpreter or
# library gives 126/127, and a broken program gives a traceback or a signal.
UNSUPPORTED_PROBE_TEXT = re.compile(
    r"(?i)\b(unknown|unrecognized|invalid|illegal)\s+(argument|option|flag|command|switch)"
    r"|\busage\s*:|\bunknown\s+arg\b|--help'? for (more )?(information|usage)"
)


def unsupported_probe(rc_code: int, output: str) -> bool:
    """True when the nonzero exit means "no such flag", not "this tool is broken"."""
    if rc_code in (126, 127) or rc_code < 0:
        return False
    if re.search(r"(?i)traceback \(most recent call last\)|command not found|no such file", output):
        return False
    return bool(UNSUPPORTED_PROBE_TEXT.search(output))


def registry_records(rows: list[dict[str, Any]]) -> set[str]:
    """Render one row per registry entry. Returns the set of covered binaries."""
    covered: set[str] = set(BUILTIN_BINARIES)
    if not REGISTRY.exists():
        return covered
    try:
        data = json.loads(REGISTRY.read_text(encoding="utf-8"))
        tools = data["tools"]
        if not isinstance(tools, list):
            raise ValueError("registry 'tools' must be a list")
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        rec(
            rows, "Tool Registry", "Custom CLI", "warn",
            "Registry file is unreadable",
            f"{REGISTRY}: {type(exc).__name__}: {exc}. Auto-registration is paused until it parses.",
            cause_code="registry.malformed",
            fix=fix_manual(
                "Repair registry",
                "Fix or delete the JSON file; the next background scan re-registers discovered tools.",
                ["cat", str(REGISTRY)],
            ),
        )
        return covered
    invalid: list[str] = []
    exec_budget = MAX_REGISTRY_EXEC_CHECKS
    timeout_deadline = time.monotonic() + REGISTRY_EXEC_TIMEOUT_BUDGET_SECONDS
    # When the elapsed-time deadline is reached, rotate probe priority once per
    # normal five-minute scan bucket so a perpetually slow registry cannot leave
    # the same trailing tool untested forever. No cursor file is needed, keeping
    # the scanner itself read-only.
    rotation = int(time.time() // 300) % len(tools) if tools else 0
    ordered_tools = tools[rotation:] + tools[:rotation]
    for entry in ordered_tools:
        if not isinstance(entry, dict):
            invalid.append(repr(entry)[:60])
            continue
        binary = entry.get("binary")
        if not isinstance(binary, str) or not binary or "/" in binary:
            invalid.append(str(binary)[:60])
            continue
        if binary in covered:
            continue
        covered.add(binary)
        name = entry.get("name") if isinstance(entry.get("name"), str) else binary
        check = entry.get("check") if entry.get("check") in REGISTRY_CHECKS else "exists"
        timeout_seconds = entry.get("timeoutSeconds", REGISTRY_DEFAULT_TIMEOUT_SECONDS)
        if (
            isinstance(timeout_seconds, bool)
            or not isinstance(timeout_seconds, int)
            or not REGISTRY_MIN_TIMEOUT_SECONDS <= timeout_seconds <= REGISTRY_MAX_TIMEOUT_SECONDS
        ):
            invalid.append(f"{binary}: timeoutSeconds={timeout_seconds!r}")
            continue
        auto = entry.get("addedBy") == "auto"
        path = executable_on_disk(binary)
        if path is None:
            if auto:
                # Auto-discovered inventory: a vanished binary is usually an
                # intentional uninstall. Stay out of the incident pipeline; the
                # background scan deregisters it after two consecutive misses.
                rec(
                    rows, name, "Custom CLI", "unknown",
                    "Binary missing; pending auto-deregistration",
                    f"{binary} was auto-registered from ~/.local/bin but is no longer present.",
                )
            else:
                rec(
                    rows, name, "Custom CLI", "fail",
                    "Not installed",
                    f"{binary} was registered via tool-status-register but is not on PATH or in ~/.local/bin.",
                    cause_code="registry.binary_missing",
                    fix=fix_manual(
                        "Restore or deregister",
                        f"Reinstall {binary}, or remove it: tool-status-register remove {binary}",
                    ),
                )
            continue
        detail = path
        timeout_remaining = timeout_deadline - time.monotonic()
        if check != "exists" and exec_budget > 0 and timeout_seconds <= timeout_remaining:
            exec_budget -= 1
            flag = "--version" if check == "version" else "--help"
            rc_code, out = run([binary, flag], timeout=timeout_seconds)
            if rc_code != 0 and unsupported_probe(rc_code, out):
                # Try the other probe before concluding anything: auto-registration
                # guesses a flag, and a tool that never implemented it is not broken.
                alternate = "--help" if flag == "--version" else "--version"
                alt_rc, alt_out = run([binary, alternate], timeout=timeout_seconds)
                if alt_rc == 0:
                    flag, rc_code, out = alternate, alt_rc, alt_out
                elif unsupported_probe(alt_rc, alt_out):
                    # Neither probe is implemented. That is a fact about the
                    # registry entry, not about the tool, so it must never become
                    # an incident or a notification. app-repo-bootstrap -- a
                    # one-time script with no flag parsing -- produced 256
                    # consecutive "failures" this way.
                    rec(
                        rows, name, "Custom CLI", "unknown",
                        "No health check available",
                        f"{path} implements neither --version nor --help, so its registry "
                        f"check cannot report health. Set it to 'exists': "
                        f"tool-status-register set {binary} --check exists",
                    )
                    continue
            if rc_code != 0:
                rec(
                    rows, name, "Custom CLI", "warn",
                    f"Health check failed ({flag} rc={rc_code})",
                    f"{path} - {clip(out, 220)}",
                    cause_code="registry.health_check_failed",
                )
                continue
            detail = f"{path} - {clip(out, 140)}"
        elif check != "exists":
            rec(
                rows, name, "Custom CLI", "unknown",
                "Health check deferred by scan budget",
                f"{path} exists, but its {check} check was not run in this scan.",
            )
            continue
        rec(rows, name, "Custom CLI", "ok", "Installed", detail)
    if invalid:
        rec(
            rows, "Tool Registry entries", "Custom CLI", "warn",
            f"{len(invalid)} invalid registry entries",
            "Invalid: " + ", ".join(invalid[:10]),
            cause_code="registry.invalid_entries",
            fix=fix_manual("Repair entries", f"Edit {REGISTRY} or use tool-status-register."),
        )
    return covered


def discover_unregistered(covered: set[str]) -> list[str]:
    """Executables in ~/.local/bin with no built-in or registry coverage."""
    found: list[str] = []
    try:
        entries = sorted(LOCAL_BIN.iterdir())
    except OSError:
        return found
    for path in entries:
        if path.name.startswith(".") or path.name in covered:
            continue
        try:
            if path.is_file() and os.access(path, os.X_OK):
                found.append(path.name)
        except OSError:
            continue
    return found


def registry_coverage_record(rows: list[dict[str, Any]], unregistered: list[str]) -> None:
    if unregistered:
        rec(
            rows, "Registry coverage", "Custom CLI", "unknown",
            f"{len(unregistered)} tools await auto-registration",
            "Unregistered: " + ", ".join(unregistered[:15]),
        )
    else:
        rec(
            rows, "Registry coverage", "Custom CLI", "ok",
            "Every ~/.local/bin executable is monitored",
            f"Registry: {REGISTRY}",
        )


def launchctl_job(label: str) -> dict[str, str] | None:
    rc, out = run(["launchctl", "print", f"gui/{os.getuid()}/{label}"], timeout=8)
    if rc != 0:
        return None
    fields: dict[str, str] = {}
    for key in ("state", "runs", "pid", "last exit code", "program"):
        match = re.search(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$", out, re.MULTILINE)
        if match:
            fields[key] = match.group(1)
    return fields


def _json_rc_ok(text: str) -> bool:
    return str(json.loads(text).get("overall_rc")) == "0"


def _tsv_result_verified(text: str) -> bool:
    for line in text.splitlines():
        key, _, value = line.partition("\t")
        if key == "last_result":
            return value.strip() == "verified"
    return False


# launchd's LastExitStatus is a fact about launchd's own last invocation, and it
# never changes when the job is run by hand or by another path. A job fixed and
# re-run successfully at 02:08 therefore keeps reporting the 16:30 failure until
# its next scheduled tick -- days of a card that is simply wrong, and a repair
# worker sent to fix something already fixed.
#
# Where a job keeps its OWN authoritative record of how it went, that record wins
# whenever it is newer than launchd's log output. Adding a job here is one line:
# its status file and the predicate that reads success out of it.
SELF_REPORTED_STATUS: dict[str, tuple[Path, Any]] = {
    "com.ivogundlach.memory.semantic-index": (
        HOME / ".memory" / "semantic-index-status.json", _json_rc_ok),
    "com.ivogundlach.personal-repo-sync": (
        HOME / ".local/state/personal-repo-sync/status.tsv", _tsv_result_verified),
}


DECLARED_PORT = re.compile(r"--port[=\s]+(\d{2,5})\b")


def declared_port_serving(data: dict[str, Any]) -> tuple[bool, str]:
    """True when the job declares a port and that port is actually being served.

    A KeepAlive service can be perfectly healthy while launchd records a nonzero
    exit: the supervised wrapper notices an instance is already running, refuses
    to start a second one, and exits 1. launchd then reports "last exit code = 1"
    forever while the service happily serves traffic. com.opencodex.proxy sat in
    that state for 115 consecutive scans -- alive on port 10100 the whole time.
    Where the job names the port it serves, serving that port is the better
    evidence, so it wins over launchd's bookkeeping.
    """
    arguments = data.get("ProgramArguments")
    if not isinstance(arguments, list):
        return False, ""
    match = DECLARED_PORT.search(" ".join(str(value) for value in arguments))
    if not match:
        return False, ""
    port = int(match.group(1))
    if not 1 <= port <= 65535:
        return False, ""
    for family, address in ((socket.AF_INET, ("127.0.0.1", port)), (socket.AF_INET6, ("::1", port))):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as probe:
                probe.settimeout(0.4)
                if probe.connect_ex(address) == 0:
                    return True, f"declared port {port} is being served"
        except OSError:
            continue
    return False, ""


def newer_success_status(label: str, data: dict[str, Any]) -> tuple[bool, str]:
    entry = SELF_REPORTED_STATUS.get(label)
    if entry is None:
        return False, ""
    status_path, succeeded = entry
    if not status_path.exists():
        return False, ""
    try:
        if not succeeded(status_path.read_text(encoding="utf-8")):
            return False, ""
        output_paths = [data.get("StandardErrorPath"), data.get("StandardOutPath")]
        output_mtime = max(
            (Path(path).stat().st_mtime for path in output_paths if path and Path(path).exists()),
            default=0,
        )
        if status_path.stat().st_mtime >= output_mtime:
            return True, f"later successful status: {status_path}"
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    return False, ""


def launch_agent_records(rows: list[dict[str, Any]]) -> None:
    agents_dir = HOME / "Library" / "LaunchAgents"
    for plist_path in sorted(agents_dir.glob("*.plist")):
        try:
            data = plistlib.loads(plist_path.read_bytes())
        except Exception as exc:
            rec(
                rows,
                plist_path.name,
                "LaunchAgent",
                "fail",
                "Unreadable plist",
                str(exc),
                fix=fix_auto("Lint plist", ["plutil", "-lint", str(plist_path)], "Shows the exact parse error."),
            )
            continue
        # Some installers leave empty plists as migration tombstones; they do
        # not define a launchd job and must not be treated as one.
        if data == {}:
            continue
        if not isinstance(data, dict):
            rec(
                rows,
                plist_path.name,
                "LaunchAgent",
                "fail",
                "Invalid plist structure",
                "The plist root must be a dictionary.",
                str(plist_path),
                cause_code="launchagent.invalid_plist_structure",
                notification_policy="immediate",
            )
            continue
        label = data.get("Label", plist_path.stem)
        # Market has a contract-level health adapter below. Avoid a second row
        # and duplicate incident for the same scheduler.
        if label == "com.ivo.market.refresh":
            continue
        program = data.get("Program")
        args = data.get("ProgramArguments") or []
        executable = Path(program or (args[0] if args else ""))
        exists = executable.exists() if str(executable) else False
        job = launchctl_job(label)
        running = bool(job and job.get("state") == "running")
        last_exit = job.get("last exit code") if job else None
        superseded, superseded_evidence = newer_success_status(label, data)
        if not superseded:
            superseded, superseded_evidence = declared_port_serving(data)
        fix = None
        if not exists:
            state = "fail"
            headline = "Executable path missing"
            cause_code = "launchagent.executable_missing"
            policy = "immediate"
            fix = fix_manual(
                "Repair path",
                f"{executable} does not exist. Restore the binary or update the plist, then Refresh.",
            )
        elif running:
            state = "ok"
            headline = "Running"
            cause_code = None
            policy = "consecutive"
        elif job is None:
            state = "fail"
            headline = "Not loaded"
            cause_code = "launchagent.not_loaded"
            policy = "immediate"
            fix = fix_auto(
                "Load now",
                ["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist_path)],
                "Loads the agent for this login session.",
            )
        elif last_exit and last_exit not in {"0", "(never exited)"} and label in {
            "com.ivogundlach.memory.semantic-index"
        }:
            state = "ok"
            headline = "Loaded / health adapter active"
            cause_code = None
            policy = "consecutive"
        elif last_exit and last_exit not in {"0", "(never exited)"} and not superseded:
            state = "warn"
            headline = "Last run failed"
            cause_code = "launchagent.last_run_failed"
            policy = "consecutive"
            fix = fix_auto(
                "Run again",
                ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"],
                "Runs the existing agent again. Review its output paths below if it fails.",
            )
        else:
            state = "ok"
            headline = "Loaded / idle"
            cause_code = None
            policy = "consecutive"
        schedule = []
        if data.get("RunAtLoad"):
            schedule.append("RunAtLoad")
        if data.get("StartInterval"):
            schedule.append(f"every {data['StartInterval']}s")
        job_detail = ", ".join(f"{key}={value}" for key, value in (job or {}).items()) or "not loaded"
        output_paths = [path for path in (data.get("StandardOutPath"), data.get("StandardErrorPath")) if path]
        detail = f"{job_detail}; {'; '.join(schedule) or 'manual/other trigger'}"
        if superseded_evidence:
            detail += f"; {superseded_evidence}"
        rec(
            rows,
            label,
            "LaunchAgent",
            state,
            headline,
            detail,
            " | ".join([str(plist_path), *output_paths]),
            fix=fix,
            cause_code=cause_code,
            notification_policy=policy,
            cause_params={"label": label},
        )


def crontab_lines() -> tuple[int, list[str], str]:
    rc, out = run(["crontab", "-l"], timeout=8)
    return (rc, out.splitlines() if rc == 0 else [], out)


def cron_command(line: str) -> str | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", stripped):
        return None
    try:
        parts = shlex.split(stripped, comments=False, posix=True)
    except ValueError:
        return None
    offset = 1 if parts and parts[0].startswith("@") else 5
    if len(parts) <= offset:
        return None
    while offset < len(parts) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", parts[offset]):
        offset += 1
    if len(parts) <= offset:
        return None
    token = parts[offset]
    if token in {"cd", "env", "bash", "sh", "zsh"}:
        return None
    return token


def cron_records(rows: list[dict[str, Any]]) -> None:
    rc, lines, evidence = crontab_lines()
    if rc != 0:
        rec(
            rows, "User crontab", "Background Job", "fail", "Crontab cannot be read",
            clip(evidence), "crontab -l",
            fix=fix_manual("Inspect crontab", "Run `crontab -l` in Terminal and repair the reported access or parse error."),
            cause_code="cron.unreadable", notification_policy="immediate",
        )
        return

    active = [line for line in lines if line.strip() and not line.lstrip().startswith("#")]
    rec(rows, "User crontab", "Background Job", "ok", f"{len(active)} active entries", "crontab -l")
    for index, line in enumerate(lines, start=1):
        command = cron_command(line)
        if command is None:
            continue
        tag = line.split("#", 1)[1].strip() if "#" in line else ""
        if "claude-window-keeper" in line:
            name = "Claude Window Keeper"
        elif "codex-auto-reset --schedule" in line:
            name = "Codex Auto Reset Scheduler"
        elif "codex-auto-reset" in line:
            target = re.search(r"codex-auto-reset-target:(\d+)", line)
            name = f"Codex Auto Reset Target {target.group(1) if target else index}"
        else:
            name = tag or f"Cron job line {index}"
        if command.startswith(("/", "~")):
            resolved = Path(command).expanduser()
            exists = resolved.exists()
        else:
            resolved_binary = which(command)
            resolved = Path(resolved_binary) if resolved_binary else Path(command)
            exists = bool(resolved_binary)
        if not exists:
            rec(
                rows, name, "Background Job", "warn", "Scheduled command is missing",
                f"Line {index}: {line}", "crontab -l",
                fix=fix_manual("Repair cron command", f"Restore `{command}` or update only this crontab entry."),
                cause_code="cron.command_missing", notification_policy="consecutive",
                cause_params={"command": command},
            )
        else:
            rec(rows, name, "Background Job", "ok", "Scheduled", f"Line {index}: {line}", str(resolved))

    keeper_cron_scheduled = any("claude-window-keeper" in line and not line.lstrip().startswith("#") for line in lines)
    keeper_launch_job = launchctl_job("com.ivogundlach.claude-window-keeper")
    keeper_scheduled = keeper_cron_scheduled or keeper_launch_job is not None
    token = HOME / ".local/state/claude-window-keeper/claude-oauth-token"
    token_ok = token.is_file() and token.stat().st_size > 0 and (token.stat().st_mode & 0o077) == 0
    keeper_log = HOME / ".local/state/claude-window-keeper/keeper.log"
    uses_keychain = keeper_launch_job is not None
    auth_fix = fix_launch(
        "Log in to Claude",
        "Opens the Claude sign-in in Terminal. Finish it, then Refresh — the keeper picks it up on its next tick.",
        ["claude", "auth", "login"],
    )
    if keeper_cron_scheduled and not uses_keychain and not token_ok:
        rec(
            rows, "Claude Window Keeper", "Background Job", "fail",
            "Claude authentication is not configured",
            "The scheduled keeper cannot start Claude usage windows. Its token file is missing, empty, or not private (required mode: 600).",
            str(keeper_log),
            fix=auth_fix,
            cause_code="claude_keeper.auth_missing", notification_policy="immediate",
            record_id="Background Job:Claude Window Keeper Authentication",
        )
    elif keeper_scheduled:
        try:
            latest = next(
                (line for line in reversed(keeper_log.read_text(encoding="utf-8", errors="replace").splitlines())
                 if " claude ping " in line),
                "",
            )
            log_predates_auth = not uses_keychain and keeper_log.stat().st_mtime < token.stat().st_mtime
        except OSError:
            latest = ""
            log_predates_auth = True
        keeper_self_healing = False
        if not latest or log_predates_auth:
            state, headline = "warn", "Claude authentication is waiting for verification"
            cause_code, policy, fix = "claude_keeper.unverified", "consecutive", auth_fix
        elif " ping ok " in f" {latest} ":
            state, headline = "ok", "Claude authentication and live ping are verified"
            cause_code, policy, fix = None, "consecutive", None
        elif any(marker in latest.lower() for marker in ("not logged in", "oauth", "authentication", "token")):
            state, headline = "fail", "Claude rejected the keeper authentication"
            cause_code, policy, fix = "claude_keeper.auth_rejected", "immediate", auth_fix
        elif any(marker in latest.lower() for marker in (
            "session limit", "usage limit", "weekly limit", "usage credits", "monthly spend",
        )):
            # Expected and self-healing: the account is out of usage. The keeper is
            # healthy and correctly waits for the reset boundary; nothing to repair,
            # so this is a green, non-escalating state (not a failure).
            state, headline = "ok", "Claude usage temporarily exhausted; keeper resumes at reset"
            cause_code, policy, fix = None, "consecutive", None
        else:
            # An unrecognized ping outcome: transient network/service, or a timeout
            # (e.g. rc=142). Shown for awareness but self-healing -- the keeper retries
            # every ten minutes and only genuine auth problems (handled above) are
            # actionable, so this must never escalate to autonomous repair or a push.
            state, headline = "warn", "Claude Window Keeper ping is retrying"
            cause_code, policy, fix = "claude_keeper.ping_retrying", "consecutive", fix_manual(
                "Inspect only if persistent",
                "Usually transient (network, service, or a ping timeout); the keeper retries every ten minutes. Run `claude-window-keeper` once in Terminal only if this persists for hours.",
                [str(HOME / ".local/bin/claude-window-keeper")],
            )
            keeper_self_healing = True
        rec(
            rows, "Claude Window Keeper", "Background Job", state, headline,
            ("Aqua LaunchAgent using Claude's normal user-session authentication. " if uses_keychain else "Cron using a private long-lived token. ")
            + (latest or "No Claude keeper result has been recorded since authentication was configured."),
            str(keeper_log), fix=fix,
            cause_code=cause_code, notification_policy=policy,
            record_id="Background Job:Claude Window Keeper Authentication",
            self_healing=keeper_self_healing,
        )


def semantic_index_records(rows: list[dict[str, Any]]) -> None:
    def load_json(path: Path) -> dict[str, Any] | None:
        try:
            return json.loads(path.read_text())
        except Exception:
            return None

    rebuild_fix = fix_manual(
        "Rebuild semantic index",
        "Runs the semantic index build now. Can take a while and consume Gemini (agy) quota — run when acceptable.",
        [str(HOME / ".local" / "bin" / "semantic-index-retry"), "--semantic-only"],
    )

    for label, path, max_days in [
        ("Semantic index (memory)", HOME / ".memory" / "semantic-index-status.json", 2),
    ]:
        data = load_json(path)
        if not data:
            rec(
                rows, label, "Pipeline", "fail", "Pipeline status is missing", str(path), fix=rebuild_fix,
                cause_code="pipeline.status_missing", notification_policy="immediate",
            )
            continue
        finished = data.get("finished") or data.get("started") or ""
        state = "ok" if str(data.get("overall_rc")) == "0" else "fail"
        try:
            parsed = dt.datetime.fromisoformat(re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", finished))
            age_days = (dt.datetime.now(parsed.tzinfo) - parsed).total_seconds() / 86400
            if age_days > max_days and state == "ok":
                state = "warn"
            headline = "Pipeline is overdue" if state == "warn" else (
                "Last pipeline run failed" if state == "fail" else "Pipeline is current"
            )
            timing_detail = f"rc={data.get('overall_rc')} finished {age_days:.1f}d ago"
        except Exception:
            headline = "Last pipeline run failed" if state == "fail" else "Pipeline status timestamp is invalid"
            timing_detail = f"rc={data.get('overall_rc')}"
        rec(
            rows,
            label,
            "Pipeline",
            state,
            headline,
            f"{timing_detail}; model={data.get('model', '?')} phase={data.get('phase', '?')}",
            str(path),
            fix=rebuild_fix if state != "ok" else None,
            cause_code=("pipeline.run_failed" if state == "fail" else "pipeline.overdue") if state != "ok" else None,
            notification_policy="consecutive",
        )

    db = HOME / ".memory" / "semantic-index.sqlite"
    if db.exists():
        try:
            conn = sqlite3.connect(f"file:{db}?immutable=1", uri=True)
            count = conn.execute("SELECT COUNT(*) FROM docs").fetchone()[0]
            conn.close()
            rec(rows, "Global semantic index", "Pipeline", "ok", f"{count} records", str(db))
        except Exception as exc:
            rec(rows, "Global semantic index", "Pipeline", "warn", "DB read failed", str(exc), str(db))
    else:
        rec(rows, "Global semantic index", "Pipeline", "fail", "DB missing", str(db), fix=rebuild_fix)

    # Retrieval QUALITY, as distinct from liveness. Everything above proves the
    # index is fresh and readable; none of it proves a question still finds its
    # answer. memory-retrieval-eval scores a gold set weekly and leaves its result
    # here, so a ranking or enrichment regression shows up as a card instead of as
    # searches that quietly stop working.
    eval_state = HOME / ".local" / "state" / "memory-retrieval-eval" / "last-run.json"
    eval_fix = fix_manual(
        "Re-run retrieval eval",
        "Scores ~/.memory/evals/retrieval-gold.jsonl against the live index. "
        "Read-only: runs queries, writes no memory.",
        [str(HOME / ".local" / "bin" / "memory-retrieval-eval")],
    )
    data = load_json(eval_state)
    if not data:
        # Absent is not failing: the weekly job may simply not have run yet.
        rec(rows, "Memory retrieval quality", "Pipeline", "unknown",
            "No eval result yet", str(eval_state), fix=eval_fix)
    else:
        r1 = data.get("recall_at_1")
        r5 = data.get("recall_at_5")
        thr = data.get("threshold")
        stale_days = None
        try:
            stale_days = (dt.datetime.now() - dt.datetime.fromtimestamp(
                eval_state.stat().st_mtime)).total_seconds() / 86400
        except Exception:
            pass
        passed = bool(data.get("pass"))
        if stale_days is not None and stale_days > 14:
            state, headline = "warn", "Eval result is stale"
        elif passed:
            state, headline = "ok", "Retrieval meets the recall bar"
        else:
            state, headline = "warn", "Retrieval is below the recall bar"
        misses = data.get("failures") or []
        detail = (f"recall@1 {r1:.0%} recall@5 {r5:.0%} vs {thr:.0%} bar; "
                  f"{len(misses)}/{data.get('cases', '?')} case(s) miss the top 5"
                  if isinstance(r1, float) and isinstance(r5, float) and isinstance(thr, float)
                  else "eval result is unreadable")
        if stale_days is not None:
            detail += f"; scored {stale_days:.1f}d ago"
        rec(rows, "Memory retrieval quality", "Pipeline", state, headline, detail,
            str(eval_state),
            fix=eval_fix if state != "ok" else None,
            cause_code="memory.retrieval_below_bar" if state != "ok" else None,
            # Quality drifts, it does not break: one weak week is noise, a
            # sustained one is a real regression worth a push.
            notification_policy="consecutive")

    # Coverage: content the index cannot see at all. Distinct from both liveness
    # and quality — a perfectly fresh, perfectly ranked index still returns
    # nothing for a folder no configured root covers, and nothing else notices.
    drift_state = HOME / ".local" / "state" / "memory-coverage-drift" / "last-run.json"
    drift = load_json(drift_state)
    if drift is None:
        rec(rows, "Memory index coverage", "Pipeline", "unknown",
            "No coverage scan yet", str(drift_state),
            fix=fix_manual("Run coverage scan",
                           "Read-only scan for authored content outside every indexed root.",
                           [str(HOME / ".local" / "bin" / "memory-coverage-drift")]))
    else:
        found = drift.get("findings") or []
        top = ", ".join(f["path"].replace(str(HOME), "~") for f in found[:3])
        # A truncated scan proves nothing about what it did not reach, so it must
        # never render as a clean bill of health.
        partial = bool(drift.get("partial"))
        rec(rows, "Memory index coverage", "Pipeline",
            "warn" if (found or partial) else "ok",
            "Coverage scan did not finish" if partial
            else ("Every content directory is indexed" if not found
                  else f"{len(found)} director(ies) hold memory nothing indexes"),
            f">={drift.get('threshold', '?')} prose files each" + (f": {top}" if top else ""),
            str(drift_state),
            fix=None if not found else fix_manual(
                "Review uncovered directories",
                "Add the ones holding real memory to ~/.memory/semantic-folders.txt. "
                "Deliberately manual: what belongs in the corpus is a judgement call.",
                [str(HOME / ".local" / "bin" / "memory-coverage-drift")]),
            cause_code="memory.coverage_gap" if (found or partial) else None,
            notification_policy="consecutive")

    # Index integrity. MEMORY.md is the one file loaded into context every single
    # session, and it rots in ways nothing else can see: a line pointing at a
    # deleted note keeps asserting that note's facts forever, and a note with no
    # line never enters context at all. Both read as perfectly healthy everywhere
    # else — the file parses, the search index is fresh, liveness is green.
    idx_state = HOME / ".local" / "state" / "memory-index-check" / "last-run.json"
    idx = load_json(idx_state)
    idx_fix = fix_manual(
        "Review memory index",
        "Lists index lines with no note, notes with no index line, and broken "
        "frontmatter. Read-only: which one is wrong is a judgement call.",
        [str(HOME / ".local" / "bin" / "memory-index-check")],
    )
    if idx is None:
        rec(rows, "Memory index integrity", "Pipeline", "unknown",
            "Never checked", str(idx_state), fix=idx_fix)
    else:
        n = int(idx.get("problems", 0))
        bits = []
        for key, word in (("dangling", "dangling"), ("unlinked", "unlinked"),
                          ("misnamed", "misnamed"), ("incomplete", "incomplete")):
            c = len(idx.get(key) or [])
            if c:
                bits.append(f"{c} {word}")
        rec(rows, "Memory index integrity", "Pipeline", "warn" if n else "ok",
            f"{idx.get('entries', '?')} entries match {idx.get('files', '?')} notes"
            if not n else f"{n} index problem(s)",
            "; ".join(bits) or "no dangling entries, no unlinked notes",
            str(idx_state),
            fix=idx_fix if n else None,
            cause_code="memory.index_rot" if n else None,
            notification_policy="consecutive")

    # Restore drill. A push that returns success proves the remote ACCEPTED a
    # commit, not that a full corpus can be recovered from it. memory-backup-verify
    # clones the remote and diffs it against the live corpus, so silent one-way
    # drift (a widened ignore rule, rotated credentials, a rejecting hook) is
    # caught by an actual restore rather than by needing one.
    verify_state = HOME / ".local" / "state" / "memory-backup-verify" / "last-run.json"
    verify = load_json(verify_state)
    verify_fix = fix_manual(
        "Run restore drill",
        "Clones the corpus remote into a temp dir and diffs it against ~/.memory. "
        "Read-only; the clone is deleted afterwards.",
        [str(HOME / ".local" / "bin" / "memory-backup-verify")],
    )
    if not verify:
        rec(rows, "Memory backup restorability", "Pipeline", "unknown",
            "Never verified", str(verify_state), fix=verify_fix)
    else:
        st = {"ok": "ok", "warn": "warn"}.get(str(verify.get("status")), "fail")
        rec(rows, "Memory backup restorability", "Pipeline", st,
            str(verify.get("headline", "unknown")),
            str(verify.get("detail", "")) + f"; checked {verify.get('checked_at', '?')}",
            str(verify_state),
            fix=None if st == "ok" else verify_fix,
            cause_code="memory.backup_unrestorable" if st == "fail" else None,
            # A backup that cannot be restored is the one failure with no second
            # chance, so it pages on the first occurrence rather than waiting for
            # a pattern.
            notification_policy="immediate" if st == "fail" else "consecutive")


def app_records(rows: list[dict[str, Any]]) -> None:
    apps = [
        ("Market.app", Path("/Applications") / "Market.app"),
        ("Gemini.app", Path("/Applications") / "Gemini.app"),
        ("JDownloader2.app", Path("/Applications") / "JDownloader2.app"),
        ("Claude Code URL Handler.app", Path("/Applications") / "Claude Code URL Handler.app"),
    ]
    for name, path in apps:
        rec(
            rows,
            name,
            "App",
            "ok" if path.exists() else "warn",
            "Installed" if path.exists() else "Missing",
            str(path),
            fix=None if path.exists() else fix_manual(
                "Reinstall", f"Expected at {path}. Reinstall it, or drop it from the list in tool-status-scan.py."
            ),
        )


def worker_log_records(rows: list[dict[str, Any]]) -> None:
    """Explicit contracts for long-running workers that can fail without exiting."""
    discord_health = HOME / ".local/state/smart-wake/discord-health.json"
    discord_log = HOME / ".local/state/smart-wake/discord.log"
    try:
        health = json.loads(discord_health.read_text(encoding="utf-8"))
        if not isinstance(health, dict):
            raise ValueError("health payload is not an object")
        updated_at = float(health.get("updatedAt") or 0)
        started_at = float(health.get("startedAt") or updated_at)
        last_success = float(health.get("lastSuccessAt") or 0)
        failure_count = int(health.get("consecutiveFailures") or 0)
        last_error = str(health.get("lastError") or "")
        age_seconds = max(0.0, dt.datetime.now().timestamp() - updated_at)
        outage_start = last_success or started_at
        outage_seconds = max(0.0, dt.datetime.now().timestamp() - outage_start)
        auth_failure = bool(re.search(r"Discord HTTP (401|403)\b", last_error))
        stale = age_seconds > 15 * 60

        if stale:
            state, headline = "warn", "The worker health heartbeat is stale"
            cause_code, policy = "background_worker.health_stale", "consecutive"
        elif not last_success and failure_count == 0:
            state, headline = "unknown", "The worker is completing its first poll"
            cause_code, policy = None, "consecutive"
        elif failure_count == 0:
            state, headline = "ok", "Polling is healthy"
            cause_code, policy = None, "consecutive"
        elif auth_failure:
            state, headline = "fail", "Discord rejected the worker credentials"
            cause_code, policy = "background_worker.auth_failed", "immediate"
        elif outage_seconds >= 30 * 60:
            state, headline = "warn", "Discord polling has been unavailable for 30 minutes"
            cause_code, policy = "background_worker.sustained_outage", "consecutive"
        else:
            state, headline = "unknown", "Polling is temporarily deferred"
            cause_code, policy = None, "consecutive"

        detail = (
            f"health age={age_seconds / 60:.1f}m; consecutive failures={failure_count}; "
            f"last success age={(dt.datetime.now().timestamp() - last_success) / 60:.1f}m"
            if last_success else
            f"health age={age_seconds / 60:.1f}m; consecutive failures={failure_count}; no successful poll yet"
        )
        if last_error:
            detail += f"; latest error: {clip(last_error, 260)}"
        rec(
            rows, "Smart Wake Discord Watcher", "Background Worker", state, headline,
            detail, f"{discord_health} | {discord_log}",
            fix=fix_auto(
                "Restart worker",
                ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/com.user.smartwake.discord"],
                "Restarts the existing worker. Use the structured health evidence to distinguish authentication failure from a transient network outage.",
            ) if state in {"warn", "fail"} else None,
            cause_code=cause_code, notification_policy=policy,
            cause_params={"worker": "com.user.smartwake.discord"},
        )
    except FileNotFoundError:
        rec(
            rows, "Smart Wake Discord Watcher", "Background Worker", "unknown",
            "Structured worker health has not been published yet",
            "The LaunchAgent record remains the authoritative liveness check until the watcher publishes its first health heartbeat.",
            str(discord_health), cause_params={"worker": "com.user.smartwake.discord"},
        )
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        rec(
            rows, "Smart Wake Discord Watcher", "Background Worker", "warn",
            "Structured worker health cannot be read", str(error), str(discord_health),
            cause_code="background_worker.health_invalid", notification_policy="consecutive",
            cause_params={"worker": "com.user.smartwake.discord"},
        )

    adapters = [("Smart Wake Core", Path("/tmp/smartwake.err"), "com.user.smartwake")]
    failure_words = re.compile(r"failed|error|http 5\d\d|could not resolve", re.IGNORECASE)
    for name, path, launch_label in adapters:
        if not path.exists():
            rec(
                rows, name, "Background Worker", "unknown", "No worker log exists",
                "The process/LaunchAgent record remains the authoritative liveness check.", str(path),
            )
            continue
        try:
            age_minutes = (dt.datetime.now().timestamp() - path.stat().st_mtime) / 60
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            latest = next((line for line in reversed(lines) if line.strip()), "")
        except OSError as error:
            rec(rows, name, "Background Worker", "unknown", "Worker log cannot be read", str(error), str(path))
            continue
        recent_failure = age_minutes <= 20 and bool(failure_words.search(latest))
        rec(
            rows, name, "Background Worker", "warn" if recent_failure else "ok",
            "The worker is repeatedly failing" if recent_failure else "No recent worker failure",
            f"latest log age={age_minutes:.1f}m; latest line: {clip(latest, 300)}",
            str(path),
            fix=fix_auto(
                "Restart worker",
                ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{launch_label}"],
                "Restarts the existing worker. If the same cause returns, use the log evidence above to repair network or configuration.",
            ) if recent_failure else None,
            cause_code="background_worker.recent_failures" if recent_failure else None,
            notification_policy="consecutive",
            cause_params={"worker": launch_label},
        )


def dashboard_runtime_records(rows: list[dict[str, Any]]) -> None:
    app = Path("/Applications/Tool Dashboard.app")
    components = [
        ("app executable", app / "Contents/MacOS/ToolStatusDashboard", True),
        ("status scanner", app / "Contents/Resources/tool-status-scan.py", True),
        ("incident runner", app / "Contents/Resources/tool-status-background-scan.py", True),
        ("repair worker", app / "Contents/Resources/tool-status-repair-worker.py", True),
        ("repair result schema", app / "Contents/Resources/tool-status-repair-result.schema.json", False),
        ("launch wrapper", HOME / ".local/bin/tool-status-background-scan", True),
        ("repair wrapper", HOME / ".local/bin/tool-status-repair-worker", True),
        ("notification bridge", HOME / ".local/bin/tool-status-notify", True),
        ("LaunchAgent definition", HOME / "Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.scan.plist", False),
        ("repair LaunchAgent definition", HOME / "Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.repair.plist", False),
    ]
    missing = [name for name, path, _ in components if not path.is_file()]
    non_executable = [name for name, path, executable in components if executable and path.is_file() and not os.access(path, os.X_OK)]
    problems = [*(f"missing {name}" for name in missing), *(f"non-executable {name}" for name in non_executable)]
    paths = [str(path) for _, path, _ in components]
    rec(
        rows, "Tool Dashboard Runtime", "Background Job",
        "fail" if problems else "ok",
        "; ".join(problems) if problems else f"All {len(components)} installed runtime components are present",
        "; ".join(f"{name}={path}" for name, path, _ in components),
        " | ".join(paths),
        fix=fix_manual(
            "Reinstall dashboard",
            "Run the project build wrapper to atomically replace the app, bridges, and LaunchAgent, then verify the scheduled context.",
            [str(HOME / "Projects/ToolStatusDashboard/build.sh")],
        ) if problems else None,
        cause_code="tool_status.runtime_component_missing" if problems else None,
        notification_policy="immediate",
        cause_params={"components": ",".join(problems)} if problems else {},
        record_id="Background Job:Tool Status Dashboard Runtime",
    )


def deployed_source_drift_records(rows: list[dict[str, Any]]) -> None:
    """Prove the deployed copies still match their repo sources.

    Every file below is *copied* out of Projects/ToolStatusDashboard by build.sh.
    The repo is the source of truth; the deployed file is a build artifact. Editing
    the repo without rebuilding leaves the dashboard running old code, which then
    reports stale findings that look like real failures. This check makes that
    divergence visible instead of silent.
    """
    repo = HOME / "Projects/ToolStatusDashboard"
    app = Path("/Applications/Tool Dashboard.app")
    pairs = [
        (repo / "scripts/tool-status-scan.py", app / "Contents/Resources/tool-status-scan.py"),
        (repo / "scripts/tool-status-background-scan.py", app / "Contents/Resources/tool-status-background-scan.py"),
        (repo / "scripts/tool-status-repair-worker.py", app / "Contents/Resources/tool-status-repair-worker.py"),
        (repo / "scripts/tool-status-repair-result.schema.json", app / "Contents/Resources/tool-status-repair-result.schema.json"),
        (repo / "scripts/tool-status-background-scan-wrapper.sh", HOME / ".local/bin/tool-status-background-scan"),
        (repo / "scripts/tool-status-repair-worker-wrapper.sh", HOME / ".local/bin/tool-status-repair-worker"),
        (repo / "scripts/tool-status-register", HOME / ".local/bin/tool-status-register"),
        (repo / "scripts/tool-status-notify.py", HOME / ".local/bin/tool-status-notify"),
        (repo / "LaunchAgents/com.ivogundlach.tool-status-dashboard.scan.plist", HOME / "Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.scan.plist"),
        (repo / "LaunchAgents/com.ivogundlach.tool-status-dashboard.repair.plist", HOME / "Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.repair.plist"),
    ]

    def digest(path: Path) -> str | None:
        try:
            return hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError:
            return None

    if not repo.is_dir():
        rec(
            rows, "Deployed source drift", "Background Job", "unknown",
            "Source checkout not present; cannot compare deployed copies",
            str(repo), str(repo),
            record_id="Background Job:Deployed source drift",
        )
        return

    stale: list[str] = []
    unreadable: list[str] = []
    for source, deployed in pairs:
        src, dst = digest(source), digest(deployed)
        if src is None or dst is None:
            unreadable.append(source.name)
        elif src != dst:
            stale.append(source.name)

    problems = [*(f"stale {name}" for name in stale), *(f"unreadable {name}" for name in unreadable)]
    rec(
        rows, "Deployed source drift", "Background Job",
        "warn" if problems else "ok",
        (f"{len(stale)} deployed file(s) differ from the repo source — rebuild needed"
         if stale else "; ".join(problems)) if problems
        else f"All {len(pairs)} deployed files match their repo sources",
        "; ".join(problems) if problems else "",
        " | ".join(str(source) for source, _ in pairs),
        fix=fix_manual(
            "Rebuild and redeploy",
            "The repo under Projects/ToolStatusDashboard is the source of truth. "
            "Run build.sh to copy the current sources into the app bundle and ~/.local/bin. "
            "Never hand-edit the deployed copies.",
            [str(repo / "build.sh")],
        ) if problems else None,
        cause_code="tool_status.deployed_source_drift" if problems else None,
        notification_policy="consecutive",
        cause_params={"files": ",".join(stale + unreadable)} if problems else {},
        record_id="Background Job:Deployed source drift",
    )


# How many recent model repair finishes to judge, and how many must be unusable
# before the lane counts as broken rather than merely unlucky.
REPAIR_LANE_WINDOW = 6
REPAIR_LANE_MIN_RUNS = 3
REPAIR_FINISH_EVENTS = {
    "luna-live-finished", "luna-finished", "terra-finished", "decision-audit-finished",
}


def repair_lane_health(rows: list[dict[str, Any]]) -> None:
    """Check that the thing which fixes everything else is itself working.

    The dashboard monitored 135 targets and never once checked whether its own
    repair agent could run. A rejected output schema made every model repair a
    guaranteed no-op for three days; each run was recorded as an ordinary
    unsuccessful repair and retried on a six-hour timer, so approving a fix did
    nothing and nothing ever said so. A repair lane that produces no usable
    result is a broken tool, and a broken tool is reported, not retried in
    silence.
    """
    history = STATE / "repair-history.jsonl"
    finishes: list[dict[str, Any]] = []
    schema_invalid: list[str] = []
    try:
        with history.open("r", encoding="utf-8", errors="replace") as handle:
            # Only the tail matters; the file grows past a megabyte.
            for line in handle.readlines()[-4000:]:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue
                event = entry.get("event")
                if event in REPAIR_FINISH_EVENTS:
                    finishes.append(entry)
                elif event == "repair-schema-invalid":
                    details = entry.get("details")
                    schema_invalid = details if isinstance(details, list) else [str(details)]
                elif event in {"luna-live-started", "terra-started", "luna-started"}:
                    # A fresh attempt clears a previously recorded schema refusal.
                    schema_invalid = []
    except OSError as exc:
        rec(
            rows, "Repair pipeline", "Background Job", "warn",
            "The repair history cannot be read, so repair health is unknown",
            str(exc), str(history),
            cause_code="tool_status.repair_lane_unverifiable",
            notification_policy="consecutive",
            record_id="Background Job:Repair pipeline",
            needs_ivo=True,
        )
        return

    recent = finishes[-REPAIR_LANE_WINDOW:]
    # "Unusable" means the run returned no parseable result at all -- the agent
    # never got to say anything. That is distinct from a repair that ran and
    # concluded it could not fix the problem, which is a legitimate outcome.
    unusable = [
        entry for entry in recent
        if entry.get("status") in (None, "") and entry.get("returnCode") not in (0, None)
    ]
    if schema_invalid:
        state, headline = "fail", "The repair agent's output schema is rejected, so no repair can run"
        detail = "; ".join(str(problem) for problem in schema_invalid)[:700]
        cause = "tool_status.repair_schema_invalid"
        policy = "immediate"
    elif len(recent) >= REPAIR_LANE_MIN_RUNS and len(unusable) == len(recent):
        state = "fail"
        headline = f"The last {len(recent)} repair runs produced no result — approving a fix will not work"
        detail = clip(str(unusable[-1].get("log") or unusable[-1].get("detail") or "no output recorded"), 700)
        cause = "tool_status.repair_lane_dead"
        policy = "immediate"
    else:
        usable = len(recent) - len(unusable)
        state, cause, policy = "ok", None, "consecutive"
        headline = (
            f"{usable} of the last {len(recent)} repair runs returned a usable result"
            if recent else "No repair runs recorded yet"
        )
        detail = ""
    rec(
        rows, "Repair pipeline", "Background Job", state, headline, detail, str(history),
        fix=fix_manual(
            "Inspect the repair agent",
            "The repair agent itself is failing, so every card waiting on a repair is stuck. "
            "Run the worker by hand and read its output; the failing schema or command is "
            "reported in the repair history at the evidence path above.",
            [str(HOME / ".local/bin/tool-status-repair-worker")],
        ) if state != "ok" else None,
        cause_code=cause,
        notification_policy=policy,
        cause_params={"unusable": str(len(unusable)), "window": str(len(recent))} if cause else {},
        record_id="Background Job:Repair pipeline",
        # Deliberately NOT owned by the repair agent, and never queued to it. A
        # dead repair lane cannot repair itself, so queuing this row can only
        # burn retries -- and granting write authority here would let the agent
        # "fix" the very check that grades it by editing the check. This one
        # always comes to Ivo.
        needs_ivo=True,
    )


# Display cap for the process inventory. Overflow is a display limit, never a
# health problem: it reports as an informational row, never a warn (a warn here
# escalates to autonomous repair and produces a manual-intervention card for
# what is only "your Mac is busy").
MAX_PROCESS_ROWS = 150
# Rows whose only possible remediation is the dashboard's own source. See rec()'s
# "owner" field -- this string is the grant the repair worker matches on.
DASHBOARD_OWNER = "tool-status-dashboard"
# Bundle-id prefixes Ivo signs his own apps with. Used instead of a "/Applications"
# substring, which matched every app on the Mac (including /System/Applications).
PERSONAL_BUNDLE_PREFIXES = ("com.ivo.", "com.ivogundlach.", "dev.ivogundlach.")
APP_BUNDLE_RE = re.compile(r"^(/.*?\.app)(?:/|$)")


def is_personal_app(bundle: Path, cache: dict[str, bool]) -> bool:
    """True when the .app bundle is one Ivo built (bundle id prefix), not a vendor app."""
    key = str(bundle)
    if key in cache:
        return cache[key]
    try:
        with (bundle / "Contents" / "Info.plist").open("rb") as handle:
            ident = str(plistlib.load(handle).get("CFBundleIdentifier", ""))
    except Exception:
        ident = ""
    cache[key] = ident.startswith(PERSONAL_BUNDLE_PREFIXES)
    return cache[key]


def school_sync_records(rows: list[dict[str, Any]]) -> None:
    """UAH school sync health.

    The sync used to raise problems as macOS banners posted with `osascript`,
    which macOS attributes to an unsigned generic script rather than to any app.
    That is now removed: the sync only records alert state, and this dashboard is
    where a school-sync problem becomes visible. If this check is wrong or
    missing, a dead Canvas session goes unreported entirely.

    Health is read from the exporter's OUTPUT (the snapshot the School app
    displays), not from the sync's exit status — a run that succeeds at nothing
    still exits 0.
    """
    sync_dir = HOME / "School" / "sync"
    if not sync_dir.is_dir():
        return  # the project is gone; nothing to report on

    snapshot_path = HOME / ".local/state/school-dashboard/dashboard.json"
    login_fix = fix_launch(
        "Log in to Canvas",
        "Opens the Canvas login in a browser. Ivo has to sign in himself — it "
        "restores grades and turned-in status for the School app and the sync.",
        [str(sync_dir / ".venv/bin/python"), "setup_session.py"],
        cwd=str(sync_dir),
    )

    try:
        snapshot = json.loads(snapshot_path.read_text())
    except Exception as error:
        rec(
            rows, "School data snapshot", "Pipeline", "fail",
            "The School app has no data to show",
            f"{type(error).__name__}: {error}", str(snapshot_path),
            fix=fix_manual(
                "Rebuild the School snapshot",
                "Read-only: re-reads Canvas and the saved course list, writes no "
                "reminders or calendar events.",
                [str(sync_dir / ".venv/bin/python"), str(sync_dir / "school_sync.py"), "export"],
            ),
            cause_code="pipeline.status_missing",
        )
        return

    generated = snapshot.get("generated") or ""
    age_hours = None
    try:
        parsed = dt.datetime.fromisoformat(generated)
        age_hours = (dt.datetime.now(parsed.tzinfo) - parsed).total_seconds() / 3600
    except ValueError:
        pass

    # The sync runs hourly; two missed cycles plus slack for a sleeping Mac.
    stale_limit = float(snapshot.get("stale_after_hours") or 3)
    if age_hours is None:
        rec(rows, "School data snapshot", "Pipeline", "warn",
            "The snapshot has no usable timestamp", clip(generated), str(snapshot_path))
    elif age_hours > stale_limit:
        rec(rows, "School data snapshot", "Pipeline", "warn",
            f"School data is {age_hours:.0f}h old",
            f"The hourly sync has not refreshed it since {generated[:16]}.",
            str(snapshot_path),
            cause_code="pipeline.stale")
    else:
        rec(rows, "School data snapshot", "Pipeline", "ok",
            f"School data is current ({age_hours:.1f}h old)",
            f"{len(snapshot.get('courses') or [])} courses, "
            f"{len(snapshot.get('assignments') or [])} assignments",
            str(snapshot_path))

    health = snapshot.get("health") or {}
    started = bool(health.get("started"))
    start_date = health.get("sync_start_date") or ""

    session = health.get("canvas_session") or {}
    if session.get("ok"):
        rec(rows, "School Canvas login", "Auth", "ok",
            "The saved Canvas session is alive", "", str(sync_dir / "storage_state.json"))
    else:
        # Before the semester a dead session is a warning with a deadline; once
        # the term is running it is breaking the sync now.
        rec(rows, "School Canvas login", "Auth",
            "fail" if started else "warn",
            "The saved Canvas session has expired",
            (f"Grades and turned-in status are unavailable until Ivo logs back in. "
             f"School sync starts {start_date}." if not started else
             "Grades and turned-in status are unavailable until Ivo logs back in."),
            clip(str(session.get("error") or "")),
            fix=login_fix,
            cause_code="auth.session_expired",
            notification_policy="immediate",
            deadline_at=start_date or None,
            needs_ivo=True)

    feed = health.get("feed") or {}
    rec(rows, "School assignment feed", "Pipeline",
        "ok" if feed.get("ok") else "fail",
        "The Canvas assignment feed is reachable" if feed.get("ok")
        else "The Canvas assignment feed is failing",
        clip(str(feed.get("error") or "")),
        fix=None if feed.get("ok") else login_fix,
        cause_code=None if feed.get("ok") else "pipeline.source_unreachable")

    # Alerts whose entire subject is already a check above. Reporting both puts
    # the same dead session on the board twice, which trains Ivo to skim.
    covered_by_a_check = {"preflight_session", "session_dead", "ics_backbone"}
    for alert in health.get("alerts") or []:
        key = str(alert.get("key") or "alert")
        if key in covered_by_a_check:
            continue
        rec(rows, f"School sync alert: {key}", "Background Job", "warn",
            clip(str(alert.get("message") or key)),
            f"Raised by the school sync; active since {alert.get('since') or 'unknown'}.",
            str(sync_dir / "state.json"),
            fix=login_fix if "session" in key else None,
            cause_code="job.alert_active")


def process_records(rows: list[dict[str, Any]]) -> None:
    rc, out = run(["ps", "-axo", "pid=,command="], timeout=8)
    if rc != 0:
        rec(rows, "process scan", "Running Process", "warn", "ps failed", clip(out),
            owner=DASHBOARD_OWNER)
        return
    needles = [
        str(HOME / ".local" / "bin"),
        str(HOME / "Projects/Market"),
        str(HOME / ".config" / "smart-wake"),
        str(HOME / "School" / "sync"),
        "PerplexityXPC",
        "NotebookLM",
    ]
    seen: set[str] = set()
    label_counts: dict[str, int] = {}
    app_cache: dict[str, bool] = {}
    matched = 0
    truncated = False
    for line in out.splitlines():
        if "tool-status-scan.py" in line:
            continue
        parts = line.strip().split(maxsplit=1)
        if len(parts) != 2:
            continue
        pid, command = parts
        if not any(needle in command for needle in needles):
            bundle = APP_BUNDLE_RE.match(command)
            if not (bundle and is_personal_app(Path(bundle.group(1)), app_cache)):
                continue
        label = process_label(command)
        key = f"{pid}:{label}"
        if key in seen:
            continue
        seen.add(key)
        matched += 1
        if matched > MAX_PROCESS_ROWS:
            truncated = True
            continue
        # Disambiguate repeated labels so item ids stay unique (SwiftUI Identifiable).
        label_counts[label] = label_counts.get(label, 0) + 1
        display = label if label_counts[label] == 1 else f"{label} (pid {pid})"
        rec(rows, display, "Running Process", "ok", f"pid {pid}", clip(command, 300))
    if truncated:
        rec(rows, "process scan", "Running Process", "ok",
            f"Showing {MAX_PROCESS_ROWS} of {matched} matching processes",
            owner=DASHBOARD_OWNER)
    if not seen:
        rec(rows, "custom process scan", "Running Process", "unknown",
            "No matching custom processes found", owner=DASHBOARD_OWNER)


def process_label(command: str) -> str:
    labels = [
        ("PerplexityXPC", "Perplexity XPC"),
        ("discord-command-watch.py", "Smart Wake Discord Watch"),
        ("smart-wake.sh", "Smart Wake"),
        ("quit-on-close", "quit-on-close"),
        ("apple-mail-draft-runner", "Apple Mail Draft Runner"),
        ("codex-to-claude-sync", "Codex to Claude Sync"),
        ("notebooklm", "NotebookLM"),
        ("/Projects/Market/", "Market"),
        ("/School/sync/", "School Sync"),
        ("agy", "AGY"),
    ]
    for needle, label in labels:
        if needle in command:
            return label
    # App-bundle executables carry spaces ("/Applications/Warm Corners.app/..."),
    # so splitting on whitespace truncates the name. Prefer the bundle name.
    bundle = APP_BUNDLE_RE.match(command)
    if bundle:
        return Path(bundle.group(1)).stem
    return Path(command.split()[0]).name or command.split()[0]


def source_archive_coverage_record(rows: list[dict[str, Any]]) -> None:
    """Projects the source archive is deliberately not archiving.

    personal-repo-sync only archives projects on a hardcoded manifest. It used to
    abort the whole run on an unlisted name, which meant one new folder silently
    stopped archiving everything else; it now skips and records the names. That
    trade is only safe if "these are not backed up" is visible somewhere, because
    the failure mode moved from loud-and-total to quiet-and-partial.
    """
    listing = HOME / ".local/state/personal-repo-sync/unclassified.txt"
    try:
        names = [line.strip() for line in listing.read_text(encoding="utf-8").splitlines() if line.strip()]
    except OSError:
        return
    rec(
        rows, "Source archive coverage", "Background Job",
        "warn" if names else "ok",
        f"{len(names)} project(s) are not being archived" if names
        else "Every project in Projects is covered by the source archive",
        ", ".join(names), str(listing),
        fix=fix_manual(
            "Add them to the archive manifest",
            "Each name goes in the known_projects list in "
            "Projects/Personal-Repo/scripts/sync-from-machine.sh, and in apps as well "
            "if its source should actually be snapshotted. Leaving one out is a valid "
            "choice; this card just keeps it a deliberate one.",
        ) if names else None,
        cause_code="personal_repo_sync.unclassified_projects" if names else None,
        notification_policy="consecutive",
        record_id="Background Job:Source archive coverage",
    )


def operational_failure_records(rows: list[dict[str, Any]]) -> None:
    auto_reset_log = HOME / ".local/state/codex-auto-reset/auto-reset.log"
    try:
        latest_reset = next(
            line for line in reversed(auto_reset_log.read_text(encoding="utf-8", errors="replace").splitlines())
            if line.strip()
        )
    except (OSError, StopIteration):
        latest_reset = ""
    reset_failure = any(marker in latest_reset for marker in (
        " failure:", " schedule-failure:", " skip:", " notification-failure:",
    ))
    reset_warning = " retry:" in latest_reset
    # Transient network/timeout/quota conditions self-heal on the next run (the daily
    # refresh re-installs targets), so they are shown but never escalated to Terra.
    reset_transient = any(marker in latest_reset.lower() for marker in (
        "timeout", "timed out", "disconnect", "connection", "network",
        "temporarily", "unavailable", "rate limit", " 429", " 500", " 502", " 503", " 504",
    ))
    if reset_failure and not reset_transient:
        reset_state, reset_headline = "fail", "The latest reset automation run failed"
        reset_cause, reset_policy, reset_self_healing = "codex_auto_reset.failed", "immediate", False
    elif reset_failure or reset_warning:
        reset_state = "warn"
        reset_headline = (
            "A reset run hit a transient error and will retry" if reset_transient
            else "A reset could not yet be applied"
        )
        reset_cause = "codex_auto_reset.transient" if reset_transient else "codex_auto_reset.retry"
        reset_policy, reset_self_healing = "consecutive", True
    else:
        reset_state, reset_headline = "ok", "No current reset automation failure"
        reset_cause, reset_policy, reset_self_healing = None, "consecutive", False
    rec(
        rows, "Codex Auto Reset", "Background Job", reset_state, reset_headline,
        latest_reset or "No reset automation result has been recorded yet.", str(auto_reset_log),
        fix=fix_auto(
            "Refresh reset schedule",
            [str(HOME / ".local/bin/codex-auto-reset"), "--schedule"],
            "Refreshes the exact expiry-based redemption targets. The command does not consume a reset.",
        ) if reset_state != "ok" else None,
        cause_code=reset_cause,
        notification_policy=reset_policy,
        cause_params={"latest": clip(latest_reset, 180)} if reset_state != "ok" else {},
        record_id="Background Job:Codex Auto Reset Health",
        self_healing=reset_self_healing,
    )

    mail_state_path = HOME / ".local/state/inbound-response-drafter/state.json"
    mail_state_error = ""
    try:
        mail_state = json.loads(mail_state_path.read_text(encoding="utf-8"))
        if not isinstance(mail_state, dict):
            raise ValueError("state root is not an object")
        messages = mail_state.get("messages", {})
        if not isinstance(messages, dict):
            raise ValueError("state messages field is not an object")
        failed_mail = [
            (key, value) for key, value in messages.items()
            if isinstance(value, dict) and value.get("status") in {"failed", "failed-permanent"}
        ]
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        failed_mail = []
        mail_state_error = f"Apple Mail draft state unreadable: {exc}"
    permanent_mail = [(key, value) for key, value in failed_mail if value.get("status") == "failed-permanent"]
    manual_review_mail = [
        (key, value) for key, value in permanent_mail if value.get("phase") == "manual-review"
    ]
    mail_health = "fail" if mail_state_error or permanent_mail else ("warn" if failed_mail else "ok")
    mail_examples = sorted(
        failed_mail, key=lambda item: int(item[1].get("updated_at", 0)), reverse=True
    )[:3]
    mail_detail = "; ".join(
        f"{key} [{value.get('phase', 'unknown-phase')}]: {value.get('reason', 'unknown failure')}"
        for key, value in mail_examples
    )
    rec(
        rows, "Apple Mail Draft Assistant", "Background Job", mail_health,
        mail_state_error
        or (f"{len(failed_mail)} mail draft failure{'s' if len(failed_mail) != 1 else ''} need attention"
            if failed_mail else "No unresolved mail draft failures"),
        clip(mail_state_error or mail_detail, 700), str(mail_state_path),
        fix=fix_manual(
            "Inspect failed drafts",
            "If state is unreadable, repair or restore state.json before rerunning. For manual-review failures, inspect Apple Mail Drafts for an already-saved draft before changing state or rerunning. Otherwise correct the reported mail/thread problem, then rerun the workflow.",
            [str(HOME / ".local/bin/apple-mail-draft-assistant"), "scan", "--json"],
        ) if mail_state_error or failed_mail else None,
        cause_code=("apple_mail_draft.state_unreadable" if mail_state_error else "apple_mail_draft.failed")
        if mail_state_error or failed_mail else None,
        notification_policy="immediate" if mail_state_error or permanent_mail else "consecutive",
        # A manual-review failure is a finished event: a draft that already failed
        # to save, days ago. No agent can retroactively repair it, so it must not
        # enter the repair queue -- one such record kept the repair lane retrying
        # for two days and offered Ivo an Approve button with nothing behind it.
        needs_ivo=bool(manual_review_mail) and not mail_state_error,
        cause_params={
            "count": str(len(failed_mail)),
            "manual_review_count": str(len(manual_review_mail)),
            "latest": mail_examples[0][0] if mail_examples else "state-unreadable",
        }
        if mail_state_error or failed_mail else {},
        record_id="Background Job:Apple Mail Draft Assistant Health",
    )

    usage_jobs = HOME / ".local/state/queue-when-usage/jobs"
    failed_jobs: list[dict[str, Any]] = []
    try:
        for path in usage_jobs.glob("*.json"):
            try:
                job = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(job, dict) and job.get("status") in {"failed", "gave_up"}:
                failed_jobs.append(job)
    except OSError:
        pass
    failed_jobs.sort(key=lambda job: int(job.get("updated_at") or job.get("created_at") or 0), reverse=True)
    usage_detail = "; ".join(
        f"{job.get('id', 'unknown')} ({job.get('agent', 'unknown')}): "
        f"{job.get('error') or job.get('status')}" for job in failed_jobs[:3]
    )
    rec(
        rows, "UsageQueue", "Background Job", "fail" if failed_jobs else "ok",
        f"{len(failed_jobs)} queued message failure{'s' if len(failed_jobs) != 1 else ''} need attention"
        if failed_jobs else "No unresolved queued message failures",
        clip(usage_detail, 700), str(usage_jobs),
        fix=fix_manual(
            "Inspect failed queue jobs",
            "Open UsageQueue or list its jobs, inspect the full error, then retry or remove only the failed job.",
            [str(HOME / ".local/bin/queue-when-usage"), "jobs", "--json"],
        ) if failed_jobs else None,
        cause_code="usage_queue.failed" if failed_jobs else None,
        notification_policy="immediate",
        cause_params={"count": str(len(failed_jobs)), "latest": str(failed_jobs[0].get("id", "unknown"))}
        if failed_jobs else {},
        record_id="Background Job:UsageQueue Health",
    )


def market_records(rows: list[dict[str, Any]]) -> None:
    root = HOME / "Projects/Market"
    label = "com.ivo.market.refresh"
    plist = HOME / "Library/LaunchAgents/com.ivo.market.refresh.plist"
    app = Path("/Applications/Market.app/Contents/MacOS/Market")
    wrapper = HOME / ".local/bin/market-refresh"
    state_dir = root / "state/background"
    stamps = root / "out/background_stamps"
    x_status_path = root / "state/x_scrape_status.json"
    regime_status_path = root / "state/regime_scrape_status.json"
    youtube_status_path = root / "state/youtube_scrape_status.json"
    debrief_status_path = root / "state/debrief_status.json"
    job = launchctl_job(label)
    now = dt.datetime.now().astimezone()
    today = now.date().isoformat()
    failures: list[str] = []
    evidence: list[str] = [
        str(plist), str(app), str(wrapper), str(root / "scripts/market-refresh"),
        str(state_dir), str(x_status_path), str(regime_status_path), str(youtube_status_path),
        str(debrief_status_path),
    ]
    auth_required = False
    failure_cause: str | None = None
    disabled_sources: list[str] = []
    config_path = root / "config.json"
    try:
        config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.is_file() else {}
    except (OSError, json.JSONDecodeError):
        config = {}
    configured_sources = config.get("sources") if isinstance(config, dict) else {}
    if isinstance(configured_sources, dict):
        for source_name in ("tradingview", "discord"):
            source_config = configured_sources.get(source_name)
            if isinstance(source_config, dict) and source_config.get("enabled"):
                failures.append(
                    f"{source_name} is enabled but has no registered structured Dashboard health contract"
                )
                failure_cause = failure_cause or "market.source_health_unregistered"
            elif isinstance(source_config, dict):
                disabled_sources.append(source_name)

    for name, path in (("LaunchAgent plist", plist), ("signed Market executable", app), ("dispatcher", wrapper)):
        if not path.is_file():
            failures.append(f"missing {name}: {path}")
    if job is None:
        failures.append("Market refresh LaunchAgent is not loaded")
    elif job.get("state") != "running":
        last_exit = job.get("last exit code")
        if last_exit and last_exit not in {"0", "(never exited)"}:
            failures.append(f"Market refresh LaunchAgent last exited with {last_exit}")
            failure_cause = failure_cause or "market.scheduler_last_run_failed"

    if job is not None and job.get("state") == "running" and not failures:
        rec(
            rows, "Market Background Refresh", "Background Job", "warn",
            "Refresh in progress; awaiting producer health",
            "The signed background dispatcher is running. Previous failure/status evidence "
            "is retained until this run exits and writes fresh scraper health.",
            " | ".join(evidence),
            record_id="Background Job:Market Background Refresh",
        )
        return

    due = (("ingest", 800), ("debrief", 1615), ("watchdog", 1710))
    hhmm = now.hour * 100 + now.minute
    for stage, after in due:
        attempt = state_dir / f"{stage}.last_attempt"
        success = state_dir / f"{stage}.last_success"
        failure = state_dir / f"{stage}.last_failure"
        if failure.exists() and (not success.exists() or failure.stat().st_mtime > success.stat().st_mtime):
            try:
                detail = failure.read_text(encoding="utf-8", errors="replace").strip()
            except OSError:
                detail = "unreadable failure state"
            failures.append(f"{stage} failed: {detail}")
            evidence.append(str(failure))
        attempt_recent = False
        try:
            attempt_at = dt.datetime.fromisoformat(attempt.read_text(encoding="utf-8").strip().replace("Z", "+00:00"))
            if attempt_at.tzinfo is None:
                attempt_at = attempt_at.replace(tzinfo=dt.timezone.utc)
            attempt_age = (dt.datetime.now(dt.timezone.utc) - attempt_at.astimezone(dt.timezone.utc)).total_seconds()
            # A small negative age tolerates normal clock jitter. A far-future
            # timestamp must not suppress overdue detection indefinitely.
            attempt_recent = -5 * 60 <= attempt_age < 40 * 60
        except (OSError, TypeError, ValueError):
            pass
        if hhmm >= after + 30 and not (stamps / f"{stage}.{today}").exists() and not attempt_recent:
            failures.append(f"{stage} is overdue for {today}")

    def scraper_status(name: str, path: Path) -> dict[str, Any] | None:
        nonlocal failure_cause
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise TypeError("status is not an object")
        except (OSError, json.JSONDecodeError, TypeError):
            if hhmm >= 830:
                failures.append(f"{name} scraper has no valid background health status")
                failure_cause = failure_cause or f"market.{name.casefold()}_status_missing"
            return None

        summary = {
            "scraper": name,
            "status": data.get("status"),
            "checked_at": data.get("checked_at"),
            "execution_context": data.get("execution_context"),
            "new_events": data.get("new_events"),
        }
        evidence.append(json.dumps(summary, sort_keys=True))
        if data.get("execution_context") != "background":
            failures.append(f"{name} scraper health did not come from the background context")
            failure_cause = failure_cause or f"market.{name.casefold()}_context_invalid"
        checked_at = data.get("checked_at")
        try:
            parsed = dt.datetime.fromisoformat(str(checked_at).replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
            age_hours = (dt.datetime.now(dt.timezone.utc) - parsed.astimezone(dt.timezone.utc)).total_seconds() / 3600
            if age_hours < -(5 / 60):
                failures.append(f"{name} scraper health timestamp is in the future ({-age_hours:.1f} hours)")
                failure_cause = failure_cause or f"market.{name.casefold()}_status_invalid"
            elif age_hours > 30:
                failures.append(f"{name} scraper health is stale ({age_hours:.1f} hours old)")
                failure_cause = failure_cause or f"market.{name.casefold()}_status_stale"
        except (TypeError, ValueError):
            failures.append(f"{name} scraper health has an invalid checked_at timestamp")
            failure_cause = failure_cause or f"market.{name.casefold()}_status_invalid"
        return data

    x_status = scraper_status("x", x_status_path)
    if x_status:
        if x_status.get("authentication_only"):
            failures.append("X/Twitter health contains only an authentication probe, not a completed scrape")
            failure_cause = failure_cause or "market.x_scrape_status_incomplete"
        if x_status.get("status") == "auth_required":
            auth_required = True
            failures.append("X/Twitter authentication is unavailable in the background context")
            failure_cause = "market.x_auth_required"
        elif x_status.get("status") != "ok":
            failures.append(f"X/Twitter scraper status is {x_status.get('status')}")
            failure_cause = failure_cause or "market.x_scrape_failed"
        handles_checked = x_status.get("handles_checked")
        handles_expected = x_status.get("handles_expected")
        raw_handle_results = x_status.get("handle_results")
        handle_results = raw_handle_results if isinstance(raw_handle_results, dict) else {}
        if (
            not isinstance(handles_checked, int) or not isinstance(handles_expected, int)
            or handles_expected < 1 or handles_checked != handles_expected
            or not isinstance(raw_handle_results, dict) or len(handle_results) != handles_expected
        ):
            failures.append(
                f"X/Twitter checked {handles_checked} of {handles_expected} configured profiles"
            )
            failure_cause = failure_cause or "market.x_profile_coverage_incomplete"
        empty_profiles = sorted(
            handle for handle, result in handle_results.items()
            if isinstance(result, dict) and not result.get("observed_posts")
        )
        if empty_profiles:
            failures.append(f"X/Twitter rendered no posts for: {', '.join(empty_profiles)}")
            failure_cause = failure_cause or "market.x_profile_render_empty"
        stale_profiles = []
        missing_timestamp_profiles = []
        window_days = float(x_status.get("window_days") or 30)
        for handle, result in handle_results.items():
            if not isinstance(result, dict):
                continue
            if result.get("observed_posts") and not result.get("newest_observed"):
                missing_timestamp_profiles.append(handle)
                continue
            try:
                newest = dt.datetime.fromisoformat(str(result["newest_observed"]).replace("Z", "+00:00"))
                if newest.tzinfo is None:
                    newest = newest.replace(tzinfo=dt.timezone.utc)
                age_days = (dt.datetime.now(dt.timezone.utc) - newest.astimezone(dt.timezone.utc)).total_seconds() / 86400
                if age_days < -(5 / 1440):
                    stale_profiles.append(f"{handle} (future timestamp)")
                elif age_days > window_days:
                    stale_profiles.append(f"{handle} ({age_days:.0f}d)")
            except (TypeError, ValueError):
                stale_profiles.append(f"{handle} (invalid timestamp)")
        if stale_profiles:
            failures.append(f"X/Twitter profiles have no posts inside the {window_days:.0f}-day window: {', '.join(sorted(stale_profiles))}")
            failure_cause = failure_cause or "market.x_profile_stale"
        if missing_timestamp_profiles:
            failures.append(
                "X/Twitter profiles rendered posts but no usable timestamps: "
                + ", ".join(sorted(missing_timestamp_profiles))
            )
            failure_cause = failure_cause or "market.x_profile_timestamp_missing"

    regime_status = scraper_status("regime", regime_status_path)
    if regime_status:
        claimed = str(regime_status.get("status"))
        raw_errors = regime_status.get("errors")
        raw_pending = regime_status.get("pending")
        raw_components = regime_status.get("available_components")
        # Insist on the declared types rather than truthiness: a bare string would otherwise
        # iterate character-by-character and a scalar would satisfy a plain emptiness test.
        regime_errors = [str(e) for e in raw_errors] if isinstance(raw_errors, list) else []
        regime_pending = raw_pending if isinstance(raw_pending, list) else []
        # Only this exact reason may be waived. An unrecognised or empty code is not a lag
        # this scanner knows how to forgive, so it falls through to the degraded path.
        pending_codes = {p.get("code") for p in regime_pending if isinstance(p, dict)}
        pending_text = [
            str(p.get("detail") or p.get("code")) for p in regime_pending if isinstance(p, dict)
        ]
        # "pending_session" is the producer's claim that put/call alone is missing because
        # Yahoo had not published the nearest expiry's volume yet — a lag that spans the
        # morning ingest window and that a forced retry cannot shorten. Verify the claim
        # rather than trusting the word: a monitor must never let the producer it supervises
        # declare itself healthy on an unchecked assertion. Any other shape falls through to
        # the degraded path below, where --request-ingest can actually repair it.
        # Deliberately NOT bounded by how long put/call has been pending. A wall-clock bound
        # pages every Monday after a long weekend, reintroducing the false alarm this exists
        # to remove. The blind spot is closed structurally instead: the waiver only applies
        # to a PRE/PREPRE/CLOSED scrape, and the producer treats an empty chain during
        # REGULAR or POST as a hard error, so the debrief run — 16:15 local, inside US market
        # hours year-round — surfaces any genuine outage the next time it runs.
        pending_claim_valid = (
            regime_status.get("confidence") == "partial"
            and isinstance(raw_errors, list) and not regime_errors
            and pending_codes == {"options.volume_not_published"}
            and isinstance(raw_components, list)
            and sorted(str(c) for c in raw_components) == ["fear_greed", "vix"]
        )
        if claimed != "ok" and not (claimed == "pending_session" and pending_claim_valid):
            failures.append(
                f"Market-regime website coverage is {claimed}: "
                f"{clip('; '.join(regime_errors or pending_text) or 'no reason recorded', 300)}"
            )
            failure_cause = failure_cause or "market.regime_scrape_degraded"

    youtube_status = scraper_status("youtube", youtube_status_path)
    if youtube_status and youtube_status.get("status") not in {"ok", "disabled"}:
        failures.append(
            f"YouTube scraping is {youtube_status.get('status')}: "
            f"{len(youtube_status.get('channel_failures') or [])} channel-list failures, "
            f"{len(youtube_status.get('metadata_failures') or [])} metadata failures, "
            f"{len(youtube_status.get('transcript_failures') or [])} transcript failures"
        )
        failure_cause = failure_cause or "market.youtube_scrape_degraded"
    if youtube_status and youtube_status.get("status") != "disabled":
        if youtube_status.get("channels_checked") != youtube_status.get("channels_expected"):
            failures.append(
                f"YouTube checked {youtube_status.get('channels_checked')} of "
                f"{youtube_status.get('channels_expected')} configured channels"
            )
            failure_cause = failure_cause or "market.youtube_channel_coverage_incomplete"

    # A degraded debrief commits and exits 0, so the stamp plane above reports success and the
    # synthesis failure was invisible here until 2026-07-20. Market publishes the real outcome in
    # this sidecar. Read it directly rather than through scraper_status(): that helper's
    # missing-file and >30h staleness rules assume a daily producer, but the debrief is calendar
    # gated to roughly the first and last trading day of each week, so both would fire constantly.
    debrief_repairable = False
    if debrief_status_path.is_file():
        try:
            debrief_status = json.loads(debrief_status_path.read_text(encoding="utf-8"))
            if not isinstance(debrief_status, dict):
                raise TypeError("status is not an object")
        except (OSError, json.JSONDecodeError, TypeError):
            failures.append("debrief health status is unreadable")
            failure_cause = failure_cause or "market.debrief_status_invalid"
            debrief_status = None
        if debrief_status is not None:
            evidence.append(json.dumps({
                "producer": "debrief",
                "status": debrief_status.get("status"),
                "checked_at": debrief_status.get("checked_at"),
                "session_date": debrief_status.get("session_date"),
                "execution_context": debrief_status.get("execution_context"),
            }, sort_keys=True))
            if debrief_status.get("execution_context") != "background":
                failures.append("debrief health did not come from the background context")
                failure_cause = failure_cause or "market.debrief_context_invalid"
            if debrief_status.get("status") != "ok":
                failures.append(
                    "Debrief synthesis degraded to evidence-only: "
                    f"{clip(str(debrief_status.get('degraded_reason') or 'no reason recorded'), 300)}"
                )
                failure_cause = failure_cause or "market.debrief_degraded"
                # Only offer the unattended rebuild while it would repair the CURRENT session,
                # after the normal debrief hour. A forced debrief writes the daily stamp, so
                # firing it in the morning would consume the day's slot and suppress the real
                # 16:15 run; and re-running on a later day would build a different session's
                # debrief while reporting the old one repaired.
                debrief_repairable = (
                    str(debrief_status.get("session_date") or "") == today and hhmm >= 1615
                )

    if failures:
        if auth_required:
            # Keep in lockstep with the worker's MARKET_X_LOGIN_COMMAND /
            # market_x_auth_recovery: Market reuses your Safari X sign-in, so the
            # re-login happens in Safari (not a separate Playwright profile).
            fix = fix_auto(
                "Log in to X",
                ["/usr/bin/open", "-b", "com.apple.Safari", "https://x.com/login"],
                "Opens the X sign-in in Safari. Market reuses your Safari session — sign in "
                "there and it retries automatically.",
            )
        elif debrief_repairable and job is not None and app.is_file() and wrapper.is_file():
            # Preferred over --request-ingest whenever it applies: a forced debrief runs the
            # adapters first, so it repairs the scrapers too rather than only re-ingesting.
            fix = fix_auto(
                "Rebuild today's Market debrief",
                [str(wrapper), "--request-debrief"],
                "Queues a forced rebuild of today's debrief through the signed Market scheduler, retrying synthesis and bypassing today's success stamp while preserving the dispatcher lock.",
            )
        elif job is not None and app.is_file() and wrapper.is_file():
            fix = fix_auto(
                "Retry Market scrapers",
                [str(wrapper), "--request-ingest"],
                "Queues a forced ingest through the signed Market scheduler, bypassing today's success stamp while preserving the dispatcher lock.",
            )
        elif plist.is_file():
            fix = fix_auto(
                "Load Market refresh",
                ["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)],
                "Loads the installed Market scheduler for this login session.",
            )
        else:
            fix = fix_manual(
                "Reinstall Market scheduler",
                "Run ~/Projects/Market/launchd/install.sh after rebuilding and installing Market.app.",
                [str(root / "launchd/install.sh")],
            )
        rec(
            rows, "Market Background Refresh", "Background Job", "fail",
            failures[0], "; ".join(failures), " | ".join(evidence), fix=fix,
            cause_code="market.x_auth_required" if auth_required else (failure_cause or "market.refresh_failed"),
            notification_policy="immediate" if auth_required or job is None else "consecutive",
            cause_params={"failure_count": str(len(failures)), "label": label},
            record_id="Background Job:Market Background Refresh",
        )
        return

    detail = (
        f"scheduler loaded; cadence=900s; today={today}; "
        f"last exit={job.get('last exit code', 'unknown') if job else 'unknown'}; "
        f"registered scraper health=X, regime, YouTube; "
        f"disabled sources={','.join(disabled_sources) if disabled_sources else 'none'}"
    )
    rec(
        rows, "Market Background Refresh", "Background Job", "ok",
        "Scheduler and registered scraper health are current", detail, " | ".join(evidence),
        record_id="Background Job:Market Background Refresh",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live-auth", action="store_true")
    args = parser.parse_args()
    rows: list[dict[str, Any]] = []
    auth_records(rows, live_auth=args.live_auth)
    cli_records(rows)
    covered = registry_records(rows)
    unregistered = discover_unregistered(covered)
    registry_coverage_record(rows, unregistered)
    cron_records(rows)
    launch_agent_records(rows)
    dashboard_runtime_records(rows)
    deployed_source_drift_records(rows)
    repair_lane_health(rows)
    operational_failure_records(rows)
    source_archive_coverage_record(rows)
    market_records(rows)
    semantic_index_records(rows)
    school_sync_records(rows)
    app_records(rows)
    worker_log_records(rows)
    process_records(rows)
    payload = {
        "schemaVersion": 2,
        "generatedAt": now_iso(),
        "liveAuth": args.live_auth,
        "items": rows,
        "unregisteredBinaries": unregistered,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
