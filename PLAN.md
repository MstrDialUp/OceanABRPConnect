# OceanABRPConnect — Plan

A phone app that reads live data from a Fisker Ocean through a vLinker FD+ (BLE, ELM327-compatible) and sends it to A Better Route Planner (ABRP) using the ABRP "Generic" live-data token.

Status: planning. Open questions are at the end of this file.

---

## 1. What the reference app (Unfiskered Go v6) shows us

`UNFISKERED_GO_FREE_OFFLINE.html` is a single-page Web Bluetooth app. It is a diagnostic tool (read/clear DTCs), not a telemetry tool. Relevant findings:

### 1.1 Transport
- Uses Web Bluetooth (`navigator.bluetooth.requestDevice`, `acceptAllDevices`), then picks the first GATT service that has one write characteristic and one notify characteristic. The vLinker FD+ exposes this on one of the common UART-style services (`FFF0`/`FFE0` family).
- Commands are ASCII ELM327 AT/OBD strings terminated with `\r`, written in 20-byte chunks. A reply is complete when the `>` prompt arrives.

### 1.2 Adapter init sequence
`ATZ`, `ATI`, `ATSP6` (ISO 15765-4 CAN, 11-bit, 500 kbps), `ATH1` (headers on), `ATE0` (echo off), `ATS0` (no spaces), `0100`, `1001` (UDS default session).

### 1.3 Per-module addressing (UDS over ISO-TP)
For each request: `ATSH<tx>` (request ID), `ATFCSH<tx>` (flow-control header), `ATCRA<rx>` (receive filter), send the UDS request, then `ATAR` (reset filter).

Module request/response CAN IDs (hex) used by the tool:

| Module | Tx/Rx | Module | Tx/Rx | Module | Tx/Rx |
|---|---|---|---|---|---|
| BMS | 7E1/7E9 | VCU | 7C2/7CA | BCM | 7C1/7C9 |
| PKC | 7A2/7AA | MCU_F | 786/78E | MCU_R | 7F2/7FA |
| PDU | 7F3/7FB | OHC (charger?) | 783/78B | ECC (climate?) | 7F0/7F8 |
| ESP | 7D0/7D8 | GW | 7B6/7BE | TBOX | 7D1/7D9 |
| ICC | 7B1/7B9 | CIM | 7D3/7DB | TRM | 7C7/7CF |

(35 modules total; the functional/broadcast address is 7DF.)

### 1.4 Known data identifiers (UDS service 0x22, ReadDataByIdentifier)

| Value | Module | DID | Decoding | ABRP field |
|---|---|---|---|---|
| VIN | VCU (fallback BCM, PKC) | F190 | ASCII | — |
| Odometer | BCM | 3409 | uint32 / 100 = km | `odometer` |
| HV state of charge | BMS | 2050 | uint16 / 10 = % | `soc` |
| 12 V battery | VCU (fallback BCM, PKC) | EFF9 | uint16 / 1000 = V | — |

That is the full set of live values in the reference app. **Speed, power (pack voltage × current), charging state, gear/park state, and temperatures are not in it**, and the OBDb community signal set for the Ocean (`OBDb/Fisker-Ocean`) is currently empty. Finding those DIDs is the main technical risk (see §4, Phase 1).

### 1.5 Things we will not do
The reference app also sends `14FFFFFF` (ClearDiagnosticInformation) to every module and `0414…` on the functional address. Our app is **read-only**: it will only ever send ELM327 `AT` configuration commands and UDS `0x22` reads (plus `0x3E` TesterPresent if a session ever needs it). A hard allow-list in the transport layer will reject anything else.

### 1.6 Licensing note
The reference app's terms prohibit copying, modifying, or reverse engineering its code. We will not copy its source. Our ELM327, ISO-TP and UDS handling will be written from the public standards (ELM327 datasheet, ISO 15765-2, ISO 14229). Module CAN IDs and DIDs are vehicle facts that we will also verify ourselves on the car. You should decide whether you are comfortable with this; it is not legal advice.

---

## 2. What ABRP needs

