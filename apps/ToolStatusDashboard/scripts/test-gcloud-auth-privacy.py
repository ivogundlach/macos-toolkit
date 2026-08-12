#!/usr/bin/env python3
"""Checks that Google Cloud health never persists account or token output."""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
from pathlib import Path


SCANNER = Path(__file__).with_name("tool-status-scan.py")


def main() -> int:
    spec = importlib.util.spec_from_file_location("tool_status_gcloud_test", SCANNER)
    assert spec and spec.loader
    scanner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scanner)

    with tempfile.TemporaryDirectory(prefix="tool-status-gcloud-test-") as temporary:
        root = Path(temporary)
        scanner.HOME = root
        scanner.PATH = f"{root}/bin:/usr/bin:/bin"
        fake = root / "bin/gcloud"
        fake.parent.mkdir(parents=True)
        log = root / "gcloud-calls.json"
        fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
log=Path(os.environ["FAKE_GCLOUD_LOG"])
log.write_text(json.dumps(sys.argv[1:]))
print("private-account@example.com ya29.secret-canary")
""", encoding="utf-8")
        fake.chmod(0o755)
        os.environ["FAKE_GCLOUD_LOG"] = str(log)
        adc = root / ".config/gcloud/application_default_credentials.json"
        adc.parent.mkdir(parents=True)
        adc.write_text('{"private_key":"secret-adc-canary"}\n', encoding="utf-8")

        original_command_record = scanner.command_record

        def only_gcloud(rows, name, binary, version_args=None, category="Custom CLI", **kwargs):
            if name == "Google Cloud CLI":
                return str(fake)
            return None

        scanner.command_record = only_gcloud
        scanner.which = lambda _name: None
        rows: list[dict] = []
        scanner.auth_records(rows, live_auth=True)
        scanner.command_record = original_command_record

        gcloud_rows = [row for row in rows if row["name"].startswith("Google Cloud")]
        persisted = json.dumps(gcloud_rows, sort_keys=True)
        assert "private-account@example.com" not in persisted
        assert "ya29.secret-canary" not in persisted
        assert "secret-adc-canary" not in persisted
        assert all(row["headline"] == "Configured" for row in gcloud_rows)
        assert json.loads(log.read_text()) == [
            "auth", "list", "--filter=status:ACTIVE", "--format=value(account)",
        ]

    print("Google Cloud auth privacy checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
