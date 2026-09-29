import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import 'gps_fix.dart';

/// The foreground service only keeps the process alive and shows the
/// persistent notification (PLAN.md §3.2). BLE polling and GPS stay in the
/// main isolate, because the BLE plugin is bound to the main engine.
@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class Background {
  /// Title of the persistent notification; each app sets its own name.
  static String notificationTitle = 'Ocean';

  static void initCommunication() => FlutterForegroundTask.initCommunicationPort();

  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'recording',
        channelName: 'Recording',
        channelDescription: 'Shown while the app is reading the car.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
      ),
    );
  }

  /// Asks for notification, location and battery-optimisation exemptions.
  /// Returns an error message, or null if recording can start.
  static Future<String?> requestPermissions() async {
    if (!Platform.isAndroid) return null;
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Location is turned off. Turn it on so GPS can be recorded and sent.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return 'Location permission is needed to record and send GPS.';
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    return null;
  }

  /// Who currently needs the service (e.g. "record", "abrp"), and what
  /// each is doing, for the notification text.
  static final _holders = <String, String>{};

  /// Starts the service (or updates its text) on behalf of [holder].
  static Future<String?> start(String holder, String text) async {
    _holders[holder] = text;
    if (!Platform.isAndroid) return null;
    final ServiceRequestResult r;
    if (await FlutterForegroundTask.isRunningService) {
      r = await FlutterForegroundTask.updateService(notificationText: _text);
    } else {
      r = await FlutterForegroundTask.startService(
        serviceTypes: [
          ForegroundServiceTypes.connectedDevice,
          ForegroundServiceTypes.location,
        ],
        notificationTitle: notificationTitle,
        notificationText: _text,
        callback: _startCallback,
      );
    }
    return r is ServiceRequestFailure ? '${r.error}' : null;
  }

  /// Releases [holder]'s claim; the service stops when nobody needs it.
  static Future<void> stop(String holder) async {
    _holders.remove(holder);
    if (!Platform.isAndroid || !await FlutterForegroundTask.isRunningService) return;
    if (_holders.isEmpty) {
      await FlutterForegroundTask.stopService();
    } else {
      await FlutterForegroundTask.updateService(notificationText: _text);
    }
  }

  static String get _text => _holders.values.join(' · ');

  static StreamController<GpsFix>? _gps;
  static StreamSubscription<GpsFix>? _gpsSource;

  /// GPS fixes about once a second, converted to metric [GpsFix]es. One
  /// platform stream is shared by every listener (recording, ABRP link).
  static Stream<GpsFix> gpsFixes() {
    final c = _gps ??= StreamController<GpsFix>.broadcast(
      onListen: () => _gpsSource = _positions().listen(_gps!.add, onError: _gps!.addError),
      onCancel: () async {
        await _gpsSource?.cancel();
        _gpsSource = null;
      },
    );
    return c.stream;
  }

  static Stream<GpsFix> _positions() => Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1),
        ),
      ).map((p) => GpsFix(
            lat: p.latitude,
            lon: p.longitude,
            speedKmh: p.speed >= 0 ? p.speed * 3.6 : null,
            headingDeg: p.heading >= 0 ? p.heading : null,
            altitudeM: p.altitude,
            accuracyM: p.accuracy,
            timeMs: p.timestamp.millisecondsSinceEpoch,
          ));
}
