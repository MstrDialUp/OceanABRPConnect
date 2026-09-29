/// One ABRP telemetry point (PLAN.md §2.2). Everything is metric; null
/// fields are left out of the JSON.
class TelemetryPoint {
  const TelemetryPoint({
    required this.utc,
    this.soc,
    this.power,
    this.speed,
    this.lat,
    this.lon,
    this.isCharging,
    this.isDcfc,
    this.isParked,
    this.heading,
    this.elevation,
    this.voltage,
    this.current,
    this.odometer,
    this.battTemp,
  });

  /// Epoch seconds.
  final int utc;
  final double? soc;

  /// kW, positive = discharging, negative = charging.
  final double? power;

  /// km/h.
  final double? speed;
  final double? lat;
  final double? lon;
  final bool? isCharging;
  final bool? isDcfc;
  final bool? isParked;
  final double? heading;
  final double? elevation;
  final double? voltage;

  /// A, positive = discharging.
  final double? current;

  /// km.
  final double? odometer;
  final double? battTemp;

  /// Enough for ABRP to do anything useful with.
  bool get hasVehicleData => soc != null || power != null || speed != null;

  Map<String, dynamic> toJson() {
    double r(double v, int places) {
      final f = [1, 10, 100, 1000, 10000, 100000, 1000000][places];
      return (v * f).roundToDouble() / f;
    }

    return {
      'utc': utc,
      if (soc != null) 'soc': r(soc!, 1),
      if (power != null) 'power': r(power!, 2),
      if (speed != null) 'speed': r(speed!, 1),
      if (lat != null) 'lat': r(lat!, 6),
      if (lon != null) 'lon': r(lon!, 6),
      if (isCharging != null) 'is_charging': isCharging! ? 1 : 0,
      if (isDcfc != null) 'is_dcfc': isDcfc! ? 1 : 0,
      if (isParked != null) 'is_parked': isParked! ? 1 : 0,
      if (heading != null) 'heading': r(heading!, 1),
      if (elevation != null) 'elevation': r(elevation!, 1),
      if (voltage != null) 'voltage': r(voltage!, 1),
      if (current != null) 'current': r(current!, 1),
      if (odometer != null) 'odometer': r(odometer!, 1),
      if (battTemp != null) 'batt_temp': r(battTemp!, 1),
    };
  }
}
