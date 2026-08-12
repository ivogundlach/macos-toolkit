#!/usr/bin/python3
"""Focused regression checks for the Dashboard's GWS browser launcher."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "gws-auth-login.py"
spec = importlib.util.spec_from_file_location("gws_auth_login", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def executable(path: Path, content: str) -> Path:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)
    return path


def run_helper(gws: Path, opener: Path, timeout: float = 2.0, reset: bool = False) -> subprocess.CompletedProcess[str]:
    command = [
            "/usr/bin/python3",
            str(HELPER),
            "--gws-bin",
            str(gws),
            "--open-bin",
            str(opener),
            "--url-timeout",
            str(timeout),
        ]
    if reset:
        command.append("--reset-existing")
    return subprocess.run(
        command,
        text=True,
        capture_output=True,
        timeout=5,
        check=False,
    )


def main() -> int:
    valid, rejected = module.google_oauth_url(
        "prefix https://accounts.google.com/o/oauth2/auth?x=1 suffix"
    )
    assert valid == "https://accounts.google.com/o/oauth2/auth?x=1"
    assert not rejected
    valid, rejected = module.google_oauth_url(
        "https://evil.example/o/oauth2/auth?x=1"
    )
    assert valid is None and rejected

    with tempfile.TemporaryDirectory(prefix="gws-auth-login-test-") as temp:
        tmp = Path(temp)
        opened = tmp / "opened.txt"
        opener = executable(
            tmp / "open",
            "#!/usr/bin/python3\n"
            "import os, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['OPENED_PATH']).write_text(sys.argv[1], encoding='utf-8')\n",
        )
        env = os.environ.copy()
        env["OPENED_PATH"] = str(opened)

        expected = ",".join(module.SCOPES)
        good_gws = executable(
            tmp / "good-gws",
            "#!/usr/bin/python3\n"
            "import sys\n"
            "if sys.argv[1:4] == ['drive', 'about', 'get']:\n"
            "    raise SystemExit(0)\n"
            f"assert sys.argv[1:] == ['auth', 'login', '--scopes', {expected!r}]\n"
            "print('Open this URL in your browser to authenticate:', flush=True)\n"
            "print('  https://accounts.google.com/o/oauth2/auth?test=1', flush=True)\n"
            "print('drained-after-url', flush=True)\n",
        )
        good = subprocess.run(
            [
                "/usr/bin/python3",
                str(HELPER),
                "--gws-bin",
                str(good_gws),
                "--open-bin",
                str(opener),
                "--url-timeout",
                "2",
            ],
            env=env,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        assert good.returncode == 0, good.stderr
        assert "drained-after-url" in good.stdout
        assert opened.read_text(encoding="utf-8") == (
            "https://accounts.google.com/o/oauth2/auth?test=1"
        )

        opened.unlink()
        reset_log = tmp / "reset-log.txt"
        reset_gws = executable(
            tmp / "reset-gws",
            "#!/usr/bin/python3\n"
            "import os, sys\n"
            "from pathlib import Path\n"
            "log=Path(os.environ['RESET_LOG'])\n"
            "with log.open('a', encoding='utf-8') as handle: handle.write(' '.join(sys.argv[1:]) + '\\n')\n"
            "if sys.argv[1:3] == ['auth', 'logout']: raise SystemExit(0)\n"
            "if sys.argv[1:4] == ['drive', 'about', 'get']: raise SystemExit(0)\n"
            "print('https://accounts.google.com/o/oauth2/auth?reset=1', flush=True)\n",
        )
        reset = subprocess.run(
            [
                "/usr/bin/python3", str(HELPER), "--gws-bin", str(reset_gws),
                "--open-bin", str(opener), "--url-timeout", "2", "--reset-existing",
            ],
            env={**env, "RESET_LOG": str(reset_log)}, text=True,
            capture_output=True, timeout=5, check=False,
        )
        assert reset.returncode == 0, reset.stderr
        reset_calls = reset_log.read_text(encoding="utf-8").splitlines()
        assert reset_calls[0] == "auth logout"
        assert reset_calls[1].startswith("auth login --scopes ")
        assert reset_calls[2].startswith("drive about get --params ")

        opened.unlink()
        bad_gws = executable(
            tmp / "bad-gws",
            "#!/usr/bin/python3\n"
            "print('https://evil.example/o/oauth2/auth?test=1', flush=True)\n"
            "raise SystemExit(2)\n",
        )
        bad = run_helper(bad_gws, opener)
        assert bad.returncode == 2
        assert not opened.exists()
        assert "outside the allowed Google OAuth endpoint" in bad.stderr

        slow_gws = executable(
            tmp / "slow-gws",
            "#!/usr/bin/python3\nimport time\ntime.sleep(5)\n",
        )
        timed_out = run_helper(slow_gws, opener, timeout=0.2)
        assert timed_out.returncode == 124
        assert "did not provide a Google sign-in URL" in timed_out.stderr

    print("gws-auth-login tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
