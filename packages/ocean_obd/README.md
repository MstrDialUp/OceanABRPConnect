# ocean_obd

Shared Flutter package for talking to a Fisker Ocean's diagnostic bus through an ELM327 Bluetooth LE adapter (tested with a vLinker FD+). Both apps in this repo use it: `app/` (Ocean ABRP Connect) and `discovery/` (Ocean Discovery).

| Directory | What |
|---|---|
| `lib/transport/` | BLE UART link, serial ELM327 transport with `>` framing and a rate cap, the **read-only command allow-list** and the **ATRV bus gate** |
| `lib/elm/` | ELM327 setup, `ATRV`, module addressing, reply parsing |
| `lib/uds/` | ISO-TP reassembly, UDS `0x22` and OBD mode `01` reads |
| `lib/signals/` | the signal table (`assets/signals/ocean.json`) and its decoders |
| `lib/ui/` | shared connect/reconnect controller, Connect and Settings screens |
| `lib/platform/` | foreground service (reference-counted) and the shared GPS stream |
| `lib/app/` | settings (units, car OS) and the build stamp |
| `lib/util/` | display-only unit conversion, JSON file store |
| `lib/testing/` | `FakeElm`, a scripted adapter for tests |
| `assets/signals/` | `ocean.json` (decoded signals with evidence) and `sweep_os-2.2.3.json` (DIDs that answered in the sweep, without values) |

What the DIDs mean and how they were found: [`docs/fisker-ocean/`](../../docs/fisker-ocean/README.md).

Rules the code enforces (see `CLAUDE.md`): read-only on the vehicle, and nothing on the CAN bus unless `ATRV` shows the car on.

```
cd packages/ocean_obd && flutter test
```
