/// A raw, bidirectional byte pipe to the adapter (BLE UART, or a fake in tests).
abstract class ByteLink {
  /// Bytes received from the adapter, in arrival order.
  Stream<List<int>> get incoming;

  Future<void> write(List<int> bytes);

  Future<void> close();
}
