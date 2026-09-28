import 'dart:async';

import '../elm/ecu_module.dart';
import '../elm/elm_response.dart';
import '../transport/elm_transport.dart';
import '../uds/uds_client.dart';
import 'sweep_state.dart';

/// Candidate DID ranges from PLAN.md §4.1 (inclusive).
const defaultSweepRanges = <(int, int)>[
  (0x2000, 0x20FF),
  (0x2100, 0x21FF),
  (0x3400, 0x34FF),
  (0xD000, 0xD1FF),
  (0xEF00, 0xEFFF),
  (0xF100, 0xF1FF),
  (0xF400, 0xF4FF),
  (0xFD00, 0xFDFF),
];

/// OBD-II mode 01 PIDs probed on 7DF: the "supported PIDs" bitmaps plus the
/// ones most likely to be useful (speed, battery remaining, temperatures).
const defaultObdPids = <int>[
  0x00, 0x01, 0x05, 0x0D, 0x1F, 0x20, 0x21, 0x2F, 0x31, 0x40, //
  0x42, 0x46, 0x51, 0x5B, 0x60, 0x80, 0xA0, 0xA6, 0xC0,
];

class SweepPaused implements Exception {
  SweepPaused(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Runs the discovery sweep over [modules]. Read-only: only 0x22 requests,
/// mode 01 probes and a passive ATMA listen. Progress lives in [state] and
/// is handed to [save] regularly, so a stopped sweep resumes where it left
/// off.
class DiscoverySweep {
  DiscoverySweep({
    required this.uds,
    required this.modules,
    required this.state,
    required this.save,
    this.ranges = defaultSweepRanges,
    this.obdPids = defaultObdPids,
    this.monitorDuration = const Duration(seconds: 5),
    this.voltageEvery = const Duration(seconds: 30),
    this.silentAfter = 8,
    this.saveEvery = 32,
  }) : dids = didsIn(ranges);

  static List<int> didsIn(List<(int, int)> ranges) => [
        for (final (start, end) in ranges)
          for (var d = start; d <= end; d++) d,
      ];

  /// (requests done, total requests) for the module part of the sweep.
  static (int, int) progressOf(SweepState state, List<EcuModule> modules, int didCount) {
    var done = 0;
    for (final m in modules) {
      final p = state.modules[m.name];
      if (p != null) done += p.finished ? didCount : p.next;
    }
    return (done, modules.length * didCount);
  }

  final UdsClient uds;
  final List<EcuModule> modules;
  final SweepState state;
  final Future<void> Function(SweepState) save;
  final List<(int, int)> ranges;
  final List<int> obdPids;
  final Duration monitorDuration;
  final Duration voltageEvery;

  /// A module that hasn't answered any of its first [silentAfter] requests
  /// is marked silent and skipped.
  final int silentAfter;
  final int saveEvery;

  final List<int> dids;

  static String rangesKeyFor(List<(int, int)> ranges) => ranges
      .map((r) => '${r.$1.toRadixString(16)}-${r.$2.toRadixString(16)}')
      .join(',')
      .toUpperCase();

  String currentStep = '';
  Stopwatch? _sinceVoltage;

  /// Runs until finished, [isCancelled] returns true, or the car turns off
  /// (throws [SweepPaused]). [onProgress] is called after every request.
  Future<void> run({required bool Function() isCancelled, void Function()? onProgress}) async {
    _sinceVoltage = null;
    try {
      for (final m in modules) {
        final p = state.progressFor(m.name);
        if (p.finished) continue;
        p.status = ModuleSweepStatus.inProgress;
        while (p.next < dids.length && p.status == ModuleSweepStatus.inProgress) {
          if (isCancelled()) return;
          final did = dids[p.next];
          currentStep = '${m.name} ${did.toRadixString(16).padLeft(4, '0').toUpperCase()}';
          await _ensureCarOn();
          _record(m, did, p, await _read(() => uds.readDid(m, did)));
          p.next++;
          if (p.next % saveEvery == 0) await _save();
          onProgress?.call();
        }
        if (p.status == ModuleSweepStatus.inProgress) p.status = ModuleSweepStatus.done;
        await _save();
      }

      if (!state.obdDone) {
        for (final pid in obdPids) {
          if (isCancelled()) return;
          final key = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
          if (state.obd.containsKey(key)) continue;
          currentStep = 'OBD 01$key';
          await _ensureCarOn();
          state.obd[key] = switch (await _read(() => uds.readObdPid(pid))) {
            ReadValue(:final data) => bytesToHex(data),
            ReadNegative(:final nrc) => 'NRC ${nrc.toRadixString(16).padLeft(2, '0').toUpperCase()}',
            ReadNoResponse() => 'none',
          };
          onProgress?.call();
        }
        state.obdDone = true;
        await _save();
      }

      if (state.monitor == null) {
        if (isCancelled()) return;
        currentStep = 'Passive listen (ATMA)';
        onProgress?.call();
        await _ensureCarOn();
        final lines = await uds.elm.transport.monitor(monitorDuration);
        final ids = <String>{};
        for (final f in ElmResponse.parse(lines.join('\r')).frames) {
          ids.add(f.id.toRadixString(16).toUpperCase());
        }
        state.monitor = {
          'lines': lines.length,
          'ids': ids.toList()..sort(),
          'sample': lines.take(100).toList(),
        };
      }
      currentStep = 'Finished';
    } finally {
      await _save();
      onProgress?.call();
    }
  }

  bool get finished =>
      modules.every((m) => state.modules[m.name]?.finished ?? false) &&
      state.obdDone &&
      state.monitor != null;

  Future<ReadResult> _read(Future<ReadResult> Function() op) async {
    try {
      return await op();
    } on BusClosedException {
      throw SweepPaused('Car is off (ATRV). Sweep paused.');
    } on ElmTimeoutException catch (e) {
      return ReadNoResponse('timeout ${e.command}');
    }
  }

  void _record(EcuModule m, int did, ModuleProgress p, ReadResult r) {
    switch (r) {
      case ReadValue(:final data):
        p.answered++;
        state.hits.add(DidHit(module: m.name, did: did, sample: bytesToHex(data)));
      case ReadNegative(:final nrc):
        p.answered++;
        if (nrc == 0x11) {
          p.status = ModuleSweepStatus.noService;
        } else if (nrc != 0x31) {
          state.hits.add(DidHit(module: m.name, did: did, nrc: nrc));
        }
      case ReadNoResponse():
        if (p.answered == 0 && p.next + 1 >= silentAfter) {
          p.status = ModuleSweepStatus.silent;
        }
    }
  }

  Future<void> _ensureCarOn() async {
    final sw = _sinceVoltage;
    if (sw != null && sw.elapsed < voltageEvery) return;
    final volts = await uds.elm.readVoltage();
    _sinceVoltage = Stopwatch()..start();
    if (!uds.elm.transport.gate.isOpen) {
      throw SweepPaused(
          'Car appears off (${volts?.toStringAsFixed(1) ?? '?'} V). Sweep paused.');
    }
  }

  Future<void> _save() async {
    state.updated = DateTime.now();
    await save(state);
  }
}
