import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ocean_obd/app/app_settings.dart';
import 'package:ocean_obd/platform/background.dart';
import 'package:ocean_obd/signals/assets.dart';
import 'package:ocean_obd/ui/connect_controller.dart';
import 'package:ocean_obd/ui/connect_screen.dart';
import 'package:ocean_obd/util/json_store.dart';
import 'package:path_provider/path_provider.dart';

import 'abrp/credentials.dart';
import 'ui/link_controller.dart';
import 'ui/link_screen.dart';

/// Strait: sends live data from the car to ABRP (PLAN.md §5).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Background.notificationTitle = 'Strait';
  Background.initCommunication();
  Background.init();

  final docs = await getApplicationDocumentsDirectory();
  final table = await loadSignalTable();
  final settings = AppSettings(JsonFileStore(File('${docs.path}/settings.json')));
  await settings.load();

  final connect = ConnectController(table);
  final link = LinkController(connect: connect, table: table, store: SecureCredentialStore());
  await link.load();

  runApp(StraitApp(settings: settings, connect: connect, link: link));
}

class StraitApp extends StatefulWidget {
  const StraitApp({
    super.key,
    required this.settings,
    required this.connect,
    required this.link,
  });

  final AppSettings settings;
  final ConnectController connect;
  final LinkController link;

  @override
  State<StraitApp> createState() => _StraitAppState();
}

class _StraitAppState extends State<StraitApp> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      LinkScreen(controller: widget.link, settings: widget.settings),
      ConnectScreen(controller: widget.connect, settings: widget.settings),
    ];
    return MaterialApp(
      title: 'Strait',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
      home: Scaffold(
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.cloud_upload_outlined), label: 'ABRP'),
            NavigationDestination(icon: Icon(Icons.bluetooth), label: 'Car'),
          ],
        ),
      ),
    );
  }
}
