import 'dart:async';

import '../elm/elm_client.dart';
import '../signals/signal_table.dart';
import '../transport/elm_transport.dart';
import '../uds/uds_client.dart';
import 'vehicle_state.dart';

class LivePollerStats {
  double? volts;
  bool carOn = false;
  int reads = 0;
  int noResponses = 0;
  DateTime? carOffSince;
  String status = '';
}

/// Polls the verified ABRP signals into a [VehicleState] (PLAN.md §5.1,
/// §5.4).
///
/// Nothing goes on the bus unless ATRV shows the car on. While the car is
/// off, ATRV is re-read every [carOffRecheck]; after [carOffTimeout] of the
/// car being off, [run] returns and [onCarOffTimeout] fires so the caller
/// can disconnect the adapter. A run of [noResponseLimit] unanswered reads
/// closes the bus gate until the next voltage check.
class LivePoller {
  LivePoller({
    required this.uds,
    required List<SignalDef> signals,
    required this.state,
    DateTime Function()? clock,
    Duration Function(SignalDef)? intervalOf,
    this.voltageEvery = const Duration(seconds: 30),
    this.carOffRecheck = const Duration(seconds: 60),
    this.carOffTimeout = const Duration(minutes: 10),
    this.linkRecheck = const Duration(seconds: 2),
    this.noResponseLimit = 10,
  })  : signals = [
          for (final s in signals)
            if (s.verified && s.abrpField != null && s.pollSeconds > 0) s,
        ],
        _clock = clock ?? DateTime.now,
        _intervalOf = intervalOf ?? ((s) => Duration(seconds: s.pollSeconds));

  final UdsClient? Function() uds;
  final List<SignalDef> signals;
  final VehicleState state;
  final DateTime Function() _clock;
  final Duration Function(SignalDef) _intervalOf;
  final Duration voltageEvery;
  final Duration carOffRecheck;
  final Duration carOffTimeout;
  final Duration linkRecheck;
  final int noResponseLimit;

  final stats = LivePollerStats();
  void Function()? onUpdate;
  void Function()? onCarOffTimeout;

  bool _stopping = false;
  Completer<void>? _wake;
  final _due = <SignalDef, DateTime>{};
  DateTime? _lastVoltage;
  UdsClient? _lastUds;
  int _streak = 0;

  Future<void> run() async {
    _stopping = false;
    while (!_stopping) {
      await Future<void>.delayed(Duration.zero);
      final u = uds();
      if (u == null) {
        _lastUds = null;
        state.clearCar();
        stats.carOn = false;
        _set('Adapter disconnected: waiting for it');
        await _sleep(linkRecheck);
        continue;
      }
      if (!identical(u, _lastUds)) {
        _lastUds = u;
        _lastVoltage = null; // a new session's gate starts closed
      }
      final now = _clock();
      if (_lastVoltage == null || now.difference(_lastVoltage!) >= voltageEvery) {
        await _checkVoltage(u);
      }
      if (!stats.carOn) {
        state.clearCar();
        final since = stats.carOffSince ??= now;
        if (now.difference(since) >= carOffTimeout) {
          _set('Car off for ${carOffTimeout.inMinutes} min: stopping');
          onCarOffTimeout?.call();
          return;
        }
        _set('Car off: nothing sent on the bus');
        await _sleep(carOffRecheck);
        _lastVoltage = null;
        continue;
      }
      stats.carOffSince = null;
      if (signals.isEmpty) {
        _set('No verified ABRP signals to poll');
        await _sleep(const Duration(seconds: 1));
        continue;
      }

      // Most overdue signal first.
      SignalDef? next;
      DateTime? nextAt;
      for (final s in signals) {
        final at = _due[s] ?? DateTime(0);
        if (nextAt == null || at.isBefore(nextAt)) {
          next = s;
          nextAt = at;
        }
      }
      final wait = nextAt!.difference(_clock());
      if (wait > Duration.zero) {
        await _sleep(wait < const Duration(seconds: 1) ? wait : const Duration(seconds: 1));
        continue;
      }
      _set('Polling ${signals.length} signals');
      await _poll(u, next!);
      _due[next] = _clock().add(_intervalOf(next));
      if (_streak >= noResponseLimit) {
        _streak = 0;
        u.elm.transport.gate.close();
        stats.carOn = false;
        _lastVoltage = null;
        await _sleep(const Duration(seconds: 10));
      }
      onUpdate?.call();
    }
  }

  void stop() {
    _stopping = true;
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _poll(UdsClient u, SignalDef s) async {
    try {
      final r = await u.readDid(s.module, s.did);
      stats.reads++;
      switch (r) {
        case ReadValue(:final data):
          _streak = 0;
          final v = s.decode(data);
          if (v is double) state.update(s.abrpField!, v);
        case ReadNegative():
          _streak = 0;
        case ReadNoResponse():
          _streak++;
          stats.noResponses++;
      }
    } on BusClosedException {
      stats.carOn = false;
    } on ElmTimeoutException {
      _streak++;
    } on ElmSetupException {
      _streak++;
    } on SignalDecodeException {
      _streak = 0;
    } catch (_) {
      // Usually the BLE link dropping; the connect controller swaps the
      // session out.
      await _sleep(linkRecheck);
    }
  }

  Future<void> _checkVoltage(UdsClient u) async {
    try {
      stats.volts = await u.elm.readVoltage();
    } catch (_) {
      stats.volts = null;
    }
    stats.carOn = u.elm.transport.gate.isOpen;
    _lastVoltage = _clock();
  }

  void _set(String status) {
    stats.status = status;
    onUpdate?.call();
  }

  Future<void> _sleep(Duration d) async {
    if (_stopping) return;
    final wake = _wake = Completer<void>();
    await Future.any([wake.future, Future<void>.delayed(d)]);
  }
}
