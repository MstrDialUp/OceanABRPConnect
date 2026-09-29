import 'package:flutter/services.dart';

import 'signal_table.dart';

/// Where the package's signal assets live, as seen by an app's asset bundle.
const signalTableAsset = 'packages/ocean_obd/assets/signals/ocean.json';

/// The DID list from a discovery sweep for Ocean OS [carOs].
String bundledDidListAsset(String carOs) => 'packages/ocean_obd/assets/signals/sweep_os-$carOs.json';

Future<SignalTable> loadSignalTable([AssetBundle? bundle]) async =>
    SignalTable.parse(await (bundle ?? rootBundle).loadString(signalTableAsset));
