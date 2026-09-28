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

/// Weighted round-robin over the DIDs to record (PLAN.md §4.1, screen 3):
/// targets on [priorityModules] (BMS, VCU, MCUs) get [priorityWeight] turns
/// for every one turn of the rest.
class PollSchedule {
  PollSchedule(
    Iterable<PollTarget> targets, {
    this.priorityModules = const {'BMS', 'VCU', 'MCU_F', 'MCU_R'},
    this.priorityWeight = 3,
  }) {
    for (final t in targets.toSet()) {
      (priorityModules.contains(t.module.name) ? _priority : _other).add(t);
    }
  }

  final Set<String> priorityModules;
  final int priorityWeight;
  final _priority = <PollTarget>[];
  final _other = <PollTarget>[];
  int _pi = 0;
  int _oi = 0;
  int _turn = 0;

  bool get isEmpty => _priority.isEmpty && _other.isEmpty;
  int get length => _priority.length + _other.length;

  PollTarget next() {
    if (isEmpty) throw StateError('empty schedule');
    final usePriority =
        _other.isEmpty || (_priority.isNotEmpty && _turn % (priorityWeight + 1) != priorityWeight);
    _turn++;
    if (usePriority) {
      return _priority[_pi++ % _priority.length];
    }
    return _other[_oi++ % _other.length];
  }
}
