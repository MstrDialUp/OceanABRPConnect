import 'dart:async';
import 'dart:collection';

import 'abrp_client.dart';
import 'telemetry.dart';

/// Sends telemetry to ABRP on a schedule (PLAN.md §5.1): every
/// [drivingInterval] while driving, every [idleInterval] while parked or
/// charging. Points that fail for network reasons are kept (up to
/// [bufferLimit], oldest dropped first) and flushed with `tlm/bulk` once
/// sending works again.
class AbrpUploader {
  AbrpUploader({
    required this.client,
    required this.snapshot,
    DateTime Function()? clock,
    this.drivingInterval = const Duration(seconds: 5),
    this.idleInterval = const Duration(seconds: 30),
    this.bufferLimit = 720,
    this.bulkBatch = 100,
  }) : _clock = clock ?? DateTime.now;

  final AbrpClient client;

  /// The point to send now, or null if there's nothing worth sending.
  final TelemetryPoint? Function() snapshot;
  final DateTime Function() _clock;
  final Duration drivingInterval;
  final Duration idleInterval;
  final int bufferLimit;
  final int bulkBatch;

  final buffer = Queue<TelemetryPoint>();
  int sent = 0;
  int dropped = 0;
  DateTime? lastSuccessAt;
  AbrpResult? lastResult;
  TelemetryPoint? lastPoint;
  String status = 'Not started';

  /// Called after every tick.
  void Function()? onUpdate;

  bool _stopping = false;
  Completer<void>? _wake;

  Duration get interval {
    final p = lastPoint;
    final idle = p != null && (p.isParked == true || p.isCharging == true);
    return idle ? idleInterval : drivingInterval;
  }

  Future<void> run() async {
    _stopping = false;
    while (!_stopping) {
      await tick();
      await _sleep(interval);
    }
    status = 'Stopped';
    onUpdate?.call();
  }

  void stop() {
    _stopping = true;
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// One upload cycle: flush the buffer if there is one, then send the
  /// current point.
  Future<void> tick() async {
    final point = snapshot();
    if (point == null) {
      status = 'Waiting for car data';
      onUpdate?.call();
      return;
    }
    lastPoint = point;

    if (buffer.isNotEmpty) {
      final flushed = await _flush();
      if (!flushed) {
        _keep(point);
        onUpdate?.call();
        return;
      }
    }

    final r = await client.send(point);
    lastResult = r;
    switch (r.outcome) {
      case AbrpOutcome.ok:
        sent++;
        lastSuccessAt = _clock();
        status = 'Sending';
      case AbrpOutcome.network:
        _keep(point);
        status = 'Offline: buffering (${buffer.length})';
      case AbrpOutcome.http:
      case AbrpOutcome.rejected:
        // Retrying the same data won't help; show the error instead.
        status = 'ABRP error';
    }
    onUpdate?.call();
  }

  /// Sends buffered points in batches. Returns false if the network is
  /// still down.
  Future<bool> _flush() async {
    while (buffer.isNotEmpty) {
      final batch = buffer.take(bulkBatch).toList();
      final r = await client.bulk(batch);
      lastResult = r;
      if (r.outcome == AbrpOutcome.network) {
        status = 'Offline: buffering (${buffer.length})';
        return false;
      }
      for (var i = 0; i < batch.length; i++) {
        buffer.removeFirst();
      }
      if (r.ok) {
        sent += batch.length;
        lastSuccessAt = _clock();
      } else {
        dropped += batch.length; // rejected: resending won't help
      }
    }
    return true;
  }

  void _keep(TelemetryPoint p) {
    buffer.addLast(p);
    while (buffer.length > bufferLimit) {
      buffer.removeFirst();
      dropped++;
    }
  }

  Future<void> _sleep(Duration d) async {
    if (_stopping) return;
    final wake = _wake = Completer<void>();
    await Future.any([wake.future, Future<void>.delayed(d)]);
  }
}
