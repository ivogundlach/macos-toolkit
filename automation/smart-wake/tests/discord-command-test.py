#!/usr/bin/env python3

import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "discord-command-watch.py"
SPEC = importlib.util.spec_from_file_location("discord_command_watch", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def assert_equal(actual, expected):
    if actual != expected:
        raise AssertionError(f"expected {expected!r}, got {actual!r}")


assert_equal(MODULE.parse_command("status"), ("status", None))
assert_equal(MODULE.parse_command(" sleep "), ("off", None))
assert_equal(MODULE.parse_command("STOP"), ("off", None))
assert_equal(MODULE.parse_command("2h"), ("on", "2h"))
assert_equal(MODULE.parse_command("50 min"), ("on", "50min"))
assert_equal(MODULE.parse_command("90MIN"), ("on", "90min"))
assert_equal(MODULE.parse_command("12 hours"), ("on", "12hours"))
assert_equal(MODULE.parse_command("Received"), None)
assert_equal(MODULE.parse_command("wake forever"), None)

print("discord command tests passed")