### 2.1 Endpoint
`POST/GET https://api.iternio.com/1/tlm/send`
- `api_key` — identifies **our app**. Telemetry-only keys are free; request one from contact@iternio.com. Sent as a query parameter or `Authorization: APIKEY <key>` header.
- `token` — identifies **your car in ABRP**. You get it in ABRP: Settings → your vehicle → Modify connections → Generic → Link. (OAuth2 is the other option; not needed for a personal app.)
- `tlm` — JSON object with the telemetry.

Response is JSON (`{"status":"ok"}` on success); HTTP errors indicate a bad key or bad request.

### 2.2 Telemetry fields
High priority: `utc` (epoch **seconds**), `soc` (%), `power` (kW, + = discharge, − = charging), `speed` (km/h), `lat`, `lon`, `is_charging`, `is_dcfc`, `is_parked`.

Lower priority: `capacity`, `soe`, `soh`, `heading`, `elevation`, `ext_temp`, `batt_temp`, `voltage`, `current`, `odometer`, `est_battery_range`, `hvac_power`, `hvac_setpoint`, `cabin_temp`, `tire_pressure_fl/fr/rl/rr` (kPa).

ABRP's consumption calibration needs **`speed`, `power` and `is_charging` at least once every 10 s** (faster is better).

### 2.3 Where each field comes from

| Field | Source | Status |
|---|---|---|
| `utc` | phone clock | available |
| `lat`, `lon`, `heading`, `elevation` | phone GPS | available |
| `speed` | car (preferred) or phone GPS | GPS available; car DID unknown |
| `soc` | BMS 2050 | known — must confirm it matches the dash SOC |
| `odometer` | BCM 3409 | known |
| `power`, `voltage`, `current` | BMS | unknown DIDs — discovery needed |
| `is_charging`, `is_dcfc` | BMS / OHC / VCU | unknown — can be inferred from current sign + speed 0 as a fallback |
| `is_parked` | VCU gear | unknown — fallback: speed 0 for N seconds |
| `batt_temp`, `ext_temp`, `soh`, `est_battery_range` | BMS / ECC / VCU | unknown, nice-to-have |

Minimum viable ABRP link with what is already known: `utc`, `soc`, `lat`, `lon`, `speed` (GPS), `odometer`, `is_parked` (inferred). ABRP will show live SOC and position and re-plan, but will not calibrate consumption until we have `power`.

---

## 3. Architecture

```
 vLinker FD+ ──BLE──► Transport (ELM327 over GATT)
                         │  read-only allow-list
                         ▼
                      ISO-TP / UDS layer (0x22 reads, multi-frame reassembly)
                         │
                         ▼
                      Signal poller (per-signal DID, decoder, rate)
                         │                  Phone GPS
                         ▼                     │
                      Telemetry snapshot ◄─────┘
                         │
                         ▼
                      ABRP uploader (every 5 s driving / 30 s parked,
                         │             offline queue, retry/backoff)
                         ▼
                      api.iternio.com/1/tlm/send
```

### 3.1 Why a native app, not the HTML approach
ABRP is on screen (or on Android Auto / CarPlay) while driving, so our app runs in the background with the screen off for the whole trip. A web page cannot hold a BLE connection in the background, and iOS has no Web Bluetooth at all. The app therefore needs:
- **Android:** a foreground service (persistent notification) holding the BLE GATT connection and location updates.
- **iOS:** CoreBluetooth `bluetooth-central` and `location` background modes.

Proposed stack (depends on your answer to Q1): Kotlin for Android-only, or Flutter for both platforms from one codebase. The HTML reference is still useful as a quick desktop/Android-Chrome **bench tool** for Phase 1 discovery.

### 3.2 Module layout
- `transport/` — BLE scan/connect to vLinker, write/notify characteristic discovery, command queue, prompt-based framing, timeouts, auto-reconnect.
- `elm/` — init sequence, header/filter management (only re-issue `ATSH`/`ATCRA` when the target module changes), command allow-list.
- `uds/` — ISO-TP single/first/consecutive frame reassembly, negative-response (`7F`) handling, `0x22` request builder.
- `signals/` — a data table (JSON) of `{module, did, byte offset, length, scale, offset, unit, abrpField, pollRateMs}`. New DIDs are added by editing this table, not code.
- `abrp/` — token + API key storage (Android Keystore / iOS Keychain), payload builder, uploader, offline queue.
- `ui/` — connection status, live values, last upload result, settings (token, units, poll rates), debug log export.

