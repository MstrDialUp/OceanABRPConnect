import 'package:flutter/foundation.dart';

import '../discovery/discovery_sweep.dart';
import '../discovery/sweep_state.dart';
import '../elm/ecu_module.dart';
import '../recorder/poll_schedule.dart';
import '../signals/signal_table.dart';
import '../util/json_store.dart';
import 'connect_controller.dart';

class DiscoveryController extends ChangeNotifier {
  DiscoveryController({
    required this.connect,
    required this.table,
    required this.store,
    this.bundled = const [],
  });

  final ConnectController connect;
  final SignalTable table;
  final JsonFileStore store;

  /// DIDs from the sweep bundled with the app, so recording works on a fresh
  /// install without running Discover again.
  final List<DidHit> bundled;

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

  /// What to record: DIDs that answered positively in the local sweep or
  /// the bundled list, plus the known signals. Identification DIDs (and known signals that aren't
  /// polled, like the VIN) go in [once]; the rest are polled.
  ({List<PollTarget> poll, List<PollTarget> once}) recordTargets() =>
      splitRecordTargets(table, state, bundled: bundled);
}

/// See [DiscoveryController.recordTargets].
({List<PollTarget> poll, List<PollTarget> once}) splitRecordTargets(
  SignalTable table,
  SweepState state, {
  List<DidHit> bundled = const [],
}) {
  final poll = <PollTarget>{};
  final once = <PollTarget>{};
  for (final s in table.signals) {
    (s.pollSeconds > 0 ? poll : once).add(PollTarget(s.module, s.did));
  }
  for (final h in [...state.positiveHits, ...bundled]) {
    final m = table.modules[h.module];
    if (m == null) continue;
    final t = PollTarget(m, h.did);
    if (poll.contains(t)) continue;
    (isIdentificationDid(h.did) ? once : poll).add(t);
  }
  once.removeAll(poll);
  return (poll: poll.toList(), once: once.toList());
}
