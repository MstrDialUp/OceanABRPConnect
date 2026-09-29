# Ocean Discovery

The tool used to find the Fisker Ocean's data identifiers (PLAN.md §4). It shares `packages/ocean_obd` with Ocean ABRP Connect and installs next to it (app ID `com.oceanabrp.ocean_discovery`).

- **Connect**: adapter, `ATRV`, and the known signals next to the dash.
- **Discover**: a resumable `0x22` sweep over DID ranges on every module, OBD mode `01` probes and a passive listen. Run only while parked in Ready.
- **Record**: polls every DID that answered (the bundled list plus any local sweep) and logs GPS, into a JSONL session with a stop checklist.
- **Sessions**: share or delete recordings. Copy them into `data/sessions/` for `tools/analyze/`.

Findings so far: [`docs/fisker-ocean/`](../docs/fisker-ocean/README.md).

```
cd discovery && flutter test && flutter run
```
