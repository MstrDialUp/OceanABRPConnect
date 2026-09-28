/// A diagnostic module on the bus, addressed by its request (tx) and
/// response (rx) CAN IDs (PLAN.md §1.2).
class EcuModule {
  const EcuModule(this.name, this.tx, this.rx);

  final String name;
  final int tx;
  final int rx;

  /// Functional (broadcast) address for OBD-II requests.
  static const functional = EcuModule('OBD', 0x7DF, 0x7E8);

  String get txHex => tx.toRadixString(16).toUpperCase().padLeft(3, '0');
  String get rxHex => rx.toRadixString(16).toUpperCase().padLeft(3, '0');

  @override
  bool operator ==(Object other) =>
      other is EcuModule && other.name == name && other.tx == tx && other.rx == rx;

  @override
  int get hashCode => Object.hash(name, tx, rx);

  @override
  String toString() => '$name($txHex/$rxHex)';
}
