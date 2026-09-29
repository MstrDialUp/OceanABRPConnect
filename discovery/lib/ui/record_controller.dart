import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:ocean_obd/app/app_settings.dart';
import 'package:ocean_obd/app/build_info.dart';
import 'package:ocean_obd/platform/background.dart';
import '../recorder/checklist.dart';
import '../recorder/poll_schedule.dart';
import '../recorder/recorder.dart';
import '../recorder/session_file.dart';
import 'package:ocean_obd/ui/connect_controller.dart';
import 'discovery_controller.dart';

class RecordController extends ChangeNotifier {
  RecordController({
    required this.connect,
    required this.discovery,
    required this.settings,
    required this.sessionsDir,
  });

  final ConnectController connect;
  final DiscoveryController discovery;
  final AppSettings settings;
  final Directory sessionsDir;

  Recorder? _recorder;
  SessionWriter? _writer;
  Future<void>? _run;
  DateTime? startedAt;
  bool starting = false;
  String? error;
  int targetCount = 0;
  DateTime _lastNotify = DateTime(0);

  /// Bumped each time a session is saved, so the Sessions list reloads.
  final saved = ValueNotifier(0);

  bool get recording => _recorder != null && !_recorder!.isStopping;

  /// True after Stop until the checklist is saved.
  bool get awaitingChecklist => _writer != null && _recorder == null;

  RecorderStats? get stats => _recorder?.stats;

  Future<void> start() async {
    if (recording || starting || awaitingChecklist) return;
    final uds = connect.uds;
    if (uds == null) {
      error = 'Connect to the adapter first.';
      notifyListeners();
      return;
    }
    starting = true;
    error = null;
    notifyListeners();
    try {
      final permError = await Background.requestPermissions();
      if (permError != null) {
        error = permError;
        return;
      }
      await uds.elm.readVoltage();
      final start = DateTime.now();
      final writer = _writer = await SessionWriter.create(
        sessionsDir,
        SessionHeader(
          appVersion: BuildInfo.label,
          gitSha: BuildInfo.gitSha,
          carOs: settings.carOs,
          start: start,
          adapter: connect.adapterId,
          vin: await connect.readVin(),
        ),
      );
      final targets = discovery.recordTargets();
      targetCount = targets.poll.length;
      final recorder = _recorder = Recorder(
        uds: () => connect.uds,
        writer: writer,
        schedule: PollSchedule(targets.poll),
        onceTargets: targets.once,
        gps: Background.gpsFixes(),
      )..onUpdate = _throttledNotify;
      startedAt = start;
      final fgsError = await Background.start('record', 'Recording a session');
      if (fgsError != null) writer.event('fgs_error $fgsError');
      _run = recorder.run().catchError((Object e) {
        writer.event('recorder_error $e');
        error = 'Recorder stopped: $e';
      });
    } catch (e) {
      error = 'Could not start: $e';
      await _writer?.close();
      _writer = null;
      _recorder = null;
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final r = _recorder;
    if (r == null) return;
    r.stop();
    notifyListeners();
    await _run;
    _run = null;
    _recorder = null;
    await Background.stop('record');
    connect.refresh();
    notifyListeners();
  }

  Future<void> saveChecklist(StopReport report) async {
    final w = _writer;
    if (w == null) return;
    await w.finish(report);
    saved.value++;
    _writer = null;
    startedAt = null;
    notifyListeners();
  }

  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastNotify) < const Duration(milliseconds: 500)) return;
    _lastNotify = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _recorder?.stop();
    _writer?.close();
    saved.dispose();
    super.dispose();
  }
}
