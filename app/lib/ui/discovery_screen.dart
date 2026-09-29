import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../discovery/sweep_state.dart';
import 'discovery_controller.dart';

class DiscoveryScreen extends StatelessWidget {
  const DiscoveryScreen({super.key, required this.controller});

  final DiscoveryController controller;

  Future<void> _confirmAndStart(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Parked?'),
        content: const Text(
          'Only run the sweep while parked with the car in Ready. It sends '
          'read-only requests to every module for 20–30 minutes in total. '
          'You can stop at any time; progress is saved.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true), child: const Text('Parked, start')),
        ],
      ),
    );
    if (ok == true) await controller.start();
  }

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear sweep results?'),
        content: const Text('All responding DIDs and progress will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) await controller.reset();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.connect]),
      builder: (context, _) {
        final (done, total) = c.progress;
        final connected = c.connect.uds != null;
        final state = c.state;
        return Scaffold(
          appBar: AppBar(title: const Text('Discovery sweep')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (c.message != null)
                Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(c.message!))),
              LinearProgressIndicator(value: total == 0 ? 0 : done / total),
              const SizedBox(height: 4),
              Text('$done / $total DID requests'
                  '${c.running && c.currentStep.isNotEmpty ? '  ·  ${c.currentStep}' : ''}'),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (!c.running)
                  FilledButton(
                    onPressed: connected && !c.finished ? () => _confirmAndStart(context) : null,
                    child: Text(done == 0 ? 'Start sweep' : 'Resume sweep'),
                  )
                else
                  FilledButton.tonal(onPressed: c.stop, child: const Text('Stop')),
                OutlinedButton(
                  onPressed: c.store.file.existsSync()
                      ? () => SharePlus.instance.share(ShareParams(
                            files: [XFile(c.store.file.path, mimeType: 'application/json')],
                            subject: 'Ocean discovery results',
                          ))
                      : null,
                  child: const Text('Share results'),
                ),
                TextButton(
                  onPressed: c.running ? null : () => _confirmReset(context),
                  child: const Text('Clear'),
                ),
              ]),
              if (!connected)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Connect to the adapter first (Connect tab).'),
                ),
              const Divider(height: 32),
              Text('Modules', style: Theme.of(context).textTheme.titleMedium),
              for (final m in c.modules) _moduleTile(m.name, state),
              const Divider(height: 32),
              Text('Responding DIDs: ${state.positiveHits.length} with data, '
                  '${state.hits.length - state.positiveHits.length} refused'),
              Text('Bundled with the app: ${c.bundled.length} DIDs '
                  '(used for recording even without a local sweep)'),
              const SizedBox(height: 8),
              Text('OBD mode 01: ${state.obdDone ? '' : 'not done'}'),
              for (final e in state.obd.entries)
                Text('  01${e.key}: ${e.value}', style: const TextStyle(fontFamily: 'monospace')),
              const SizedBox(height: 8),
              Text(state.monitor == null
                  ? 'Passive listen: not done'
                  : 'Passive listen: ${state.monitor!['lines']} lines, '
                      'IDs ${(state.monitor!['ids'] as List).join(' ')}'),
            ],
          ),
        );
      },
    );
  }

  Widget _moduleTile(String name, SweepState state) {
    final p = state.modules[name];
    final hits = state.hits.where((h) => h.module == name);
    final label = switch (p?.status) {
      null || ModuleSweepStatus.pending => 'pending',
      ModuleSweepStatus.inProgress => 'in progress',
      ModuleSweepStatus.done => 'done',
      ModuleSweepStatus.silent => 'no reply (absent or asleep)',
      ModuleSweepStatus.noService => '0x22 not supported',
    };
    return ListTile(
      dense: true,
      title: Text(name),
      subtitle: Text(label),
      trailing: Text('${hits.where((h) => h.positive).length} DIDs'),
    );
  }
}
