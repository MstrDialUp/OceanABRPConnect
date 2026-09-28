import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_settings.dart';
import 'platform/background.dart';
import 'signals/signal_table.dart';
import 'ui/connect_controller.dart';
import 'ui/connect_screen.dart';
import 'ui/discovery_controller.dart';
import 'ui/discovery_screen.dart';
import 'ui/record_controller.dart';
import 'ui/record_screen.dart';
import 'ui/sessions_screen.dart';
import 'util/json_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Background.initCommunication();
  Background.init();

  final docs = await getApplicationDocumentsDirectory();
  final table = SignalTable.parse(await rootBundle.loadString('assets/signals/ocean.json'));
  final settings = AppSettings(JsonFileStore(File('${docs.path}/settings.json')));
  await settings.load();

  final connect = ConnectController(table);
  final discovery = DiscoveryController(
    connect: connect,
    table: table,
    store: JsonFileStore(File('${docs.path}/discovery.json')),
  );
  await discovery.load();
  final sessionsDir = Directory('${docs.path}/sessions');
  final record = RecordController(
    connect: connect,
    discovery: discovery,
    settings: settings,
    sessionsDir: sessionsDir,
  );

  runApp(OceanAbrpApp(
    settings: settings,
    connect: connect,
    discovery: discovery,
    record: record,
    sessionsDir: sessionsDir,
  ));
}

class OceanAbrpApp extends StatefulWidget {
  const OceanAbrpApp({
    super.key,
    required this.settings,
    required this.connect,
    required this.discovery,
    required this.record,
    required this.sessionsDir,
  });

  final AppSettings settings;
  final ConnectController connect;
  final DiscoveryController discovery;
  final RecordController record;
  final Directory sessionsDir;

  @override
  State<OceanAbrpApp> createState() => _OceanAbrpAppState();
}

class _OceanAbrpAppState extends State<OceanAbrpApp> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ConnectScreen(controller: widget.connect, settings: widget.settings),
      DiscoveryScreen(controller: widget.discovery),
      RecordScreen(controller: widget.record, settings: widget.settings),
      SessionsScreen(dir: widget.sessionsDir, refresh: widget.record.saved),
    ];
    return MaterialApp(
      title: 'Ocean ABRP Connect',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
      home: Scaffold(
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.bluetooth), label: 'Connect'),
            NavigationDestination(icon: Icon(Icons.radar), label: 'Discover'),
            NavigationDestination(icon: Icon(Icons.fiber_manual_record), label: 'Record'),
            NavigationDestination(icon: Icon(Icons.folder_open), label: 'Sessions'),
          ],
        ),
      ),
    );
  }
}
