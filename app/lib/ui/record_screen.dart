import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_settings.dart';
import '../recorder/checklist.dart';
import '../util/units.dart';
import 'record_controller.dart';

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key, required this.controller, required this.settings});

  final RecordController controller;
  final AppSettings settings;

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  Timer? _ticker;

  RecordController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // Keeps the elapsed time moving even when no readings arrive.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (c.recording && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _stop() async {
    await c.stop();
    if (!mounted) return;
    await _openChecklist();
  }

  Future<void> _openChecklist() async {
    final report = await Navigator.of(context).push<StopReport>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ChecklistScreen(units: widget.settings.units),
    ));
    await c.saveChecklist(report ?? StopReport());
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Session saved (Sessions tab).')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.connect, widget.settings]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final stats = c.stats;
        final connected = c.connect.uds != null;
        final elapsed =
            c.startedAt == null ? Duration.zero : DateTime.now().difference(c.startedAt!);
        final speed = stats?.lastFix?.speedKmh;
        return Scaffold(
          appBar: AppBar(title: const Text('Record')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (c.error != null)
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(padding: const EdgeInsets.all(12), child: Text(c.error!)),
                ),
              const SizedBox(height: 16),
              Center(
                child: SizedBox(
                  width: 220,
                  height: 220,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      backgroundColor: c.recording ? theme.colorScheme.error : null,
                    ),
                    onPressed: c.starting
                        ? null
                        : c.recording
                            ? _stop
                            : c.awaitingChecklist
                                ? _openChecklist
                                : connected
                                    ? c.start
                                    : null,
                    child: Text(
                      c.starting
                          ? 'Starting…'
                          : c.recording
                              ? 'Stop\nRecording'
                              : c.awaitingChecklist
                                  ? 'Finish\nchecklist'
                                  : 'Start\nRecording',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (!connected && !c.recording)
                const Text('Connect to the adapter first (Connect tab).',
                    textAlign: TextAlign.center),
              if (!c.recording && !c.awaitingChecklist)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Start before the trip. You can then lock the phone and drive; '
                    'recording continues in the background. Stop after the trip.',
                    textAlign: TextAlign.center,
                  ),
                ),
              if (stats != null) ...[
                ListTile(title: const Text('Elapsed'), trailing: Text(_fmt(elapsed))),
                ListTile(
                  title: const Text('Status'),
                  subtitle: Text(stats.status),
                  trailing: Text(stats.volts == null
                      ? '? V'
                      : '${stats.volts!.toStringAsFixed(1)} V ${stats.carOn ? '(on)' : '(off)'}'),
                ),
                ListTile(
                  title: Text('Reads (${c.targetCount} DIDs)'),
                  trailing: Text('${stats.values} values · ${stats.negatives} refused · '
                      '${stats.noResponses} no reply'),
                ),
                ListTile(
                  title: const Text('GPS fixes'),
                  trailing: Text('${stats.gpsFixes}'
                      '${speed == null ? '' : ' · ${toDisplay(speed, 'km/h', widget.settings.units).format(decimals: 0)}'}'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _fmt(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }
}

/// Stop checklist (PLAN.md §4.2). Pops with a [StopReport] in metric.
class ChecklistScreen extends StatefulWidget {
  const ChecklistScreen({super.key, required this.units});

  final UnitSystem units;

  @override
  State<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<ChecklistScreen> {
  final _checked = <String>{};
  final _soc = TextEditingController();
  final _range = TextEditingController();
  final _temp = TextEditingController();
  final _odo = TextEditingController();
  final _notes = TextEditingController();

  @override
  void dispose() {
    for (final c in [_soc, _range, _temp, _odo, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _metric(TextEditingController c, String unit) {
    final v = double.tryParse(c.text.trim());
    return v == null ? null : fromDisplay(v, unit, widget.units);
  }

  void _save() {
    Navigator.pop(
      context,
      StopReport(
        checked: Set.of(_checked),
        socPercent: double.tryParse(_soc.text.trim()),
        rangeKm: _metric(_range, 'km'),
        outsideTempC: _metric(_temp, '°C'),
        odometerKm: _metric(_odo, 'km'),
        notes: _notes.text.trim(),
      ),
    );
  }

  Widget _number(TextEditingController c, String label, String unit) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(labelText: label, suffixText: unit),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final u = widget.units;
    return PopScope(
      // The session is saved either way; leaving without Save saves the
      // checklist as filled so far.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _save();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('What happened?'),
          actions: [TextButton(onPressed: _save, child: const Text('Save'))],
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final (key, label) in checklistItems)
              CheckboxListTile(
                title: Text(label),
                value: _checked.contains(key),
                onChanged: (v) => setState(() => v == true ? _checked.add(key) : _checked.remove(key)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  Text('Dash readings now (optional)', style: Theme.of(context).textTheme.titleMedium),
                  _number(_soc, 'State of charge', '%'),
                  _number(_range, 'Range shown', displayUnit('km', u)),
                  _number(_temp, 'Outside temperature', displayUnit('°C', u)),
                  _number(_odo, 'Odometer', displayUnit('km', u)),
                  TextField(
                    controller: _notes,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _save, child: const Text('Save session')),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
