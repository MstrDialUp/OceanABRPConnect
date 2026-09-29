import '../elm/ecu_module.dart';

class PollTarget {
  const PollTarget(this.module, this.did);

  final EcuModule module;
  final int did;

  String get didHex => did.toRadixString(16).padLeft(4, '0').toUpperCase();

  @override
  bool operator ==(Object other) =>
      other is PollTarget && other.module == module && other.did == did;

  @override
  int get hashCode => Object.hash(module, did);

  @override
  String toString() => '${module.name}:$didHex';
}

/// Identification and snapshot DIDs (ISO 14229 `F1xx`, supplier `EFxx`).
/// Their values don't change during a drive, so they are read once per
/// session rather than polled.
bool isIdentificationDid(int did) =>
    (did >= 0xF100 && did <= 0xF1FF) || (did >= 0xEF00 && did <= 0xEFFF);

/// Polling order for recording (PLAN.md §4.1, screen 3).
///
/// Each module's DIDs are read back to back, because switching modules
/// costs three extra adapter round trips (`ATSH`, `ATFCSH`, `ATCRA`). A
/// round reads every [priorityModules] group, then one other group in
/// rotation, so priority modules are read about twice as often or more.
class PollSchedule {
  PollSchedule(
    Iterable<PollTarget> targets, {
    this.priorityModules = const {'BMS', 'VCU', 'MCU_F', 'MCU_R', 'ESP'},
  }) {
    for (final t in targets.toSet()) {
      final groups = priorityModules.contains(t.module.name) ? _priority : _other;
      groups.putIfAbsent(t.module.name, () => []).add(t);
    }
  }

  final Set<String> priorityModules;
  final _priority = <String, List<PollTarget>>{};
  final _other = <String, List<PollTarget>>{};
  final _queue = <PollTarget>[];
  int _nextOther = 0;

  bool get isEmpty => _priority.isEmpty && _other.isEmpty;

  int get length =>
      [..._priority.values, ..._other.values].fold(0, (n, g) => n + g.length);

  PollTarget next() {
    if (isEmpty) throw StateError('empty schedule');
    if (_queue.isEmpty) _fillRound();
    return _queue.removeAt(0);
  }

  void _fillRound() {
    for (final g in _priority.values) {
      _queue.addAll(g);
    }
    if (_other.isNotEmpty) {
      final others = _other.values.toList();
      _queue.addAll(others[_nextOther++ % others.length]);
    }
  }
}
