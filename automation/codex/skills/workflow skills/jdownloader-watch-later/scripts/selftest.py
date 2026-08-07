#!/usr/bin/env python3
"""Isolated regression checks for the JDownloader playlist workflow."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ENUMERATOR = ROOT / "enumerate-youtube-playlist.py"
PLAYLIST = ROOT / "youtube-playlist-to-jdownloader.sh"
WATCH_LATER = ROOT / "watch-later-to-jdownloader.sh"
WATCHER = ROOT / "quit-jdownloader-on-complete.sh"
LAUNCHER = ROOT / "launch-quit-watcher.sh"
URLS = [
    "https://www.youtube.com/watch?v=aaaaaaaaaaa",
    "https://www.youtube.com/watch?v=bbbbbbbbbbb",
]


def write_executable(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(0o755)


def run(command: list[str], env: dict[str, str], timeout: int = 20) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, env=env, timeout=timeout, check=False)


class EnumeratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="jd-enumerator-test-")
        self.root = Path(self.temp.name)
        self.log = self.root / "attempts.log"
        self.fake = self.root / "yt-dlp"
        write_executable(
            self.fake,
            """#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
browser = None
if '--cookies-from-browser' in args:
    browser = args[args.index('--cookies-from-browser') + 1]
with open(os.environ['FAKE_ATTEMPT_LOG'], 'a') as handle:
    handle.write((browser or 'public') + '\\n')
mode = os.environ.get('FAKE_YTDLP_MODE', 'success')
if mode == 'timeout':
    time.sleep(3)
if mode == 'fallback' and browser is None:
    print('ERROR: Sign in to confirm you are not a bot', file=sys.stderr)
    raise SystemExit(1)
if mode == 'forbidden' and browser is None:
    print('ERROR: Unable to download API page: HTTP Error 403: Forbidden', file=sys.stderr)
    raise SystemExit(1)
if mode == 'safari_tcc' and browser == 'safari':
    print('ERROR: Operation not permitted while reading Safari Cookies', file=sys.stderr)
    raise SystemExit(1)
if mode == 'secret':
    print('ERROR auth_token=topsecret Cookie:sessionsecret Authorization: Bearer bearersecret sign in required', file=sys.stderr)
    raise SystemExit(1)
if mode == 'empty':
    print(json.dumps({'title': 'Empty fixture', 'entries': []}))
    raise SystemExit(0)
