import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../recorder/checklist.dart';
import '../recorder/session_file.dart';

/// Saved sessions with duration, size and checklist summary, plus export
/// through the share sheet (PLAN.md §4.1, screen 4).
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.dir, required this.refresh});

  final Directory dir;

  /// Bumped by the app whenever a session is saved.
  final Listenable refresh;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late Future<List<SessionSummary>> _sessions = _load();

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_reload);
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_reload);
    super.dispose();
  }

  void _reload() => setState(() => _sessions = _load());

  Future<List<SessionSummary>> _load() async {
    if (!await widget.dir.exists()) return [];
    final files = await widget.dir
        .list()
        .where((e) => e is File && e.path.endsWith('.jsonl'))
        .cast<File>()
        .toList();
    final summaries = await Future.wait(files.map(SessionSummary.read));
    summaries.sort((a, b) => b.name.compareTo(a.name));
    return summaries;
  }

  Future<void> _delete(SessionSummary s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text(s.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await s.file.delete();
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh))],
      ),
      body: FutureBuilder(
        future: _sessions,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('No sessions yet.'));
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = list[i];
              final checklist = s.hasFooter
                  ? (s.checklist.isEmpty ? 'nothing ticked' : s.checklist.map(checklistLabel).join(', '))
                  : 'no checklist (recording was interrupted)';
              return ListTile(
                title: Text(s.name),
                subtitle: Text('${_duration(s.duration)} · ${_size(s.sizeBytes)} · OS ${s.carOs ?? '?'}\n'
                    '$checklist${s.notes.isEmpty ? '' : '\n“${s.notes}”'}'),
                isThreeLine: true,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.share),
                    tooltip: 'Share',
                    onPressed: () => SharePlus.instance.share(ShareParams(
                      files: [XFile(s.file.path, mimeType: 'application/x-ndjson')],
                      subject: s.name,
                    )),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () => _delete(s),
                  ),
                ]),
              );
            },
          );
        },
      ),
    );
  }

  static String _duration(Duration? d) {
    if (d == null) return '?';
    if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
    if (d.inMinutes > 0) return '${d.inMinutes} min';
    return '${d.inSeconds} s';
  }

  static String _size(int bytes) {
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} kB';
  }
}
