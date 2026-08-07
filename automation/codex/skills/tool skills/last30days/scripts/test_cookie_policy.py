#!/usr/bin/env python3
"""Focused offline checks for Ivo's automatic local-cookie policy."""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from lib import cookie_extract, env, setup_wizard  # noqa: E402

SPEC = importlib.util.spec_from_file_location("last30days_main", SCRIPT_DIR / "last30days.py")
assert SPEC and SPEC.loader
last30days_main = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(last30days_main)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def namespace(**overrides):
    values = {"no_browser_cookies": False, "diagnose": False, "preflight": False}
    values.update(overrides)
    return argparse.Namespace(**values)


def main() -> int:
    checks: list[str] = []

    with patch("lib.env.platform.system", return_value="Darwin"):
        check(env.cookie_extraction_browsers({}) == ["safari", "firefox"], "macOS default order is wrong")
        check(env.cookie_extraction_browsers({"FROM_BROWSER": "off"}) == [], "explicit cookie opt-out failed")
        check(env.cookie_extraction_browsers({"FROM_BROWSER": "firefox"}) == ["firefox"], "explicit browser pin failed")
    checks.append("browser_defaults_and_optout")

    check(last30days_main._setup_allows_browser_cookies(namespace(), []) is True, "setup does not allow cookies by default")
    check(
        last30days_main._setup_allows_browser_cookies(namespace(), ["--allow-browser-cookies"]) is True,
        "legacy compatibility flag changed behavior",
    )
    check(
        last30days_main._setup_allows_browser_cookies(namespace(no_browser_cookies=True), []) is False,
        "--no-browser-cookies did not disable setup reads",
    )
    last30days_main._validate_extra_argv(
        argparse.ArgumentParser(), "setup", ["--allow-browser-cookies"]
    )
    checks.append("setup_default_and_legacy_compatibility")

    normal_policy = last30days_main._config_policy_for_args(namespace(), "topic", [])
    safe_policy = last30days_main._config_policy_for_args(namespace(preflight=True), "topic", [])
    off_policy = last30days_main._config_policy_for_args(namespace(no_browser_cookies=True), "topic", [])
    check(normal_policy.browser_cookies == "read", "normal run is not cookie-enabled")
    check(safe_policy.browser_cookies == "plan_only", "preflight would read cookie values")
    check(off_policy.browser_cookies == "off", "explicit opt-out policy failed")
    checks.append("safe_preflight_policy")

    calls: list[tuple[str, str]] = []

    def fake_extract(browser: str, domain: str, names: list[str]):
        calls.append((browser, domain))
        if browser == "safari":
            raise PermissionError("Operation not permitted")
        return ({name: "must-not-escape" for name in names}, browser)

    with patch("lib.env.platform.system", return_value="Darwin"), \
         patch.object(cookie_extract, "extract_cookies_with_source", fake_extract), \
         patch.object(setup_wizard, "_install_digg_cli", return_value=(True, "already_installed", "", None)), \
         patch.object(setup_wizard, "install_default_pp_sources", return_value={}), \
         patch.object(setup_wizard.shutil, "which", return_value="/fake/tool"):
        result = setup_wizard.run_auto_setup({})
    check(result["cookies_found"].get("x") == "firefox", "Safari failure did not fall back to Firefox")
    check(calls[:2] == [("safari", ".x.com"), ("firefox", ".x.com")], "Safari/Firefox attempt order wrong")
    check("must-not-escape" not in json.dumps(result), "raw cookie value escaped setup")
    checks.append("safari_tcc_firefox_fallback")

    with tempfile.TemporaryDirectory(prefix="last30days-cookie-policy-") as temp:
        config_file = Path(temp) / ".env"
        config_file.write_text("SETUP_COMPLETE=true\n", encoding="utf-8")
        config_file.chmod(0o600)
        policy = env.ConfigLoadPolicy(browser_cookies="plan_only")
        with patch.object(env, "CONFIG_FILE", config_file), \
             patch.object(env, "extract_browser_credentials", side_effect=AssertionError("cookie values read")):
            config = env.get_config(policy=policy)
        check(config["_BROWSER_COOKIE_MODE"] == "plan_only", "safe inspection mode missing")
    checks.append("preflight_does_not_read_values")

    skill_text = (SCRIPT_DIR.parent / "SKILL.md").read_text(encoding="utf-8")
    check("BROWSER_CONSENT" not in skill_text, "retired consent flag remains in skill contract")
    checks.append("consent_gate_retired")

    print(json.dumps({"status": "ok", "checks": checks, "count": len(checks)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