print(json.dumps({'title': 'Fixture', 'entries': [
    {'id': 'aaaaaaaaaaa'},
    {'url': 'https://youtu.be/bbbbbbbbbbb'},
    {'id': 'bad'},
    {'id': 'aaaaaaaaaaa'}
]}))
""",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def invoke(self, *args: str, mode: str = "success") -> tuple[subprocess.CompletedProcess[str], dict]:
        env = {
            **os.environ,
            "YTDLP": str(self.fake),
            "FAKE_ATTEMPT_LOG": str(self.log),
            "FAKE_YTDLP_MODE": mode,
        }
        proc = run(["/usr/bin/python3", str(ENUMERATOR), "--source", "https://example.test/list", *args], env)
        return proc, json.loads(proc.stdout)

    def test_public_success_normalizes_and_reports_malformed_entries(self) -> None:
        proc, payload = self.invoke("--mode", "public", "--no-browser-cookies")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["status"], "partial")
        self.assertEqual(payload["result"]["urls"], URLS)
        self.assertEqual(self.log.read_text().splitlines(), ["public"])

    def test_public_auth_barrier_falls_back_to_safari(self) -> None:
        proc, payload = self.invoke("--mode", "public", mode="fallback")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["browser_path"], "safari")
        self.assertTrue(payload["authenticated_read_performed"])
        self.assertEqual(self.log.read_text().splitlines(), ["public", "safari"])

    def test_public_403_falls_back_to_safari(self) -> None:
        proc, payload = self.invoke("--mode", "public", mode="forbidden")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["browser_path"], "safari")
        self.assertEqual(payload["attempts"][0]["error_code"], "public_access_forbidden")
        self.assertEqual(self.log.read_text().splitlines(), ["public", "safari"])

    def test_safari_tcc_failure_falls_back_to_firefox(self) -> None:
        proc, payload = self.invoke("--mode", "auth", mode="safari_tcc")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["browser_path"], "firefox")
        self.assertEqual(self.log.read_text().splitlines(), ["safari", "firefox"])

    def test_explicit_browser_is_strict(self) -> None:
        proc, payload = self.invoke("--mode", "auth", "--browser", "firefox", mode="safari_tcc")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["browser_path"], "firefox")
        self.assertEqual(self.log.read_text().splitlines(), ["firefox"])

    def test_timeout_is_structured(self) -> None:
        proc, payload = self.invoke("--mode", "public", "--no-browser-cookies", "--timeout", "1", mode="timeout")
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(payload["error"]["code"], "network_timeout")

    def test_empty_accessible_playlist_is_a_clean_noop(self) -> None:
        proc, payload = self.invoke("--mode", "public", "--no-browser-cookies", mode="empty")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["result"]["entry_count"], 0)
        self.assertEqual(payload["result"]["urls"], [])

    def test_diagnostics_redact_cookie_secrets(self) -> None:
        proc, payload = self.invoke("--mode", "public", "--no-browser-cookies", mode="secret")
        self.assertEqual(proc.returncode, 1)
        serialized = json.dumps(payload)
        for secret in ("topsecret", "sessionsecret", "bearersecret"):
            self.assertNotIn(secret, serialized)
        self.assertIn("[REDACTED]", serialized)


class WorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="jd-workflow-test-")
        self.root = Path(self.temp.name)
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        self.state = self.root / "state"
        self.jd_home = self.root / "JDownloader 2"
        self.cfg = self.jd_home / "cfg"
        self.cfg.mkdir(parents=True)
        self.watch = self.cfg / "folderwatch"
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        self.enum_log = self.root / "enumerator.log"
        self.curl_log = self.root / "curl.log"
        self.open_log = self.root / "open.log"
        self.watcher_log = self.root / "watcher.log"
        self.launcher = self.root / "fake-launcher"
        self.enumerator = self.root / "enumerator.py"
        self.watcher = self.root / "fake-watcher.py"
        self.settings = self.cfg / "org.jdownloader.gui.views.linkgrabber.addlinksdialog.LinkgrabberSettings.json"
        self.auth = self.cfg / "org.jdownloader.api.RemoteAPIConfig.externinterfaceauth.json"
        self.settings.write_text('{"linkgrabberautoconfirmenabled":false,"linkgrabberautostartenabled":false}\n')
        self.auth.write_text('[]\n')
        write_executable(
            self.enumerator,
            """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_ENUM_LOG'], 'a') as handle:
    handle.write(' '.join(sys.argv[1:]) + '\\n')
auth = '--mode' in sys.argv and sys.argv[sys.argv.index('--mode') + 1] == 'auth'
print(json.dumps({
  'schema_version': 1, 'status': 'ok', 'notify_user': False,
  'network_performed': True, 'authenticated_read_performed': auth,
  'browser_path': 'safari' if auth else None,
  'attempts': [{'method': 'fixture', 'status': 'ok'}],
  'degradation_reasons': [],
  'result': {'urls': [
    'https://www.youtube.com/watch?v=aaaaaaaaaaa',
    'https://www.youtube.com/watch?v=bbbbbbbbbbb'
  ]}
}))
""",
        )
        write_executable(
            self.fakebin / "curl",
            """#!/usr/bin/env python3
import os, sys
with open(os.environ['FAKE_CURL_LOG'], 'a') as handle:
    handle.write(' '.join(sys.argv[1:]) + '\\n')
if os.environ.get('FAKE_CURL_MODE') == 'unreachable':
    raise SystemExit(7)
print('success' if any(arg.endswith('/flash/add') for arg in sys.argv) else 'OK')
""",
        )
        write_executable(
            self.fakebin / "open",
            """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_OPEN_LOG"
""",
        )
        write_executable(
            self.watcher,
            """#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
def value(flag): return args[args.index(flag) + 1]
ready, nonce = value('--ready-file'), value('--run-nonce')
with open(os.environ['FAKE_WATCHER_LOG'], 'a') as handle:
    handle.write(' '.join(args) + '\\n')
