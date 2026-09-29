# Strait

Sends live data from a Fisker Ocean to A Better Routeplanner (ABRP) (PLAN.md §5). It reads the car through a vLinker FD+ BLE OBD adapter using `packages/ocean_obd`, and uploads SOC, speed, power, voltage, current, odometer, GPS and the inferred parked/charging state to ABRP's Telemetry API.

Each user enters their own ABRP API key (ABRP → API keys → telemetry) and vehicle token (ABRP → your car → Modify connections → Generic → Link) on the ABRP tab. Both are stored only in the phone's secure storage.

- **ABRP**: key and token, Start/Stop sending, upload status, the latest values, and a check of what ABRP received.
- **Car**: connect to the adapter, `ATRV`, the known signals, and Settings (units).

App ID `com.mstrdialup.strait`.

```
cd strait && flutter test && flutter run
```
