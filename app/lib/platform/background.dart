import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../recorder/recorder.dart';

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
      return 'Location is turned off. Turn it on to record GPS.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return 'Location permission is needed to record GPS.';
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    return null;
  }

  static Future<String?> start(String text) async {
    if (!Platform.isAndroid) return null;
    final ServiceRequestResult r;
    if (await FlutterForegroundTask.isRunningService) {
      r = await FlutterForegroundTask.updateService(notificationText: text);
    } else {
      r = await FlutterForegroundTask.startService(
        serviceTypes: [
          ForegroundServiceTypes.connectedDevice,
          ForegroundServiceTypes.location,
        ],
        notificationTitle: 'Ocean ABRP',
        notificationText: text,
        callback: _startCallback,
      );
    }
    return r is ServiceRequestFailure ? '${r.error}' : null;
  }

  static Future<void> stop() async {
    if (Platform.isAndroid && await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// GPS fixes about once a second, converted to metric [GpsFix]es.
  static Stream<GpsFix> gpsFixes() => Geolocator.getPositionStream(
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
