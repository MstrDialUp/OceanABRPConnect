/// Keeps the car asleep (PLAN.md §5.4): bus traffic is only allowed while a
/// recent `ATRV` reading shows the DC-DC converter running.
class BusGate {
  BusGate({
    this.onThresholdVolts = 13.0,
    this.maxReadingAge = const Duration(seconds: 90),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final double onThresholdVolts;
  final Duration maxReadingAge;
  final DateTime Function() _clock;

  double? _volts;
  DateTime? _readAt;

  double? get lastVolts => _volts;
  DateTime? get lastReadAt => _readAt;

  void recordVoltage(double volts) {
    _volts = volts;
    _readAt = _clock();
  }

  /// Forces the gate shut until the next voltage reading, e.g. after a UDS
  /// request goes unanswered.
  void close() {
    _volts = null;
    _readAt = null;
  }

  bool get isOpen {
    final v = _volts;
    final t = _readAt;
    if (v == null || t == null) return false;
    return v >= onThresholdVolts && _clock().difference(t) <= maxReadingAge;
  }
}
