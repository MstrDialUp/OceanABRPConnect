"""Find signals in recorded sessions (PLAN.md §4.4).

Usage:
    python3 tools/analyze/analyze.py [data/sessions/*.jsonl ...]

With no arguments it analyses every session in data/sessions/. It prints a
Markdown report to stdout: which DIDs change, which track GPS speed, which
track a tractive-power estimate (current/power candidates), an energy check
of the current signal against the SOC drop, and the DIDs that behave like
states (few distinct values). Standard library only.
"""

from __future__ import annotations

import sys
from pathlib import Path

from session import Decoding, Session, candidate_decodings, linear_fit, load, pearson, varying_bytes

REPO = Path(__file__).resolve().parents[2]

# Rough Ocean figures for the tractive-power estimate; only the shape matters.
MASS_KG = 2500
CDA_M2 = 0.7
CRR = 0.009
PACK_KWH = 113  # gross capacity, for the energy check


def tractive_kw(s: Session, t: int) -> float | None:
    v = s.speed_at(t)
    a = s.accel_at(t, 3000)
    if v is None or a is None:
        return None
    ms = v / 3.6
    return (MASS_KG * a * ms + 0.5 * 1.2 * CDA_M2 * ms**3 + CRR * MASS_KG * 9.81 * ms) / 1000


def best_correlations(s: Session, target, modules=None, top=12):
    """Best |r| decoding per DID against target(session, t)."""
    out = []
    for key, samples in s.dids.items():
        if modules and key[0] not in modules:
            continue
        best = None
        for d in candidate_decodings([b for _, b in samples]):
            xs, ys = [], []
            for t, b in samples:
                y = target(s, t)
                x = d.read(b)
                if y is None or x is None:
                    continue
                xs.append(x)
                ys.append(y)
            r = pearson(xs, ys)
            if r is not None and (best is None or abs(r) > abs(best[0])):
                best = (r, d, xs, ys)
        if best:
            out.append((key, *best))
    out.sort(key=lambda e: -abs(e[1]))
    return out[:top]


def report(s: Session) -> str:
    lines: list[str] = []
    w = lines.append
    dur_min = ((s.footer or {}).get("t", s.start_ms) - s.start_ms) / 60000
    n_reads = sum(len(v) for v in s.dids.values())
    w(f"## {s.name}")
    w("")
    w(f"- Duration {dur_min:.1f} min, {n_reads} DID reads ({n_reads / max(dur_min * 60, 1):.1f}/s), "
      f"{len(s.gps)} GPS fixes, OS {s.header.get('car_os')}")
    w(f"- Checklist: {', '.join(s.checklist) or '(none)'}; dash: {(s.footer or {}).get('dash', {})}")
    events = {}
    for _, e in s.events:
        k = e.split(" ")[0]
        events[k] = events.get(k, 0) + 1
    w(f"- Events: {events}")

    varying = {k: v for k, v in s.dids.items() if varying_bytes([b for _, b in v])}
    w(f"- {len(s.dids)} DIDs read, {len(varying)} changed during the session")
    w("")

    w("### Tracks GPS speed")
    w("")
    w("| DID | decoding | r | km/h per bit | offset | n |")
    w("|---|---|---|---|---|---|")
    for key, r, d, xs, ys in best_correlations(s, lambda s, t: s.speed_at(t)):
        if abs(r) < 0.9:
            break
        a, b = linear_fit(xs, ys)
        w(f"| {key[0]} {key[1]} | {d} | {r:+.3f} | {a:.5f} | {b:+.2f} | {len(xs)} |")
    w("")

    w("### Tracks tractive power (current / power candidates)")
    w("")
    w("| DID | decoding | r | range |")
    w("|---|---|---|---|")
    for key, r, d, xs, _ in best_correlations(s, tractive_kw, top=8):
        w(f"| {key[0]} {key[1]} | {d} | {r:+.3f} | {min(xs)}..{max(xs)} |")
    w("")

    w("### Energy check")
    w("")
    soc = s.dids.get(("BMS", "2050"))
    cur = s.dids.get(("BMS", "2004"))
    volt = s.dids.get(("BMS", "2107"))
    if soc and cur and volt and len(soc) > 1:
        d_soc = (int.from_bytes(soc[0][1][:2], "big") - int.from_bytes(soc[-1][1][:2], "big")) / 10
        amps = [int.from_bytes(b[2:4], "big") * 0.1 - 2000 for _, b in cur]
        volts = [int.from_bytes(b[:2], "big") * 0.1 for _, b in volt]
        hours = (cur[-1][0] - cur[0][0]) / 3_600_000
        kwh = sum(amps) / len(amps) * sum(volts) / len(volts) / 1000 * hours
        w(f"- SOC (2050) fell {d_soc:.1f} points ≈ {d_soc / 100 * PACK_KWH:.2f} kWh at {PACK_KWH} kWh")
        w(f"- Mean current × mean voltage × time = {kwh:.2f} kWh "
          f"(mean {sum(amps) / len(amps):.1f} A, {sum(volts) / len(volts):.1f} V, {hours:.2f} h)")
        charging = [a for a in amps if a < -5]
        w(f"- Samples with current below −5 A: {len(charging)} of {len(amps)}")
    else:
        w("- Needs BMS 2050, 2004 and 2107 in the session.")
    w("")

    w("### State-like DIDs (2–6 distinct values)")
    w("")
    w("| DID | values (first seen, min) | speed when seen (km/h) |")
    w("|---|---|---|")
    for key, samples in sorted(varying.items()):
        distinct = {}
        for t, b in samples:
            distinct.setdefault(b.hex().upper(), []).append((t, s.speed_at(t)))
        if not 2 <= len(distinct) <= 6:
            continue
        cells = []
        speeds = []
        for val, seen in distinct.items():
            cells.append(f"`{val[:16]}` @{(seen[0][0] - s.start_ms) / 60000:.0f}")
            sp = [x for _, x in seen if x is not None]
            speeds.append(f"{min(sp):.0f}–{max(sp):.0f}" if sp else "?")
        w(f"| {key[0]} {key[1]} | {', '.join(cells)} | {', '.join(speeds)} |")
    w("")
    return "\n".join(lines)


def main(argv: list[str]) -> None:
    paths = [Path(p) for p in argv] or sorted((REPO / "data" / "sessions").glob("*.jsonl"))
    if not paths:
        sys.exit("No sessions found; copy them into data/sessions/.")
    print("# Session analysis\n")
    for p in paths:
        s = load(p)
        if not s.dids:
            continue
        print(report(s))


if __name__ == "__main__":
    main(sys.argv[1:])
