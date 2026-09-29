import 'dart:async';

import '../elm/elm_client.dart';
import '../elm/elm_response.dart';
import '../transport/elm_transport.dart';
import '../uds/uds_client.dart';
import 'poll_schedule.dart';
import 'session_file.dart';

/// One GPS fix, metric.
class GpsFix {
  const GpsFix({
    required this.lat,
    required this.lon,
    this.speedKmh,
    this.headingDeg,
    this.altitudeM,
    this.accuracyM,
    this.timeMs,
  });

  final double lat;
  final double lon;
  final double? speedKmh;
  final double? headingDeg;
  final double? altitudeM;
  final double? accuracyM;
  final int? timeMs;
}

/// Live counters for the Record screen.
class RecorderStats {
  int reads = 0;
  int values = 0;
  int negatives = 0;
  int noResponses = 0;
  int gpsFixes = 0;
  double? volts;
  bool carOn = false;
  GpsFix? lastFix;
  String status = '';
}

/// Polls the recording targets round-robin and logs GPS into a session file
/// (PLAN.md §4.1, screen 3). Nothing goes on the bus unless ATRV shows the
/// car on; after [noResponseLimit] unanswered requests in a row the gate is
/// closed and polling waits for the next voltage check (PLAN.md §5.4).
///
/// [uds] returns the current adapter session, or null while the BLE link is
/// down; GPS keeps recording meanwhile and polling resumes on reconnect.
/// [onceTargets] (identification DIDs) are read the first time the car is on.
class Recorder {
  Recorder({
    required this.uds,
    required this.writer,
    required this.schedule,
    this.onceTargets = const [],
    this.gps,
    this.voltageEvery = const Duration(seconds: 30),
    this.carOffRecheck = const Duration(seconds: 30),
    this.linkRecheck = const Duration(seconds: 2),
    this.noResponseLimit = 20,
    this.flushEvery = const Duration(seconds: 5),
  });

  final UdsClient? Function() uds;
  final SessionWriter writer;
  final PollSchedule schedule;
  final List<PollTarget> onceTargets;
  final Stream<GpsFix>? gps;
  final Duration voltageEvery;
  final Duration carOffRecheck;
  final Duration linkRecheck;
  final int noResponseLimit;
  final Duration flushEvery;

  final stats = RecorderStats();

  /// Called whenever [stats] change (throttled by the caller if needed).
  void Function()? onUpdate;

  bool _stopping = false;
  Completer<void>? _wake;
  StreamSubscription<GpsFix>? _gpsSub;
  UdsClient? _lastUds;
  bool _onceDone = false;
  int _streak = 0;
  final _sinceVoltage = Stopwatch();

  bool get isStopping => _stopping;

  /// Runs until [stop] is called.
  Future<void> run() async {
    _gpsSub = gps?.listen(_onFix);
    final flushTimer = Timer.periodic(flushEvery, (_) => writer.flush());
    writer.event('record_start');
    try {
      while (!_stopping) {
        // Let timers (flush, stop, UI) run even if replies arrive instantly.
        await Future<void>.delayed(Duration.zero);
        final u = uds();
        if (u == null) {
          if (_lastUds != null) writer.event('link_lost');
          _lastUds = null;
          stats.carOn = false;
          stats.status = 'Adapter disconnected: reconnecting, GPS only';
          onUpdate?.call();
          await _sleep(linkRecheck);
          continue;
        }
        if (!identical(u, _lastUds)) {
          if (_lastUds == null && stats.reads > 0) writer.event('link_restored');
          _lastUds = u;
          _sinceVoltage.stop(); // new session: its gate starts closed
        }
        if (!_sinceVoltage.isRunning || _sinceVoltage.elapsed >= voltageEvery) {
          await _checkVoltage(u);
          _sinceVoltage
            ..reset()
            ..start();
        }
        if (!stats.carOn) {
          stats.status = 'Car off: not polling, GPS only';
          onUpdate?.call();
          await _sleep(carOffRecheck);
          _sinceVoltage.stop(); // force a voltage check next time round
          continue;
        }
        if (!_onceDone) {
          stats.status = 'Reading ${onceTargets.length} identification DIDs';
          onUpdate?.call();
          for (final t in onceTargets) {
            if (_stopping) break;
            await _poll(u, t);
          }
          _onceDone = true;
          continue;
        }
        if (schedule.isEmpty) {
          stats.status = 'Nothing to poll: GPS only';
          onUpdate?.call();
          await _sleep(const Duration(seconds: 1));
          continue;
        }

        stats.status = 'Polling ${schedule.length} DIDs';
        await _poll(u, schedule.next());
        if (_streak >= noResponseLimit) {
          _streak = 0;
          writer.event('no_response_streak');
          u.elm.transport.gate.close();
          stats.carOn = false;
          _sinceVoltage.stop();
          await _sleep(const Duration(seconds: 10));
        }
        onUpdate?.call();
      }
    } finally {
      flushTimer.cancel();
      await _gpsSub?.cancel();
      _gpsSub = null;
      writer.event('record_stop');
      await writer.flush();
    }
  }

  void stop() {
    _stopping = true;
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// Reads one DID and logs the outcome. Never throws.
  Future<void> _poll(UdsClient u, PollTarget target) async {
    final ReadResult r;
    try {
      r = await u.readDid(target.module, target.did);
    } on BusClosedException {
      stats.carOn = false;
      return;
    } on ElmTimeoutException catch (e) {
      writer.event('timeout ${e.command}');
      _streak++;
      return;
    } on ElmSetupException catch (e) {
      writer.event('setup_error ${e.command} ${e.reply}');
      _streak++;
      return;
    } catch (e) {
      // Usually the BLE link dropping; the connect controller will swap
      // the session out, so wait a little before trying again.
      writer.event('read_error $e');
      await _sleep(linkRecheck);
      return;
    }
    stats.reads++;
    switch (r) {
      case ReadValue(:final data):
        _streak = 0;
        stats.values++;
        writer.did(target.module.name, target.didHex, bytesToHex(data));
      case ReadNegative(:final nrc):
        _streak = 0;
        stats.negatives++;
        writer.nrc(target.module.name, target.didHex, nrc);
      case ReadNoResponse():
        _streak++;
        stats.noResponses++;
    }
  }

  Future<void> _checkVoltage(UdsClient u) async {
    double? v;
    try {
      v = await u.elm.readVoltage();
    } catch (e) {
      writer.event('atrv_error $e');
    }
    writer.voltage(v);
    stats.volts = v;
    stats.carOn = u.elm.transport.gate.isOpen;
    onUpdate?.call();
  }

  void _onFix(GpsFix f) {
    writer.gps(
      lat: f.lat,
      lon: f.lon,
      speedKmh: f.speedKmh,
      headingDeg: f.headingDeg,
      altitudeM: f.altitudeM,
      accuracyM: f.accuracyM,
      fixTimeMs: f.timeMs,
    );
    stats.gpsFixes++;
    stats.lastFix = f;
    onUpdate?.call();
  }

  Future<void> _sleep(Duration d) async {
    if (_stopping) return;
    final wake = _wake = Completer<void>();
    await Future.any([wake.future, Future<void>.delayed(d)]);
  }
}
