import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ocean_obd/app/app_settings.dart';
import 'package:ocean_obd/platform/background.dart';
import 'package:ocean_obd/signals/assets.dart';
import 'package:ocean_obd/ui/connect_controller.dart';
import 'package:ocean_obd/ui/connect_screen.dart';
import 'package:ocean_obd/util/json_store.dart';
import 'package:path_provider/path_provider.dart';

import 'discovery/sweep_state.dart';
import 'ui/discovery_controller.dart';
import 'ui/discovery_screen.dart';
import 'ui/record_controller.dart';
import 'ui/record_screen.dart';
import 'ui/sessions_screen.dart';

/// Ocean Discovery: sweeps the car for DIDs and records sessions for
/// analysis (PLAN.md §4).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Background.notificationTitle = 'Ocean Discovery';
  Background.initCommunication();
  Background.init();

  final docs = await getApplicationDocumentsDirectory();
  final table = await loadSignalTable();
  final settings = AppSettings(JsonFileStore(File('${docs.path}/settings.json')));
  await settings.load();

  final connect = ConnectController(table);
  final discovery = DiscoveryController(
    connect: connect,
    table: table,
    store: JsonFileStore(File('${docs.path}/discovery.json')),
    bundled: await _loadBundledDids(settings.carOs),
  );
  await discovery.load();
  final sessionsDir = Directory('${docs.path}/sessions');
  final record = RecordController(
    connect: connect,
    discovery: discovery,
    settings: settings,
    sessionsDir: sessionsDir,
  );

  runApp(OceanDiscoveryApp(
    settings: settings,
    connect: connect,
    discovery: discovery,
    record: record,
    sessionsDir: sessionsDir,
  ));
}

/// The DID list for [carOs] bundled with the package, or none if there
/// isn't one.
Future<List<DidHit>> _loadBundledDids(String carOs) async {
  try {
    final text = await rootBundle.loadString(bundledDidListAsset(carOs));
    return parseBundledDidList(jsonDecode(text) as Map<String, dynamic>);
  } catch (_) {
    return const [];
  }
}

class OceanDiscoveryApp extends StatefulWidget {
  const OceanDiscoveryApp({
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
  State<OceanDiscoveryApp> createState() => _OceanDiscoveryAppState();
}

class _OceanDiscoveryAppState extends State<OceanDiscoveryApp> {
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
      title: 'Ocean Discovery',
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange),
      darkTheme: ThemeData(colorSchemeSeed: Colors.deepOrange, brightness: Brightness.dark),
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
