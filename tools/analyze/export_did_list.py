"""Turn a local discovery.json into the DID list bundled with the app.

Usage:
    python3 tools/analyze/export_did_list.py data/discovery/<file>.json [os_version]

Writes app/assets/signals/sweep_os-<version>.json with only the module and
DID of each positive response. Sample values are dropped, because some of
them (F190) contain the VIN and the repo is public.
"""

from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def main(argv: list[str]) -> None:
    if not argv:
        sys.exit(__doc__)
    src = Path(argv[0])
    os_version = argv[1] if len(argv) > 1 else "2.2.3"
    sweep = json.loads(src.read_text())

    dids: dict[str, list[str]] = {}
    for hit in sweep.get("hits", []):
        if "nrc" in hit:
            continue  # refused: exists, but gives no data
        dids.setdefault(hit["mod"], []).append(hit["did"])
    for m in dids:
        dids[m] = sorted(set(dids[m]))

    out = {
        "os_version": os_version,
        "ranges": sweep.get("ranges"),
        "exported": date.today().isoformat(),
        "notes": "DIDs that returned data in a discovery sweep (PLAN.md §6.3). Values are left out on purpose.",
        "dids": dict(sorted(dids.items())),
    }
    dest = REPO / "app" / "assets" / "signals" / f"sweep_os-{os_version}.json"
    dest.write_text(json.dumps(out, indent=2) + "\n")
    print(f"{dest.relative_to(REPO)}: {sum(len(v) for v in dids.values())} DIDs")


if __name__ == "__main__":
    main(sys.argv[1:])