temp = ready + '.tmp'
with open(temp, 'w') as handle:
    json.dump({'pid': os.getpid(), 'run_nonce': nonce}, handle)
os.chmod(temp, 0o600)
os.replace(temp, ready)
time.sleep(1)
""",
        )
        write_executable(
            self.launcher,
            """#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_WATCHER_LOG"
case "$*" in *unready-watcher*) exit 1;; esac
exit 0
""",
        )
        self.env = {
            **os.environ,
            "PATH": f"{self.fakebin}:{os.environ['PATH']}",
            "JDOWNLOADER_STATE_DIR": str(self.state),
            "JDOWNLOADER_HOME": str(self.jd_home),
            "JDOWNLOADER_FOLDERWATCH_DIR": str(self.watch),
            "JDOWNLOADER_PLAYLIST_ENUMERATOR": str(self.enumerator),
            "JDOWNLOADER_QUIT_WATCHER": str(self.watcher),
            "JDOWNLOADER_WATCHER_LAUNCHER": str(self.launcher),
            "FAKE_ENUM_LOG": str(self.enum_log),
            "FAKE_CURL_LOG": str(self.curl_log),
            "FAKE_OPEN_LOG": str(self.open_log),
            "FAKE_WATCHER_LOG": str(self.watcher_log),
        }

    def tearDown(self) -> None:
        time.sleep(1.1)
        self.temp.cleanup()

    def invoke_playlist(self, *args: str, **env_updates: str) -> subprocess.CompletedProcess[str]:
        return run(
            [str(PLAYLIST), "--playlist", "ai", "--download-dir", str(self.downloads), *args],
            {**self.env, **env_updates},
        )

    def invoke_watch_later(self, *args: str, **env_updates: str) -> subprocess.CompletedProcess[str]:
        return run(
            [str(WATCH_LATER), "--download-dir", str(self.downloads), *args],
            {**self.env, **env_updates},
        )

    def test_dry_runs_do_not_mutate_state_or_jdownloader_config(self) -> None:
        settings_before = self.settings.read_bytes()
        auth_before = self.auth.read_bytes()
        first = self.invoke_playlist("--dry-run", "--method", "cnl")
        second = self.invoke_watch_later("--dry-run", "--method", "folderwatch")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.watch.exists())
        self.assertEqual(self.settings.read_bytes(), settings_before)
        self.assertEqual(self.auth.read_bytes(), auth_before)
        self.assertIn("authenticated_read_performed", second.stderr)

    def test_click_and_load_commits_state_and_starts_ready_watcher(self) -> None:
        proc = self.invoke_playlist("--method", "cnl")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        state_file = self.state / "sent-ai-playlist-urls.txt"
        self.assertEqual(state_file.read_text().splitlines(), URLS)
        self.assertIn("/flash/add", self.curl_log.read_text())
        self.assertIn("--marker", self.watcher_log.read_text())
        self.assertIn("will quit after downloads complete", proc.stderr)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertEqual(state_file.stat().st_mode & 0o777, 0o600)

    def test_watch_later_folderwatch_job_autostarts_and_watcher_is_ready(self) -> None:
        proc = self.invoke_watch_later("--method", "folderwatch")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        jobs = list(self.watch.glob("watchlater-*.crawljob"))
        self.assertEqual(len(jobs), 1)
        job = json.loads(jobs[0].read_text())
        self.assertEqual([item["text"] for item in job], URLS)
        self.assertTrue(all(item["autoStart"] == "TRUE" for item in job))
        self.assertTrue((self.state / "sent-watch-later-urls.txt").exists())
        self.assertIn("--marker", self.watcher_log.read_text())

    def test_missing_watcher_reports_partial_after_successful_submission(self) -> None:
        proc = self.invoke_playlist(
            "--method", "cnl",
            JDOWNLOADER_QUIT_WATCHER=str(self.root / "missing-watcher"),
        )
        self.assertEqual(proc.returncode, 3)
        self.assertIn("PARTIAL", proc.stderr)
        self.assertTrue((self.state / "sent-ai-playlist-urls.txt").exists())
        self.assertEqual(list(self.state.glob("run-marker.*")), [])

    def test_unready_watcher_reports_partial_and_cleans_marker(self) -> None:
        unready = self.root / "unready-watcher"
        write_executable(unready, "#!/usr/bin/env bash\nexit 0\n")
        proc = self.invoke_playlist(
            "--method", "cnl",
            JDOWNLOADER_QUIT_WATCHER=str(unready),
        )
        self.assertEqual(proc.returncode, 3)
        self.assertIn("did not become ready", proc.stderr)
        self.assertTrue((self.state / "sent-ai-playlist-urls.txt").exists())
        self.assertEqual(list(self.state.glob("run-marker.*")), [])
        self.assertEqual(list(self.state.glob("watcher-ready-*.json")), [])

    def test_keep_open_submits_without_starting_watcher_or_leaking_marker(self) -> None:
        proc = self.invoke_playlist("--method", "cnl", "--keep-open")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue((self.state / "sent-ai-playlist-urls.txt").exists())
        self.assertFalse(self.watcher_log.exists())
        self.assertEqual(list(self.state.glob("run-marker.*")), [])

    def test_forced_cnl_unavailable_fails_without_committing_sent_state(self) -> None:
        proc = self.invoke_playlist(
            "--method", "cnl", "--keep-open",
            FAKE_CURL_MODE="unreachable",
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Click'n'Load is not reachable", proc.stderr)
        self.assertEqual((self.state / "sent-ai-playlist-urls.txt").read_text(), "")
        self.assertEqual(list(self.state.glob("run-marker.*")), [])

    def test_auto_mode_launches_then_falls_back_to_folderwatch(self) -> None:
        fastbin = self.root / "fastbin"
        fastbin.mkdir()
        write_executable(fastbin / "sleep", "#!/usr/bin/env bash\nexit 0\n")
        proc = self.invoke_playlist(
            "--keep-open",
            FAKE_CURL_MODE="unreachable",
            PATH=f"{fastbin}:{self.env['PATH']}",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("-gj -a JDownloader2", self.open_log.read_text())
        self.assertEqual(len(list(self.watch.glob("playlist-*.crawljob"))), 1)
        self.assertTrue((self.state / "sent-ai-playlist-urls.txt").exists())
        self.assertEqual(list(self.state.glob("run-marker.*")), [])

    def test_no_autostart_preserves_settings_and_disables_job_autostart(self) -> None:
        settings_before = self.settings.read_bytes()
        proc = self.invoke_watch_later("--method", "folderwatch", "--no-autostart", "--keep-open")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        job_path = next(self.watch.glob("watchlater-*.crawljob"))
        job = json.loads(job_path.read_text())
        self.assertTrue(all(item["autoStart"] == "FALSE" for item in job))
        self.assertEqual(self.settings.read_bytes(), settings_before)
        self.assertEqual(list(self.state.glob("run-marker.*")), [])

    def test_sent_state_resends_when_download_folder_is_empty(self) -> None:
        self.state.mkdir(mode=0o700)
        state_file = self.state / "sent-ai-playlist-urls.txt"
        state_file.write_text("\n".join(URLS) + "\n")
        proc = self.invoke_playlist("--dry-run", "--method", "folderwatch")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Resending all URLs", proc.stderr)
        self.assertEqual(proc.stdout.splitlines(), URLS)

    def test_sent_state_suppresses_duplicates_when_media_exists(self) -> None:
        self.state.mkdir(mode=0o700)
        state_file = self.state / "sent-ai-playlist-urls.txt"
        state_file.write_text("\n".join(URLS) + "\n")
        (self.downloads / "existing.mp4").write_text("fixture")
        proc = self.invoke_playlist("--method", "cnl", "--keep-open")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("No new URLs to send", proc.stderr)
        self.assertFalse(self.curl_log.exists())
        self.assertEqual(state_file.read_text().splitlines(), URLS)
        self.assertEqual(list(self.state.glob("run-marker.*")), [])


class LauncherTests(unittest.TestCase):
    LABEL = "com.ivogundlach.jdownloader-watch-later.SELFTEST-NONCE"

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="jd-launcher-test-")
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        self.marker = self.state / "run-marker.test"
        self.marker.touch()
        self.complete = self.root / "completed"
        self.uuidgen = self.root / "uuidgen"
        self.watcher = self.root / "watcher"
        write_executable(self.uuidgen, "#!/bin/sh\necho SELFTEST-NONCE\n")
        write_executable(
            self.watcher,
            f"""#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --marker) marker="$2"; shift 2;;
    --ready-file) ready="$2"; shift 2;;
    --run-nonce) nonce="$2"; shift 2;;
    *) shift;;
  esac
