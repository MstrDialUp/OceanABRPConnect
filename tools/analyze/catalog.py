"""Build the public DID catalog (docs/fisker-ocean/did-catalog.md).

Usage:
    python3 tools/analyze/catalog.py <discovery.json> [session.jsonl ...]

Combines a local discovery sweep with recorded sessions: which DIDs each
module answers, their payload length, whether they changed during the
recordings, and what is known about them. The inputs are git-ignored
because they contain the VIN and GPS; the output only publishes values that
are the same on every Ocean (part numbers, supplier names, software
versions), never the VIN, serial numbers or values from the recordings.
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

from session import load, varying_bytes

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "docs" / "fisker-ocean" / "did-catalog.md"
SIGNALS = REPO / "packages" / "ocean_obd" / "assets" / "signals" / "ocean.json"

# ISO 14229 identification DIDs whose values are safe to publish: they're
# the same on every car with the same ECU part and software.
PUBLISH_VALUES = {
    "F183": "boot software id",
    "F186": "active diagnostic session",
    "F187": "spare part number",
    "F188": "ECU software number",
    "F18A": "supplier",
    "F191": "ECU hardware number",
    "F195": "software version",
}
# Named but never published (per-car or per-person).
WITHHELD = {
    "F108": "contains a VIN fragment",
    "F10A": "per-car data",
    "F184": "tester fingerprint (a person's user name)",
    "F18C": "ECU serial number",
    "F18F": "per-car data",
    "F190": "VIN",
    "F192": "per-car data",
    "F19B": "per-car data",
}
# What the ISO 14229 / common supplier DIDs are, for DIDs with no signal yet.
GENERIC = {
    "EFF5": "supplier status text (VCU: \"Key_is_written\")",
    "EFF6": "clock / timestamp (changes every read)",
    "EFF7": "vehicle speed ÷10 km/h (all modules except BMS)",
    "EFF8": "odometer ÷100 km (all modules except BMS)",
    "EFF9": "12 V supply ÷1000 V, per module",
    "EFFC": "supplier status byte",
    "EFFE": "supplier status byte",
}


# Observations from the 2026-09-29 drive for DIDs that aren't decoded yet.
# Candidates, not facts: see docs/fisker-ocean/README.md.
NOTES = {
    ("BMS", "EFF7"): "not speed on the BMS (small values, r = 0.57 against GPS speed)",
    ("BMS", "EFF8"): "not the odometer on the BMS: 00000000 in the sweep, only the last byte changed while driving",
    ("BMS", "2003"): "bytes 0–1 ÷10 ≈ 400–411 V: a smoother pack voltage",
    ("BMS", "2009"): "rose steadily 5244 → 5989 over the drive",
    ("BMS", "2011"): "byte 1 changes in steps; bytes 2–5 constant 0FF8 0FF8",
    ("BMS", "2016"): "int32 ×0.1 A tracks pack current but reads 0 at idle: probably drive current without auxiliaries",
    ("BMS", "2019"): "bytes 2–3 same as 2032 bytes 2–3; jumps around",
    ("BMS", "2026"): "0x87–0x89, very slow rise: a temperature with an offset?",
    ("BMS", "2031"): "0x8F → 0xA0 rising through the drive: a temperature? (also 2032 byte 0–1)",
    ("BMS", "2033"): "0x9A → 0xB0 rising through the drive: a temperature? (also 2034 byte 0–1)",
    ("BMS", "2041"): "5 bytes of state; changed a few times during the drive",
    ("BMS", "2042"): "last byte toggles 0/1",
    ("BMS", "2061"): "01 parked in Ready, 05 driving: a BMS or powertrain state",
    ("BMS", "2062"): "toggles 02/03",
    ("BMS", "2063"): "829–3238, varies a lot: a power limit?",
    ("BMS", "2064"): "0–738, varies: a regen/charge limit?",
    ("BMS", "2069"): "≈2600–2870: maybe isolation resistance",
    ("BMS", "2070"): "≈2600–2870: maybe isolation resistance",
    ("BMS", "2090"): "same as 2089 within 0.2: another battery temperature (÷100 °C?)",
    ("BMS", "2091"): "same as 2089 within 0.2: another battery temperature (÷100 °C?)",
    ("BMS", "2092"): "same as 2089 within 0.2: another battery temperature (÷100 °C?)",
    ("BMS", "2093"): "same as 2089 within 0.2: another battery temperature (÷100 °C?)",
    ("BMS", "2094"): "same as 2089 within 0.2: another battery temperature (÷100 °C?)",
    ("BMS", "2109"): "pack voltage ÷10 V, same as 2107 within 1 V",
    ("BMS", "2117"): "pack voltage ÷10 V, same as 2107 within 1 V",
    ("BMS", "2130"): "≈13.4–13.5 at ÷1000: BMS supply voltage?",
    ("BMS", "2137"): "cell voltage ÷1000 V, with 2136/2138 min/max/average",
    ("BMS", "2138"): "cell voltage ÷1000 V, with 2136/2137 min/max/average",
    ("BMS", "2144"): "bytes 1–2 rose 3683 → 3753 over a drive using ≈5.5 kWh: an energy counter (×0.1 kWh?)",
    ("BMS", "2145"): "bytes 1–2 rose 5357 → 5424 over the same drive: an energy counter?",
    ("BCM", "3403"): "00 → 01 when the doors locked after pulling away",
    ("BCM", "3404"): "pattern changed when the doors locked: per-door lock state?",
    ("BCM", "3407"): "8101 / 0100, changes with driving",
    ("BCM", "340E"): "42 / 40 in byte 0",
    ("BCM", "340F"): "AA00 → 0000 after pulling away",
    ("BCM", "341A"): "80 → 84 during the drive",
    ("BCM", "341B"): "00 → 64 when the TPMS sensors woke",
    ("BCM", "3428"): "000000 → B9 B9 C4 when the TPMS sensors woke: tyre temperatures?",
    ("ESP", "FD00"): "4 × uint16 wheel speeds, ≈0.0288 km/h per bit",
    ("ESP", "FD02"): "toggles 0/1 while driving",
    ("ESP", "FD33"): "11 bytes, all changing while driving",
}


def printable(b: bytes) -> str:
    text = "".join(chr(x) if 32 <= x < 127 else "·" for x in b).strip("· ")
    return text.replace("|", "/")


def main(argv: list[str]) -> None:
    if not argv:
        sys.exit(__doc__)
    sweep = json.loads(Path(argv[0]).read_text())
    sessions = [load(p) for p in argv[1:]]
    signals = json.loads(SIGNALS.read_text())["signals"]
    modules = json.loads(SIGNALS.read_text())["modules"]

    known: dict[tuple[str, str], list[str]] = defaultdict(list)
    for s in signals:
        tag = s["name"] + ("" if s.get("verified") else " (candidate)")
        known[(s["module"], s["did"])].append(tag)

    changed: dict[tuple[str, str], bool] = {}
    reads: dict[tuple[str, str], int] = defaultdict(int)
    for sess in sessions:
        for key, samples in sess.dids.items():
            reads[key] += len(samples)
            if varying_bytes([b for _, b in samples]):
                changed[key] = True
            else:
                changed.setdefault(key, False)

    hits = defaultdict(list)
    refused = defaultdict(list)
    for h in sweep["hits"]:
        (refused if "nrc" in h else hits)[h["mod"]].append(h)

    lines: list[str] = []
    w = lines.append
    w("# Fisker Ocean DID catalog")
    w("")
    w("Generated by `tools/analyze/catalog.py` from a discovery sweep and recorded sessions "
      "(Ocean OS 2.2.3, 2026-09-28/29). Service `0x22` ReadDataByIdentifier, 11-bit CAN, 500 kbps. "
      f"Ranges swept on every module: `{sweep.get('ranges')}`. "
      "See [README.md](README.md) for how to read these and what's decoded.")
    w("")
    w("Columns: **len** is the data length in bytes after the DID echo. **live** is yes if the value changed "
      "during the recordings, no if it stayed constant, and blank if it wasn't recorded. Per-car values "
      "(VIN, serial numbers) are withheld.")
    w("")
    total = sum(len(v) for v in hits.values())
    w(f"{total} DIDs returned data; {sum(len(v) for v in refused.values())} exist but refused (NRC shown).")
    w("")
    for mod in modules:
        mod_hits = sorted(hits.get(mod, []), key=lambda h: h["did"])
        ids = modules[mod]
        w(f"## {mod} (request {ids['tx']}, response {ids['rx']})")
        w("")
        if not mod_hits:
            w("No DIDs returned data in the swept ranges.")
            w("")
            continue
        w("| DID | len | live | meaning |")
        w("|---|---|---|---|")
        for h in mod_hits:
            did = h["did"]
            data = bytes.fromhex(h.get("sample", ""))
            key = (mod, did)
            live = {True: "yes", False: "no"}.get(changed.get(key), "")
            if key in known:
                meaning = "; ".join(known[key])
            elif key in NOTES:
                meaning = NOTES[key] + " (observed)"
            elif did in PUBLISH_VALUES:
                value = printable(data)
                meaning = f"{PUBLISH_VALUES[did]}: `{value}`" if value else PUBLISH_VALUES[did]
            elif did in WITHHELD:
                meaning = f"{WITHHELD[did]} (withheld)"
            elif did in GENERIC:
                meaning = GENERIC[did]
            else:
                meaning = ""
            w(f"| {did} | {len(data)} | {live} | {meaning} |")
        for h in sorted(refused.get(mod, []), key=lambda h: h["did"]):
            w(f"| {h['did']} | – | – | refused, NRC 0x{h['nrc']} |")
        w("")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n")
    print(f"{OUT.relative_to(REPO)}: {total} DIDs")


if __name__ == "__main__":
    main(sys.argv[1:])