### 3.3 Polling budget
Each UDS read over ELM327/BLE costs roughly 50–150 ms. At 1 Hz for SOC, speed, voltage, current and a slower rate for odometer/temps, the bus load is small. Grouping DIDs per module (a single `22 DID1 DID2 …` request, if the ECU supports it) cuts header switches.

### 3.4 Power and sleep behaviour
The Ocean has known 12 V drain problems. The app must:
- poll only while the car is on (detect via VCU state or failed reads → back off to a slow heartbeat, then disconnect);
- never send periodic requests that could keep modules awake after shutdown;
- rely on the vLinker FD+'s own auto-sleep, and ideally recommend unplugging it if the car sits for days.

---

## 4. Phases

### Phase 0 — Setup (you)
- Email contact@iternio.com for a free Telemetry API key (app name, one-line description, personal/non-commercial use).
- Get the Generic token from ABRP for your Ocean.

### Phase 1 — Signal discovery (the main unknown)
Build a small **read-only DID scanner** (can start as a bench HTML page on Android Chrome, then move into the app's debug screen):
1. Connect, init, verify the known DIDs (SOC, odometer, 12 V) against the dash.
2. On BMS, VCU, MCU_F/R, OHC, PDU, ESP, ECC: request `0x22` over likely DID ranges (e.g. `2000–20FF`, `3400–34FF`, `D000–D0FF`, `F400–F4FF`, `0100–01FF`) and record which return positive responses. Also try standard OBD mode 01 PIDs on 7DF (`010D` speed, `015B` hybrid battery remaining) since the init sends `0100`.
3. Log every responding DID with raw bytes and a timestamp while (a) parked, (b) driving at steady speeds, (c) accelerating/regenerating, (d) AC charging, (e) DC fast charging.
4. Correlate: speed vs GPS speed; current sign flips between driving and charging; pack voltage in the ~350–420 V range; temperatures against dash/app values.
5. Record confirmed signals in `signals/ocean.json`.

Deliverable: a signal table covering at least `speed`, `voltage`, `current` (→ `power`), `is_charging`, gear/park.

### Phase 2 — MVP app
- BLE connect + init + read-only allow-list.
- Poll known signals, plus phone GPS.
- Upload to ABRP every 5 s while driving, 30–60 s while charging/parked.
- Settings screen for token and API key; status screen with last upload result.
- Works in background for a full trip; reconnects after BLE drops.

### Phase 3 — Full telemetry
- Add `power`, `voltage`, `current`, `is_charging`, `is_dcfc`, `is_parked`, `batt_temp`, `ext_temp`, `soh`, `est_battery_range` as discovered.
- Offline queue for dead zones (ABRP only uses recent data, so queue only the latest snapshot rather than a backlog).
- Auto-start when the vLinker is seen (Android: companion device / BLE scan; iOS: state restoration).

### Phase 4 — Hardening
- 12 V drain testing overnight with the dongle plugged in.
- Trip log export (CSV) for debugging.
- Unit tests for ISO-TP reassembly and decoders using recorded frames.

---

## 5. Open questions
1. **Phone platform:** Android, iPhone, or both? (Decides Kotlin vs Flutter; iOS also needs an Apple developer account to install outside the App Store for more than 7 days.)
2. **ABRP display:** Do you use ABRP on the phone, Android Auto, CarPlay, or the web? (Affects whether our app is always backgrounded.)
3. **Ocean software version:** Which OS is the car on (below/above 2.2.3)? Unfiskered Go treats these differently, and DIDs may change between versions.
4. **Discovery sessions:** Can you run the scanner in the car while parked, driving, AC charging and DC fast charging, and share the logs? Signal discovery needs real car data.
5. **Reference data:** Do you have any other sources of Ocean DIDs (OceanLink Pro screenshots showing which values it displayed, forum posts, FOA contacts)? Knowing what OceanLink Pro showed tells us which values are reachable over OBD.
6. **API key:** Are you willing to email Iternio for the telemetry API key, and is this strictly for personal use (vs. sharing with other Ocean owners)?
7. **Dongle behaviour:** Do you leave the vLinker plugged in permanently? (Affects the 12 V sleep strategy.)
8. **Unfiskered Go licence:** Are you comfortable with the approach in §1.6 (independent implementation, use of CAN IDs/DIDs verified on your car)?