done
printf '{{"pid":%d,"run_nonce":"%s"}}\n' "$$" "$nonce" > "$ready"
sleep 1
printf 'survived\n' > "{self.complete}"
rm -f "$ready" "$marker"
""",
        )

    def tearDown(self) -> None:
        subprocess.run(["/bin/launchctl", "remove", self.LABEL], capture_output=True, check=False)
        self.temp.cleanup()

    @unittest.skipUnless(Path("/bin/launchctl").exists(), "requires macOS launchctl")
    def test_launchd_watcher_survives_submitting_process_and_removes_job(self) -> None:
        env = {
            **os.environ,
            "JDOWNLOADER_UUIDGEN": str(self.uuidgen),
        }
        proc = run([
            str(LAUNCHER), "--state-dir", str(self.state),
            "--watcher", str(self.watcher), "--download-root", str(self.downloads),
            "--marker", str(self.marker),
        ], env, timeout=8)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not self.complete.exists():
            time.sleep(0.1)
        self.assertTrue(self.complete.exists(), "launchd watcher died with its submitting process")
        deadline = time.monotonic() + 3
        registered = True
        while time.monotonic() < deadline:
            check = subprocess.run(
                ["/bin/launchctl", "print", f"gui/{os.getuid()}/{self.LABEL}"],
                capture_output=True, check=False,
            )
            registered = check.returncode == 0
            if not registered:
                break
            time.sleep(0.1)
        self.assertFalse(registered, "one-shot launchd job leaked after watcher exit")


class WatcherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="jd-watcher-test-")
        self.root = Path(self.temp.name)
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        self.stopped = self.root / "stopped"
        self.quit_log = self.root / "quit-called"
        write_executable(
            self.fakebin / "pgrep",
            """#!/usr/bin/env bash
