/// The stop checklist (PLAN.md §4.2). Keys are what goes in the session
/// footer, so they must stay stable.
const checklistItems = <(String, String)>[
  ('parked_ready', 'Parked, car in Ready, not moving'),
  ('city', 'City driving (under 60 km/h)'),
  ('highway', 'Highway driving'),
  ('hard_accel', 'Hard acceleration'),
  ('strong_regen', 'Strong regenerative braking'),
  ('reverse', 'Reversing'),
  ('heating', 'Heating used'),
  ('ac', 'Air conditioning used'),
  ('ac_charging', 'AC charging (Level 1 or 2)'),
  ('dc_charging', 'DC fast charging'),
  ('charge_start_stop', 'Charging started or stopped during the session'),
  ('precondition', 'Preconditioning'),
  ('drive_mode', 'Hyper / Earth / Fun mode changed (list which in notes)'),
];

String checklistLabel(String key) {
  for (final (k, label) in checklistItems) {
    if (k == key) return label;
  }
  return key;
}

/// What the user fills in on stop. Dash readings are metric (the UI converts
/// from display units before building this).
class StopReport {
  StopReport({
    this.checked = const {},
    this.socPercent,
    this.rangeKm,
    this.outsideTempC,
    this.odometerKm,
    this.notes = '',
  });

  final Set<String> checked;
  final double? socPercent;
  final double? rangeKm;
  final double? outsideTempC;
  final double? odometerKm;
  final String notes;

  Map<String, dynamic> toJson() => {
        'checklist': [
          for (final (k, _) in checklistItems)
            if (checked.contains(k)) k,
        ],
        'dash': {
          if (socPercent != null) 'soc': socPercent,
          if (rangeKm != null) 'range_km': rangeKm,
          if (outsideTempC != null) 'ext_temp_c': outsideTempC,
          if (odometerKm != null) 'odometer_km': odometerKm,
        },
        'notes': notes,
      };
}
