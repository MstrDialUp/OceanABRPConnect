import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'signals/signal_table.dart';
import 'ui/connect_controller.dart';
import 'ui/connect_screen.dart';
import 'util/units.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final table = SignalTable.parse(await rootBundle.loadString('assets/signals/ocean.json'));
  runApp(OceanAbrpApp(table: table));
}

class OceanAbrpApp extends StatefulWidget {
  const OceanAbrpApp({super.key, required this.table});

  final SignalTable table;

  @override
  State<OceanAbrpApp> createState() => _OceanAbrpAppState();
}

class _OceanAbrpAppState extends State<OceanAbrpApp> {
  late final _controller = ConnectController(widget.table);
  // Imperial by default (PLAN.md §0); persisted settings come later.
  final _units = ValueNotifier(UnitSystem.imperial);

  @override
  void dispose() {
    _controller.dispose();
    _units.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ocean ABRP Connect',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
      home: ConnectScreen(controller: _controller, units: _units),
    );
  }
}