[[ ! -f "$FAKE_JD_STOPPED" ]]
""",
        )
        write_executable(
            self.fakebin / "osascript",
            """#!/usr/bin/env bash
touch "$FAKE_JD_STOPPED"
touch "$FAKE_QUIT_LOG"
""",
        )
        self.env = {
            **os.environ,
            "PATH": f"{self.fakebin}:{os.environ['PATH']}",
            "FAKE_JD_STOPPED": str(self.stopped),
            "FAKE_QUIT_LOG": str(self.quit_log),
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_activity_then_idle_quits_jdownloader(self) -> None:
        downloads = self.root / "downloads"
        downloads.mkdir()
        marker = self.root / "marker"
        marker.touch()
        time.sleep(1.1)
        (downloads / "finished.mp4").write_text("fixture")
        log = self.root / "watcher.log"
        proc = run([
            str(WATCHER), "--download-root", str(downloads), "--marker", str(marker),
            "--idle-seconds", "1", "--timeout-seconds", "8", "--poll-seconds", "1",
            "--log-file", str(log),
        ], self.env, timeout=12)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(self.quit_log.exists())
        self.assertIn("JDownloader quit", log.read_text())

    def test_no_activity_times_out_without_quitting(self) -> None:
        downloads = self.root / "empty"
        downloads.mkdir()
        marker = self.root / "marker"
        marker.touch()
        log = self.root / "watcher.log"
        proc = run([
            str(WATCHER), "--download-root", str(downloads), "--marker", str(marker),
            "--idle-seconds", "1", "--timeout-seconds", "1", "--poll-seconds", "1",
            "--log-file", str(log),
        ], self.env, timeout=5)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(self.quit_log.exists())
        self.assertIn("timeout reached; leaving JDownloader open", log.read_text())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
