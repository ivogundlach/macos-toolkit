#!/usr/bin/env python3
# SOURCE OF TRUTH. build.sh copies this file into
# "/Applications/Tool Dashboard.app" (or ~/.local/bin). The deployed copy is a
# build artifact: edit THIS file, then run Projects/ToolStatusDashboard/build.sh.
# Editing the deployed copy, or editing here without rebuilding, makes the dashboard
# report stale findings. The "Deployed source drift" check flags that divergence.
"""Serialized Tool Dashboard scan, incident lifecycle, and minimal push delivery."""

from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


HOME = Path.home()
RESOURCE_DIR = Path(__file__).resolve().parent
SCANNER = Path(os.environ.get("TOOL_STATUS_SCANNER", RESOURCE_DIR / "tool-status-scan.py"))
CACHE = Path(os.environ.get(
    "TOOL_STATUS_CACHE",
    HOME / "Library/Application Support/ToolStatusDashboard/last-scan.json",
))
STATE = Path(os.environ.get("TOOL_STATUS_STATE", HOME / ".local/state/tool-status-dashboard"))
LOCK = STATE / "scan.lock"
# The GUI app holds this same lock for the length of its own scan, on its own
# 300s refresh timer. A single non-blocking attempt here lets the two 300s
# cycles phase-lock, starving this scan for hours while the app is open, so
# wait out a GUI scan rather than skipping the whole cycle.
LOCK_WAIT_SECONDS = max(0, int(os.environ.get("TOOL_STATUS_LOCK_WAIT_SECONDS", "300")))
SCAN_TIMEOUT_SECONDS = max(150, int(os.environ.get("TOOL_STATUS_SCAN_TIMEOUT_SECONDS", "300")))
INCIDENTS_LOCK = STATE / "incidents.lock"
INCIDENTS = STATE / "incidents.json"
OUTBOX = STATE / "notification-outbox.json"
REPAIR_QUEUE = STATE / "repair-queue"
REPAIR_PENDING = STATE / "repair-pending"
REQUESTS = STATE / "repair-requests.json"
DECISIONS = STATE / "decision-log.jsonl"
HEARTBEAT = STATE / "last-success.json"
REGISTRY = STATE / "registry.json"
REGISTRY_LOCK = STATE / "registry.lock"
LOCAL_BIN = HOME / ".local/bin"
# An auto-registered binary must be absent for this many consecutive scans
# before its entry is dropped, so a transient mount/filesystem blip cannot
# silently erase inventory.
REGISTRY_AUTO_REMOVE_SCANS = 2
WRAPPER_FAILURE = STATE / "wrapper-failure.json"
RANK = {"ok": 0, "unknown": 1, "warn": 2, "fail": 3}
RECOVERY_SCANS = 2
# A self-healing condition (usage limits, transient network/timeout) is tracked but
# not escalated while it is still clearing. If it NEVER clears within this window it
# is treated as a real failure and escalates -- so a permanent fault can't hide
# behind a "transient" classification forever.
SELF_HEAL_GRACE_SECONDS = max(0, int(os.environ.get("TOOL_STATUS_SELF_HEAL_GRACE_SECONDS", str(6 * 3600))))
# Re-running Terra while a decision card is ALREADY waiting on Ivo produces no new
# information and burns a full model run every scan. A composite incident's causeCode
# shifts between scans (Market: x_auth -> debrief -> regime), which changes the
# fingerprint, mints a fresh incident record, resets repairQueued, and re-queues it.
# So gate on the standing request instead, which survives that churn.
REDIAGNOSE_MIN_SECONDS = max(0, int(os.environ.get("TOOL_STATUS_REDIAGNOSE_MIN_SECONDS", str(3600))))
OPEN_REQUEST_STATUSES = {"pending", "awaiting_user_auth", "reconsidering", "approved"}


def now() -> dt.datetime:
    override = os.environ.get("TOOL_STATUS_NOW")
    if override:
        return dt.datetime.fromisoformat(override.replace("Z", "+00:00"))
    return dt.datetime.now(dt.timezone.utc)


