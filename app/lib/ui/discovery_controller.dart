import 'package:flutter/foundation.dart';

import '../discovery/discovery_sweep.dart';
import '../discovery/sweep_state.dart';
import '../elm/ecu_module.dart';
import '../recorder/poll_schedule.dart';
import '../signals/signal_table.dart';
import '../util/json_store.dart';
import 'connect_controller.dart';

class DiscoveryController extends ChangeNotifier {
  DiscoveryController({required this.connect, required this.table, required this.store});

  final ConnectController connect;
  final SignalTable table;
  final JsonFileStore store;

  final String rangesKey = DiscoverySweep.rangesKeyFor(defaultSweepRanges);
  late SweepState state = SweepState(rangesKey: rangesKey);
  DiscoverySweep? _sweep;
  bool running = false;
  bool _cancel = false;
  String? message;

  List<EcuModule> get modules => table.modules.values.toList();

  Future<void> load() async {
    final j = await store.load();
    if (j != null) {
      final loaded = SweepState.fromJson(j);
      // Saved progress only applies to the same DID ranges.
      if (loaded.rangesKey == rangesKey) state = loaded;
    }
    notifyListeners();
  }

  DiscoverySweep _newSweep() => DiscoverySweep(
        uds: connect.uds!,
        modules: modules,
        state: state,
        save: (s) => store.save(s.toJson()),
      );

  /// Fraction done and a label, available whether or not a sweep is running.
  static final _didCount = DiscoverySweep.didsIn(defaultSweepRanges).length;

  (int, int) get progress => DiscoverySweep.progressOf(state, modules, _didCount);

  String get currentStep => _sweep?.currentStep ?? '';

  bool get finished {
    final (done, total) = progress;
    return done == total && state.obdDone && state.monitor != null;
  }

  Future<void> start() async {
    if (running || connect.uds == null) return;
    running = true;
    _cancel = false;
    message = null;
    final sweep = _sweep = _newSweep();
    notifyListeners();
    try {
      await sweep.run(isCancelled: () => _cancel, onProgress: notifyListeners);
      message = sweep.finished ? 'Sweep finished.' : 'Sweep stopped. Progress saved.';
    } on SweepPaused catch (e) {
      message = e.reason;
    } catch (e) {
      message = 'Sweep error: $e. Progress saved; you can resume.';
    } finally {
      running = false;
      connect.refresh();
      notifyListeners();
    }
  }

  void stop() {
    _cancel = true;
    notifyListeners();
  }

  Future<void> reset() async {
    if (running) return;
    state = SweepState(rangesKey: rangesKey);
    _sweep = null;
    await store.delete();
    message = 'Sweep results cleared.';
    notifyListeners();
  }

  /// DIDs that answered positively, for recording. Falls back to the known
  /// signals from ocean.json when no sweep has been done.
  List<PollTarget> recordTargets() {
    final targets = <PollTarget>{
      for (final s in table.signals) PollTarget(s.module, s.did),
    };
    for (final h in state.positiveHits) {
      final m = table.modules[h.module];
      if (m != null) targets.add(PollTarget(m, h.did));
    }
    return targets.toList();
  }
}
