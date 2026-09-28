import 'package:flutter/material.dart';

import '../app/app_settings.dart';
import '../util/units.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _carOs = TextEditingController(text: widget.settings.carOs);

  @override
  void dispose() {
    _carOs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Units', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<UnitSystem>(
              segments: const [
                ButtonSegment(value: UnitSystem.imperial, label: Text('Imperial')),
                ButtonSegment(value: UnitSystem.metric, label: Text('Metric')),
              ],
              selected: {s.units},
              onSelectionChanged: (v) => s.update(units: v.first),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Display only. Recordings and ABRP data are always metric.'),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _carOs,
              decoration: const InputDecoration(
                labelText: 'Car software version',
                helperText: 'Saved in every recording; update it after an OTA.',
              ),
              onChanged: (v) => s.update(carOs: v),
            ),
          ],
        ),
      ),
    );
  }
}