def iso(value: dt.datetime | None = None) -> str:
    return (value or now()).astimezone().isoformat(timespec="seconds")


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def acquire_lock():
    STATE.mkdir(parents=True, exist_ok=True)
    handle = LOCK.open("a+")
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while True:
        try:
            fcntl.lockf(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except BlockingIOError:
            if time.monotonic() >= deadline:
                handle.close()
                return None
            time.sleep(0.5)


def acquire_incidents_lock():
    STATE.mkdir(parents=True, exist_ok=True)
    handle = INCIDENTS_LOCK.open("a+")
    fcntl.lockf(handle.fileno(), fcntl.LOCK_EX)
    return handle


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return default


def atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
        temporary = Path(handle.name)
    os.replace(temporary, path)


def append_decision(entry: dict[str, Any]) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    with DECISIONS.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, separators=(",", ":"), sort_keys=True) + "\n")
    try:
        if DECISIONS.stat().st_size > 1_500_000:
            lines = DECISIONS.read_text(encoding="utf-8").splitlines()[-2000:]
            DECISIONS.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except OSError:
        pass


def item_fingerprint(item: dict[str, Any]) -> str:
    # Counters describe persistence, not a new root cause. Including them made
    # one continuous failure produce a fresh repair request on every scan.
    cause_params = {
        key: value for key, value in (item.get("causeParams") or {}).items()
        if key not in {"failure_count", "healthy_count", "attempt_count"}
    }
    stable = {
        "id": item.get("id"),
        "state": item.get("state"),
        "causeCode": item.get("causeCode") or f"generic.{item.get('state', 'unknown')}",
        "causeParams": cause_params,
    }
    encoded = json.dumps(stable, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()[:24]


def scanner_failure_item(cause: str, headline: str = "The background status scan failed") -> dict[str, Any]:
    return {
        "id": "Background Job:Tool Status Dashboard Scanner",
        "name": "Tool Dashboard Scanner",
        "category": "Background Job",
        "state": "fail",
        "headline": headline,
        "detail": cause,
        "evidence": str(STATE / "errors.log"),
        "checkedAt": iso(),
        "fix": {
            "label": "Inspect scanner",
            "kind": "manual",
            "command": [str(HOME / ".local/bin/tool-status-background-scan")],
            "note": "Run the scanner once in Terminal. The full error is also recorded in the evidence log.",
        },
        "causeCode": "tool_status.scanner_failed",
        "causeParams": {},
        "notificationPolicy": "immediate",
        "deadlineAt": None,
    }


def scan(live_auth: bool = False) -> tuple[dict[str, Any], bool, int]:
    previous = load_json(CACHE, {})
    try:
        command = ["/usr/bin/python3", str(SCANNER)]
        if live_auth:
            command.append("--live-auth")
        result = subprocess.run(
            command, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=SCAN_TIMEOUT_SECONDS, check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"scanner exited {result.returncode}")
        payload = json.loads(result.stdout)
        if not isinstance(payload, dict) or not isinstance(payload.get("items"), list):
            raise ValueError("scanner returned an invalid payload")
        wrapper_failure = load_json(WRAPPER_FAILURE, None)
        if isinstance(wrapper_failure, dict):
            try:
                WRAPPER_FAILURE.unlink()
            except OSError:
                pass
        return payload, True, 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        message = f"{type(error).__name__}: {error}"
        print(message, file=sys.stderr)
        items = list(previous.get("items", [])) if isinstance(previous, dict) else []
        items = [item for item in items if item.get("id") != "Background Job:Tool Status Dashboard Scanner"]
        items.append(scanner_failure_item(message))
        return {
            "schemaVersion": 2,
            "generatedAt": iso(),
            "liveAuth": False,
            "items": items,
        }, False, 1


def local_bin_executable(binary: str) -> bool:
    path = LOCAL_BIN / binary
    try:
        return path.is_file() and os.access(path, os.X_OK)
    except OSError:
        return False


def reconcile_registry(payload: dict[str, Any]) -> None:
    """Auto-register newly discovered ~/.local/bin tools; drop auto entries
    whose binary has been gone for consecutive scans. Registry writes happen
    only here and in tool-status-register, always under REGISTRY_LOCK."""
    unregistered = payload.get("unregisteredBinaries")
    if not isinstance(unregistered, list):
        unregistered = []
    STATE.mkdir(parents=True, exist_ok=True)
    lock = REGISTRY_LOCK.open("a+")
    try:
        fcntl.lockf(lock.fileno(), fcntl.LOCK_EX)
        if REGISTRY.exists():
            # Parse explicitly: a corrupt file must pause reconciliation, not
            # be silently replaced (that would drop agent-registered entries).
            # The scan renders a warn row for it; repair goes through incidents.
            try:
                data = json.loads(REGISTRY.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                data = None
            tools = data.get("tools") if isinstance(data, dict) else None
            if not isinstance(tools, list):
                append_decision({"at": iso(), "tool": "Tool Registry", "decision": "registry-reconcile-skipped"})
                return
        else:
            data = {"schemaVersion": 1, "tools": []}
            tools = data["tools"]
        known = {entry.get("binary") for entry in tools if isinstance(entry, dict)}
        changed = False
        for binary in unregistered:
            if not isinstance(binary, str) or binary in known or "/" in binary:
                continue
            # Re-check while holding the lock: the scan ran earlier and the
            # binary may have vanished (or been registered) since.
            if not local_bin_executable(binary):
                continue
            tools.append({
                "name": binary, "binary": binary, "check": "exists",
                "category": "Custom CLI", "addedBy": "auto", "addedAt": iso(),
            })
            known.add(binary)
            append_decision({"at": iso(), "tool": binary, "decision": "registry-auto-added"})
            changed = True
        for entry in list(tools):
            if not isinstance(entry, dict) or entry.get("addedBy") != "auto":
                continue
            binary = str(entry.get("binary") or "")
            if local_bin_executable(binary):
                if entry.pop("missingScans", None) is not None:
                    changed = True
                continue
            entry["missingScans"] = int(entry.get("missingScans", 0)) + 1
            changed = True
            if entry["missingScans"] >= REGISTRY_AUTO_REMOVE_SCANS:
                tools.remove(entry)
                append_decision({"at": iso(), "tool": binary, "decision": "registry-auto-removed"})
        if changed:
            atomic_json(REGISTRY, data)
    finally:
        fcntl.lockf(lock.fileno(), fcntl.LOCK_UN)
        lock.close()


def incident_state() -> dict[str, Any]:
    data = load_json(INCIDENTS, None)
    if not isinstance(data, dict) or not isinstance(data.get("tools"), dict):
        return {
            "schemaVersion": 1, "initialized": False, "tools": {},
            "lastNotifiedByTool": {}, "recentNotifiedFingerprints": {},
        }
    data.setdefault("initialized", True)
    data.setdefault("lastNotifiedByTool", {})
    data.setdefault("recentNotifiedFingerprints", {})
    return data


def standing_request(item_id: str) -> dict[str, Any] | None:
    """An open repair request already waiting on Ivo for this incident, if any."""
    if not item_id:
        return None
    data = load_json(REQUESTS, [])
    if not isinstance(data, list):
        return None
    for request in data:
        if (
            isinstance(request, dict)
            and request.get("incidentID") == item_id
            and request.get("status") in OPEN_REQUEST_STATUSES
        ):
            return request
    return None


def latest_request(item_id: str, fingerprint: str) -> dict[str, Any] | None:
    data = load_json(REQUESTS, [])
    if not isinstance(data, list):
        return None
    matching = [
        request for request in data
        if isinstance(request, dict)
        and request.get("incidentID") == item_id
        and request.get("fingerprint") == fingerprint
    ]
    return matching[-1] if matching else None


def active_repair_exists(item_id: str, fingerprint: str) -> bool:
    if standing_request(item_id) is not None:
        return True
    key = hashlib.sha256(f"{item_id}|{fingerprint}".encode("utf-8")).hexdigest()[:24]
    return (REPAIR_QUEUE / f"{key}.json").exists() or (REPAIR_PENDING / f"{key}.json").exists()


def should_queue_repair(item: dict[str, Any], incident: dict[str, Any]) -> tuple[bool, str]:
    current = now()
    deadline = parse_time(item.get("deadlineAt"))
    if deadline and current >= deadline and not incident.get("deadlineNotified", False):
        return True, "deadline-crossed"
    # Interactive authentication and other genuinely user-owned actions skip Luna,
    # but still enter the repair queue so the worker can create exactly one plain-
    # English action card and push. A future deadline keeps a pre-term login warning
    # visible in the app without notifying early.
    fix = item.get("fix") or {}
    if fix.get("kind") == "launch" or item.get("category") == "Auth" or item.get("needsIvo"):
        if deadline and current < deadline:
            return False, "human-action-awaiting-deadline"
        policy = item.get("notificationPolicy") or "consecutive"
        threshold_met = policy == "immediate" or int(incident.get("failureCount", 0)) >= 2
        if not threshold_met:
            return False, "waiting-for-second-human-action-failure"
        if standing_request(str(item.get("id") or "")) is not None:
            return False, "human-action-already-waiting"
        if incident.get("repairQueued", False):
            return False, "human-action-already-queued"
        return True, "human-action-required"
    standing = standing_request(str(item.get("id") or ""))
    if standing is not None:
        # Nothing new to learn while Ivo already has an open card for this incident.
        # Re-diagnose only if the cause materially changed AND the card has gone stale.
        same_cause = (standing.get("causeCode") or "") == (item.get("causeCode") or "")
        updated = parse_time(standing.get("updatedAt"))
        fresh = updated is not None and (current - updated).total_seconds() < REDIAGNOSE_MIN_SECONDS
        if same_cause or fresh:
            return False, "decision-already-waiting"
    if item.get("selfHealing", False):
        first = parse_time(incident.get("firstSeenAt")) or current
        if (current - first).total_seconds() < SELF_HEAL_GRACE_SECONDS:
            return False, "self-healing-grace"
        # A "transient" condition that never clears within the grace window is a
        # real, unmasked failure -- fall through and escalate it like any other.
    policy = item.get("notificationPolicy") or "consecutive"
    threshold_met = policy == "immediate" or int(incident.get("failureCount", 0)) >= 2
    if not threshold_met:
        return False, "waiting-for-second-failure"
    if incident.get("notified", False):
        return False, "continuous-incident-already-notified"
    if incident.get("repairQueued", False):
        return False, "autonomous-repair-already-queued"
    return True, "policy-threshold-met"


def update_incidents(
    payload: dict[str, Any], recover_absent: bool = True,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    state = incident_state()
    tools: dict[str, dict[str, Any]] = state["tools"]
    initialized = bool(state.get("initialized"))
    items_by_id = {item["id"]: item for item in payload.get("items", []) if isinstance(item, dict) and item.get("id")}
    queued: list[dict[str, Any]] = []

    for item_id, item in items_by_id.items():
        failed = RANK.get(item.get("state", "unknown"), 1) >= 2
        existing = tools.get(item_id)
        if not failed:
            if existing:
                existing["healthyCount"] = int(existing.get("healthyCount", 0)) + 1
                existing["lastSeenAt"] = iso()
                reason = "recovery-pending"
                if existing["healthyCount"] >= RECOVERY_SCANS:
                    del tools[item_id]
                    reason = "recovered-silently"
                append_decision({"at": iso(), "tool": item_id, "decision": reason})
            continue

        fingerprint = item_fingerprint(item)
        if not existing or existing.get("fingerprint") != fingerprint:
            existing = {
                "fingerprint": fingerprint,
                "causeCode": item.get("causeCode"),
                "failureCount": 1,
                "healthyCount": 0,
                "notified": False,
                "deadlineNotified": False,
                "firstSeenAt": iso(),
                "lastSeenAt": iso(),
            }
            tools[item_id] = existing
        else:
            existing["failureCount"] = int(existing.get("failureCount", 0)) + 1
            existing["healthyCount"] = 0
            existing["lastSeenAt"] = iso()

        if existing.get("repairQueued") and not active_repair_exists(item_id, fingerprint):
            prior_request = latest_request(item_id, fingerprint)
            if (prior_request or {}).get("status") not in {"denied", "dismissed", "revoked"}:
                # A terminal repair record must not strand a still-failing item.
                # Live and deferred work always has a queue/pending file; if both
                # disappeared, the old flag is orphaned and Luna must try again.
                existing["repairQueued"] = False
                existing["notified"] = False
                existing.pop("repairQueuedAt", None)
                append_decision({
                    "at": iso(), "tool": item_id, "fingerprint": fingerprint,
                    "decision": "orphaned-repair-flag-cleared",
                })

        if not initialized:
            decision = "baseline-seeded"
            send = False
        else:
            send, decision = should_queue_repair(item, existing)
        if send:
            queued.append({
                "id": item_id,
                "fingerprint": fingerprint,
                "title": str(item.get("name") or item_id),
                "body": str(item.get("headline") or "The tool failed"),
                "createdAt": iso(),
                "deadline": decision == "deadline-crossed",
                "item": item,
            })
        append_decision({
            "at": iso(), "tool": item_id, "fingerprint": fingerprint,
            "policy": item.get("notificationPolicy") or "consecutive",
            "failureCount": existing["failureCount"], "decision": decision,
        })

    if recover_absent:
        for item_id in list(tools.keys() - items_by_id.keys()):
            existing = tools[item_id]
            existing["healthyCount"] = int(existing.get("healthyCount", 0)) + 1
            existing["lastSeenAt"] = iso()
            reason = "recovery-pending"
            if existing["healthyCount"] >= RECOVERY_SCANS:
                del tools[item_id]
                reason = "recovered-silently"
            append_decision({"at": iso(), "tool": item_id, "decision": reason})

    state["initialized"] = True
    state["updatedAt"] = iso()
    atomic_json(INCIDENTS, state)
    return state, queued


def enqueue_repairs(queued: list[dict[str, Any]], state: dict[str, Any]) -> None:
    REPAIR_QUEUE.mkdir(parents=True, exist_ok=True)
    for entry in queued:
        incident = state["tools"].get(entry["id"])
        if not incident or incident.get("fingerprint") != entry.get("fingerprint"):
            continue
        key = hashlib.sha256(f"{entry['id']}|{entry['fingerprint']}".encode("utf-8")).hexdigest()[:24]
        job = {
            "schemaVersion": 1,
            "id": entry["id"],
            "fingerprint": entry["fingerprint"],
            "item": entry["item"],
            "createdAt": entry["createdAt"],
            "attempts": 0,
            "nextAttemptAt": entry["createdAt"],
        }
        path = REPAIR_QUEUE / f"{key}.json"
        if not path.exists():
            atomic_json(path, job)
            append_decision({
                "at": iso(), "tool": entry["id"], "fingerprint": entry["fingerprint"],
                "decision": "autonomous-repair-queued",
            })
        incident["repairQueued"] = True
        incident["repairQueuedAt"] = iso()


def main() -> int:
    arguments = sys.argv[1:]
    if any(value != "--live-auth" for value in arguments):
        print("usage: tool-status-background-scan.py [--live-auth]", file=sys.stderr)
        return 2
    live_auth = "--live-auth" in arguments
    lock = acquire_lock()
    if lock is None:
        # Exiting 0 here made contention indistinguishable from a healthy run:
        # no item, no incident, no notification, one decision-log line. That is
        # how the scan stayed starved for hours while the dashboard kept showing
        # a frozen snapshot. Waiting out a peer is normal; failing to get the
        # lock for LOCK_WAIT_SECONDS is a real fault and must surface as one.
        append_decision({"at": iso(), "tool": "Tool Dashboard Scanner", "decision": "overlap-skipped"})
        payload = load_json(CACHE, {})
        items = list(payload.get("items", [])) if isinstance(payload, dict) else []
        items = [item for item in items if item.get("id") != "Background Job:Tool Status Dashboard Scanner"]
        items.append(scanner_failure_item(
            f"Another scan held {LOCK} for more than {LOCK_WAIT_SECONDS}s, so this cycle could not run. "
            "Status shown in the dashboard is not being refreshed.",
            headline="The background status scan could not acquire its lock",
        ))
        payload = {
            "schemaVersion": 2,
            "generatedAt": iso(),
            "liveAuth": False,
            "items": items,
        }
        atomic_json(CACHE, payload)
        incidents_lock = acquire_incidents_lock()
        try:
            state, queued = update_incidents(payload, recover_absent=False)
            enqueue_repairs(queued, state)
            atomic_json(INCIDENTS, state)
        finally:
            fcntl.lockf(incidents_lock.fileno(), fcntl.LOCK_UN)
            incidents_lock.close()
        return 1
    try:
        payload, scan_ok, scan_rc = scan(live_auth=live_auth)
        atomic_json(CACHE, payload)
        if scan_ok:
            reconcile_registry(payload)
        incidents_lock = acquire_incidents_lock()
        try:
            state, queued = update_incidents(payload, recover_absent=scan_ok)
            enqueue_repairs(queued, state)
            atomic_json(INCIDENTS, state)
        finally:
            fcntl.lockf(incidents_lock.fileno(), fcntl.LOCK_UN)
            incidents_lock.close()
        atomic_json(OUTBOX, [])
        if scan_ok:
            atomic_json(HEARTBEAT, {"completedAt": iso(), "itemCount": len(payload.get("items", []))})
        return scan_rc
    finally:
        fcntl.lockf(lock.fileno(), fcntl.LOCK_UN)
        lock.close()


if __name__ == "__main__":
    raise SystemExit(main())
