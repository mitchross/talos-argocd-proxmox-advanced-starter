#!/usr/bin/env python3
"""Validate starter-owned PrometheusRule expressions with promtool."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.stderr.write("pyyaml required: pip3 install pyyaml\n")
    sys.exit(2)


def main() -> int:
    promtool = shutil.which("promtool")
    if not promtool:
        sys.stderr.write("promtool is required\n")
        return 2

    groups = []
    for path in sorted(Path("monitoring").rglob("*.yaml")):
        if "charts" in path.parts:
            continue
        for doc in yaml.safe_load_all(path.read_text()):
            if isinstance(doc, dict) and doc.get("kind") == "PrometheusRule":
                groups.extend((doc.get("spec") or {}).get("groups") or [])

    if not groups:
        sys.stderr.write("no starter-owned PrometheusRule groups found\n")
        return 1

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as rules_file:
        yaml.safe_dump({"groups": groups}, rules_file, sort_keys=False)
        rules_file.flush()
        print(f"Validating {len(groups)} starter-owned Prometheus rule groups")
        return subprocess.run(
            [promtool, "check", "rules", rules_file.name], check=False
        ).returncode


if __name__ == "__main__":
    sys.exit(main())
