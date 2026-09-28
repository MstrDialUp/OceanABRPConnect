import 'package:flutter/foundation.dart';

import '../util/json_store.dart';
import '../util/units.dart';

/// User settings persisted in `settings.json`. Secrets (ABRP token) do not
/// belong here; they go in secure storage in Phase 2.
class AppSettings extends ChangeNotifier {
  AppSettings(this._store);

  final JsonFileStore _store;

  /// Imperial by default (PLAN.md §0).
  UnitSystem units = UnitSystem.imperial;

  /// Car software version written into every session header.
  String carOs = '2.2.3';

  Future<void> load() async {
    final j = await _store.load();
    if (j == null) return;
    units = UnitSystem.values.asNameMap()[j['units']] ?? units;
    carOs = j['car_os'] as String? ?? carOs;
    notifyListeners();
  }

  Future<void> update({UnitSystem? units, String? carOs}) async {
    if (units != null) this.units = units;
    if (carOs != null && carOs.trim().isNotEmpty) this.carOs = carOs.trim();
    notifyListeners();
    await _store.save({'units': this.units.name, 'car_os': this.carOs});
  }
}
