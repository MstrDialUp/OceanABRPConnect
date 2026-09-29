# OceanABRPConnect

Flutter app (Android first) that reads live data from a Fisker Ocean through a vLinker FD+ BLE OBD dongle and sends it to ABRP's Telemetry API. `PLAN.md` is the source of truth for scope, phases and decisions; read it before starting work and update it when a decision changes.

## Hard rules
- **Read-only on the vehicle.** The transport layer may only send ELM327 `AT` setup commands, UDS `0x22` (ReadDataByIdentifier) and OBD mode `01` requests. Never add DTC clears (`0x14`), writes (`0x2E`), routines (`0x31`), resets (`0x11`) or session changes (`0x10`). The allow-list is enforced in code and covered by tests.
- **Don't keep the car awake.** The dongle is always plugged in. Nothing is sent on the CAN bus unless `ATRV` indicates the car is on (PLAN.md §5.4).
- **No third-party diagnostic app code.** ELM327 / ISO-TP / UDS handling is written from the public standards.
- **Metric internally.** Signals, session files and ABRP payloads are metric. Imperial is a display-only conversion.
- **Secrets.** The ABRP API key and user token are entered by each user in the app and stored only in the app's secure storage. Never bundle them in a build, commit them, put them in local config files, log them or put them in URLs.

## Layout (planned)
- `app/`: Flutter app (`transport/`, `elm/`, `uds/`, `signals/`, `recorder/`, `abrp/`, `ui/` under `lib/`)
- `app/assets/signals/ocean.json`: signal table (module, DID, decoding, ABRP field, poll rate)
- `tools/analyze/`: Python analysis of recorded sessions
- `data/sessions/`: exported recording sessions (JSONL)
- `docs/abrp/`: ABRP Telemetry API reference (Postman collection JSON, PDF, extracts)

## Commands
- `cd app && flutter test`: unit tests (ISO-TP reassembly, decoders, allow-list, unit conversion)
- `cd app && flutter run`: run on the connected Pixel
- CI: `.github/workflows/build-apk.yml` builds a debug APK on every push

## Target device
Pixel 10 Pro, Android 17. The foreground service types are `connectedDevice` and `location`.
