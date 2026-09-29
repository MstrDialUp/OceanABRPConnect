# Session analysis

Standard-library Python (3.10+); nothing to install.

```
python3 tools/analyze/analyze.py                      # every session in data/sessions/
python3 tools/analyze/analyze.py data/sessions/x.jsonl > report.md
```

The report lists, for each session:
- the DIDs that changed;
- the decodings that track GPS speed, with a fitted km/h-per-bit scale;
- the decodings that track a tractive-power estimate (current and power candidates);
- an energy check of BMS 2004 × 2107 against the SOC drop;
- the DIDs with only a few distinct values (states: gear, locks, charging).

`session.py` loads a session and has the decoding and statistics helpers, for one-off exploration. The reports contain car data but no GPS positions or VIN. Keep them local anyway, like the sessions.
