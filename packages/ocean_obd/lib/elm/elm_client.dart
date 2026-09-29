import '../transport/elm_transport.dart';
import 'ecu_module.dart';
import 'elm_response.dart';

class ElmSetupException implements Exception {
  ElmSetupException(this.command, this.reply);
  final String command;
  final String reply;

  @override
  String toString() => 'ElmSetupException: "$command" → "$reply"';
}

/// ELM327 session: setup sequence, adapter voltage, and module addressing
/// (PLAN.md §1.1).
class ElmClient {
  ElmClient(this.transport);

  final ElmTransport transport;

  EcuModule? _current;
  bool _flowControlUserMode = false;

  /// Runs the setup sequence. Sends nothing on the CAN bus.
  Future<void> initialize() async {
    _current = null;
    _flowControlUserMode = false;
    await transport.send('ATZ', timeout: const Duration(seconds: 5));
    await _expectOk('ATE0');
    await _expectOk('ATL0');
    await _expectOk('ATS0');
    await _expectOk('ATH1');
    await _expectOk('ATSP6');
    // Flow control frames: "clear to send, no block limit, no separation".
    await _expectOk('ATFCSD300000');
  }

  Future<String> adapterId() => transport.send('ATI');

  /// Reads the adapter's supply voltage (the OBD port pin) with `ATRV` and
  /// updates the bus gate. Sends nothing on the CAN bus.
  Future<double?> readVoltage() async {
    final reply = await transport.send('ATRV');
    final volts = parseVoltage(reply);
    if (volts != null) transport.gate.recordVoltage(volts);
    return volts;
  }

  static double? parseVoltage(String reply) {
    final m = RegExp(r'(\d+(?:\.\d+)?)\s*V', caseSensitive: false).firstMatch(reply);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  /// Points requests at [module]. Only resends headers when the module changes.
  Future<void> select(EcuModule module) async {
    if (_current == module) return;
    _current = null;
    await _expectOk('ATSH${module.txHex}');
    if (module == EcuModule.functional) {
      // Replies may come from any ECU; let the adapter pick the FC address.
      await _expectOk('ATAR');
      if (_flowControlUserMode) {
        await _expectOk('ATFCSM0');
        _flowControlUserMode = false;
      }
    } else {
      await _expectOk('ATFCSH${module.txHex}');
      await _expectOk('ATCRA${module.rxHex}');
      if (!_flowControlUserMode) {
        await _expectOk('ATFCSM1');
        _flowControlUserMode = true;
      }
    }
    _current = module;
  }

  /// Sends a hex request to the selected module and parses the frames.
  Future<ElmResponse> request(String hex, {Duration? timeout}) async {
    final reply = await transport.send(hex, timeout: timeout);
    return ElmResponse.parse(reply);
  }

  Future<void> _expectOk(String cmd) async {
    final reply = await transport.send(cmd);
    if (!reply.toUpperCase().contains('OK')) {
      throw ElmSetupException(cmd, reply);
    }
  }
}
