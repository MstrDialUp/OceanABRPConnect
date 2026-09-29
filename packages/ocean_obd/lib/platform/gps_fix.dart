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
