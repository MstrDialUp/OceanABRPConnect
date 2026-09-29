# Strait

Strait sends live data from a Fisker Ocean to A Better Routeplanner (ABRP): state of charge, speed, power, voltage, current, odometer and GPS, read through a Bluetooth OBD-II adapter (vLinker FD+). ABRP can then plan and adjust routes with the car's real state, as it does for cars with built-in live data.

It's an Android app written in Flutter. It only **reads** from the car: a code-enforced allow-list lets through nothing but diagnostic read requests. It stays quiet on the bus while the car is off, so the adapter can stay plugged in.

## What's here

| Directory | What |
|---|---|
| [`strait/`](strait/) | the Strait app |
| [`packages/ocean_obd/`](packages/ocean_obd/) | shared package for reading the car: Bluetooth adapter, ELM327, ISO-TP, UDS, signal table |
| [`discovery/`](discovery/) | Ocean Discovery, the tool used to find the car's data identifiers |
| [`docs/fisker-ocean/`](docs/fisker-ocean/README.md) | what we know about the car's diagnostic bus: modules, decoded signals, evidence, open questions |
| [`tools/analyze/`](tools/analyze/) | Python analysis of recorded sessions |
| [`PLAN.md`](PLAN.md) | scope, decisions and progress |

## Using it
You need a Fisker Ocean, an ELM327-compatible Bluetooth LE OBD adapter (tested: vLinker FD+), and your own ABRP account. In ABRP, create a telemetry API key and get your car's Generic live-data token, then enter both in Strait. They are stored only on your phone.

Builds are debug APKs from GitHub Actions for sideloading; there's no store release.

## Not affiliated
Strait is an independent project. It isn't affiliated with, endorsed by or supported by Fisker, Iternio or A Better Routeplanner. "Fisker", "Ocean", "A Better Routeplanner" and "ABRP" are names of their respective owners and are used here only to describe what the app works with. Use it at your own risk.
