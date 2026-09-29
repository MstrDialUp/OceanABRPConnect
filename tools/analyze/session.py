"""Load recorded sessions (PLAN.md §4.3) and decode DID payloads.

Standard library only, so it runs anywhere Python 3.10+ is installed.
"""

from __future__ import annotations

import bisect
import json
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Session:
    path: Path
    header: dict
    footer: dict | None
    # (module, did) -> list of (t_ms, raw bytes)
    dids: dict[tuple[str, str], list[tuple[int, bytes]]] = field(default_factory=dict)
    # sorted list of (t_ms, speed_kmh, fix dict)
    gps: list[tuple[int, float | None, dict]] = field(default_factory=list)
    atrv: list[tuple[int, float | None]] = field(default_factory=list)
    events: list[tuple[int, str]] = field(default_factory=list)

    @property
    def name(self) -> str:
        return self.path.name

    @property
    def start_ms(self) -> int:
        return self.header["t"]

    @property
    def checklist(self) -> list[str]:
        return (self.footer or {}).get("checklist", [])

    def speed_at(self, t_ms: int, max_gap_ms: int = 2000) -> float | None:
        """GPS speed (km/h) at t, linearly interpolated between fixes."""
        times = self._gps_times
        i = bisect.bisect_left(times, t_ms)
        if i == 0 or i == len(times):
            j = 0 if i == 0 else len(times) - 1
            if abs(times[j] - t_ms) <= max_gap_ms:
                return self.gps[j][1]
            return None
        (t0, s0, _), (t1, s1, _) = self.gps[i - 1], self.gps[i]
        if s0 is None or s1 is None or t1 - t0 > 2 * max_gap_ms:
            return None
        return s0 + (s1 - s0) * (t_ms - t0) / (t1 - t0)

    def accel_at(self, t_ms: int, window_ms: int = 2000) -> float | None:
        """Longitudinal acceleration (m/s²) from GPS speed around t."""
        a = self.speed_at(t_ms - window_ms // 2)
        b = self.speed_at(t_ms + window_ms // 2)
        if a is None or b is None:
            return None
        return (b - a) / 3.6 / (window_ms / 1000)

    def _index(self) -> None:
        self.gps.sort(key=lambda g: g[0])
        self._gps_times = [g[0] for g in self.gps]


def load(path: str | Path) -> Session:
    path = Path(path)
    header: dict | None = None
    footer: dict | None = None
    s = None
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue  # truncated last line if the app was killed
            kind = o.get("type")
            if kind == "header":
                header = o
                s = Session(path, header, None)
            elif s is None:
                continue
            elif kind == "did":
                s.dids.setdefault((o["mod"], o["did"]), []).append((o["t"], bytes.fromhex(o["raw"])))
            elif kind == "gps":
                s.gps.append((o["t"], o.get("spd"), o))
            elif kind == "atrv":
                s.atrv.append((o["t"], o.get("v")))
            elif kind == "event":
                s.events.append((o["t"], o["what"]))
            elif kind == "footer":
                footer = o
    if s is None:
        raise ValueError(f"{path}: no header")
    s.footer = footer
    s._index()
    return s


def load_dir(directory: str | Path) -> list[Session]:
    return [load(p) for p in sorted(Path(directory).glob("*.jsonl"))]


# ---------------------------------------------------------------- decoding

@dataclass(frozen=True)
class Decoding:
    """A way to read a number out of a payload: offset, width, signedness."""

    offset: int
    width: int  # bytes: 1, 2 or 4
    signed: bool

    def __str__(self) -> str:
        kind = ("s" if self.signed else "u") + str(8 * self.width)
        return f"{kind}@{self.offset}"

    def read(self, data: bytes) -> int | None:
        end = self.offset + self.width
        if end > len(data):
            return None
        return int.from_bytes(data[self.offset:end], "big", signed=self.signed)


def candidate_decodings(samples: list[bytes]) -> list[Decoding]:
    """Decodings over the bytes that actually change in [samples]."""
    if not samples:
        return []
    n = min(len(b) for b in samples)
    varying = [i for i in range(n) if len({b[i] for b in samples}) > 1]
    out: list[Decoding] = []
    for width in (1, 2, 4):
        for off in range(0, n - width + 1):
            span = range(off, off + width)
            # Only keep decodings that cover at least one varying byte.
            if not any(i in varying for i in span):
                continue
            for signed in (False, True):
                out.append(Decoding(off, width, signed))
    return out


def varying_bytes(samples: list[bytes]) -> list[int]:
    if not samples:
        return []
    n = min(len(b) for b in samples)
    return [i for i in range(n) if len({b[i] for b in samples}) > 1]


# ---------------------------------------------------------------- stats

def pearson(xs: list[float], ys: list[float]) -> float | None:
    n = len(xs)
    if n < 5:
        return None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx == 0 or syy == 0:
        return None
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return sxy / (sxx * syy) ** 0.5


def linear_fit(xs: list[float], ys: list[float]) -> tuple[float, float]:
    """Least squares y = a*x + b."""
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    a = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return a, my - a * mx
