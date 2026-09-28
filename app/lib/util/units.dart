/// Display-only unit conversion (PLAN.md §3.3). Values are always stored and
/// sent in metric; these helpers convert at the UI edge.
enum UnitSystem { imperial, metric }

const _kmPerMile = 1.609344;
const _kPaPerPsi = 6.894757293168361;

double kmToMiles(double km) => km / _kmPerMile;
double kmhToMph(double kmh) => kmh / _kmPerMile;
double celsiusToFahrenheit(double c) => c * 9 / 5 + 32;
double kPaToPsi(double kPa) => kPa / _kPaPerPsi;

/// Wh/km → mi/kWh. Returns infinity for zero consumption.
double whPerKmToMiPerKwh(double whPerKm) =>
    whPerKm == 0 ? double.infinity : 1000 / whPerKm / _kmPerMile;

/// A value converted for display.
class DisplayValue {
  const DisplayValue(this.value, this.unit);
  final double value;
  final String unit;

  String format({int decimals = 1}) =>
      '${value.toStringAsFixed(decimals)}${unit.isEmpty ? '' : ' $unit'}';
}

/// Converts a metric [value] in [metricUnit] for [system]. Units without an
/// imperial counterpart (%, V, A, kW, …) pass through unchanged.
DisplayValue toDisplay(double value, String? metricUnit, UnitSystem system) {
  final unit = metricUnit ?? '';
  if (system == UnitSystem.metric) return DisplayValue(value, unit);
  return switch (unit) {
    'km' => DisplayValue(kmToMiles(value), 'mi'),
    'km/h' => DisplayValue(kmhToMph(value), 'mph'),
    '°C' => DisplayValue(celsiusToFahrenheit(value), '°F'),
    'kPa' => DisplayValue(kPaToPsi(value), 'psi'),
    'Wh/km' => DisplayValue(whPerKmToMiPerKwh(value), 'mi/kWh'),
    _ => DisplayValue(value, unit),
  };
}
