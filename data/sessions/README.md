# Recorded sessions (local only)

Put session files exported from the app's Sessions tab here for analysis. They are git-ignored, because the repository is public and each file contains the VIN (in the header) and GPS tracks.

Each file is JSONL: a `header` line, then `did` / `nrc` / `gps` / `atrv` / `event` lines, then a `footer` with the stop checklist. All values are metric and `t` is epoch milliseconds. The format is in PLAN.md §4.3 and §6.2.
