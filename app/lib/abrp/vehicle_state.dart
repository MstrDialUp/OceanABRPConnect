import '../recorder/recorder.dart' show GpsFix;
import 'telemetry.dart';

/// Latest decoded car values and GPS, turned into ABRP telemetry points.
///
/// Values are keyed by their ABRP field name (`abrp` in ocean.json) and
/// dropped from points once they are older than their maximum age. States
/// ABRP needs but the car doesn't expose yet are inferred (PLAN.md §2.3):
///  * parked: speed below 1 km/h for [parkedAfter];
///  * charging: pack current below [chargingBelowA] while stationary;
///  * DC fast charging: charging at more than [dcfcAboveKw] (the Ocean's
///    on-board AC charger tops out at 11 kW).
class VehicleState {
  VehicleState({
    DateTime Function()? clock,
    this.parkedAfter = const Duration(seconds: 60),
    this.chargingBelowA = -5,
    this.dcfcAboveKw = 12,
    this.defaultMaxAge = const Duration(seconds: 15),
    this.maxAge = const {
      'odometer': Duration(minutes: 3),
      'batt_temp': Duration(minutes: 2),
    },
    this.gpsMaxAge = const Duration(seconds: 10),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Duration parkedAfter;
  final double chargingBelowA;
  final double dcfcAboveKw;
  final Duration defaultMaxAge;
  final Map<String, Duration> maxAge;
  final Duration gpsMaxAge;

  final _values = <String, (double, DateTime)>{};
  GpsFix? _fix;
  DateTime? _fixAt;
  DateTime? _stoppedSince;

  /// Records a car value for ABRP [field].
  void update(String field, double value) {
    final now = _clock();
    _values[field] = (value, now);
    if (field == 'speed') _trackStops(value, now);
  }

  void updateGps(GpsFix fix) {
    _fix = fix;
    _fixAt = _clock();
    // Only use GPS for stop tracking when the car's speed isn't available.
    if (_fresh('speed') == null && fix.speedKmh != null) _trackStops(fix.speedKmh!, _fixAt!);
  }

  /// Forgets car values, e.g. when the adapter disconnects or the car is off.
  void clearCar() {
    _values.clear();
    _stoppedSince = null;
  }

  double? value(String field) => _fresh(field);

  void _trackStops(double speedKmh, DateTime now) {
    if (speedKmh < 1) {
      _stoppedSince ??= now;
    } else {
      _stoppedSince = null;
    }
  }

  double? _fresh(String field) {
    final v = _values[field];
    if (v == null) return null;
    final age = _clock().difference(v.$2);
    return age <= (maxAge[field] ?? defaultMaxAge) ? v.$1 : null;
  }

  /// The current telemetry point, or null when there is no fresh car data
  /// (GPS alone isn't worth sending).
  TelemetryPoint? snapshot() {
    final now = _clock();
    final voltage = _fresh('voltage');
    final current = _fresh('current');
    final power = voltage != null && current != null ? voltage * current / 1000 : null;
    final carSpeed = _fresh('speed');
    final fix = _fixAt != null && now.difference(_fixAt!) <= gpsMaxAge ? _fix : null;
    final speed = carSpeed ?? fix?.speedKmh;

    final stationary = speed != null && speed < 1;
    final charging = current != null && current < chargingBelowA && (speed == null || stationary);
    final parked = charging ||
        (_stoppedSince != null && now.difference(_stoppedSince!) >= parkedAfter);

    final point = TelemetryPoint(
      utc: now.millisecondsSinceEpoch ~/ 1000,
      soc: _fresh('soc'),
      power: power,
      speed: speed,
      lat: fix?.lat,
      lon: fix?.lon,
      heading: fix?.headingDeg,
      elevation: fix?.altitudeM,
      isCharging: current == null ? null : charging,
      isDcfc: charging ? (power != null && -power > dcfcAboveKw) : null,
      isParked: speed == null ? null : parked,
      voltage: voltage,
      current: current,
      odometer: _fresh('odometer'),
      battTemp: _fresh('batt_temp'),
    );
    final hasCarData = point.soc != null || power != null || carSpeed != null;
    return hasCarData ? point : null;
  }
}
