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
class Recorder {
  Recorder({
    required this.uds,
    required this.writer,
    required this.schedule,
    this.gps,
    this.voltageEvery = const Duration(seconds: 30),
    this.carOffRecheck = const Duration(seconds: 30),
    this.noResponseLimit = 20,
    this.flushEvery = const Duration(seconds: 5),
  });

  final UdsClient uds;
  final SessionWriter writer;
  final PollSchedule schedule;
  final Stream<GpsFix>? gps;
  final Duration voltageEvery;
  final Duration carOffRecheck;
  final int noResponseLimit;
  final Duration flushEvery;

  final stats = RecorderStats();

  /// Called whenever [stats] change (throttled by the caller if needed).
  void Function()? onUpdate;

  bool _stopping = false;
  Completer<void>? _wake;
  StreamSubscription<GpsFix>? _gpsSub;

  bool get isStopping => _stopping;

  /// Runs until [stop] is called.
  Future<void> run() async {
    _gpsSub = gps?.listen(_onFix);
    final flushTimer = Timer.periodic(flushEvery, (_) => writer.flush());
    final sinceVoltage = Stopwatch();
    var streak = 0;
    writer.event('record_start');
    try {
      while (!_stopping) {
        // Let timers (flush, stop, UI) run even if replies arrive instantly.
        await Future<void>.delayed(Duration.zero);
        if (!sinceVoltage.isRunning || sinceVoltage.elapsed >= voltageEvery) {
          await _checkVoltage();
          sinceVoltage
            ..reset()
            ..start();
        }
        if (!stats.carOn) {
          stats.status = 'Car off: not polling, GPS only';
          onUpdate?.call();
          await _sleep(carOffRecheck);
          sinceVoltage.stop(); // force a voltage check next time round
          continue;
        }
        if (schedule.isEmpty) {
          stats.status = 'Nothing to poll: GPS only';
          onUpdate?.call();
          await _sleep(const Duration(seconds: 1));
          continue;
        }

        final target = schedule.next();
        stats.status = 'Polling ${schedule.length} DIDs';
        final ReadResult r;
        try {
          r = await uds.readDid(target.module, target.did);
        } on BusClosedException {
          stats.carOn = false;
          continue;
        } on ElmTimeoutException catch (e) {
          writer.event('timeout ${e.command}');
          streak++;
          continue;
        } on ElmSetupException catch (e) {
          writer.event('setup_error ${e.command} ${e.reply}');
          streak++;
          continue;
        }
        stats.reads++;
        switch (r) {
          case ReadValue(:final data):
            streak = 0;
            stats.values++;
            writer.did(target.module.name, target.didHex, bytesToHex(data));
          case ReadNegative(:final nrc):
            streak = 0;
            stats.negatives++;
            writer.nrc(target.module.name, target.didHex, nrc);
          case ReadNoResponse():
            streak++;
            stats.noResponses++;
        }
        if (streak >= noResponseLimit) {
          streak = 0;
          writer.event('no_response_streak');
          uds.elm.transport.gate.close();
          stats.carOn = false;
          sinceVoltage.stop();
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

  Future<void> _checkVoltage() async {
    double? v;
    try {
      v = await uds.elm.readVoltage();
    } catch (e) {
      writer.event('atrv_error $e');
    }
    writer.voltage(v);
    stats.volts = v;
    stats.carOn = uds.elm.transport.gate.isOpen;
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
