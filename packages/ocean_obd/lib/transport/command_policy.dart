/// Read-only allow-list for everything written to the adapter (PLAN.md §1.4).
///
/// Only three kinds of command may leave the app:
///  * ELM327 `AT` commands from a fixed list of adapter setup/query commands,
///  * UDS `0x22` ReadDataByIdentifier requests,
///  * OBD-II mode `01` (current data) requests.
///
/// Anything else, including DTC clears (`0x14`), writes (`0x2E`), routines
/// (`0x31`), resets (`0x11`) and session changes (`0x10`), is rejected.
library;

class ForbiddenCommandException implements Exception {
  ForbiddenCommandException(this.command, this.reason);

  final String command;
  final String reason;

  @override
  String toString() => 'ForbiddenCommandException: "$command" ($reason)';
}

/// Whether a command only talks to the adapter or puts traffic on the CAN bus.
enum CommandKind {
  /// Handled inside the adapter; nothing is sent on the vehicle bus.
  adapterLocal,

  /// Sends a frame on the bus (or makes the adapter listen to it).
  bus,
}

class CommandPolicy {
  const CommandPolicy._();

  /// AT commands that listen to the bus.
  static const _busAtPrefixes = <String>['MA'];

  /// Normalises and checks [raw]. Returns the command to send and its kind,
  /// or throws [ForbiddenCommandException].
  static (String, CommandKind) check(String raw) {
    if (raw.contains('\r') || raw.contains('\n') || raw.contains('>')) {
      throw ForbiddenCommandException(raw, 'contains a line break or prompt');
    }
    final cmd = raw.replaceAll(' ', '').toUpperCase();
    if (cmd.isEmpty) {
      throw ForbiddenCommandException(raw, 'empty');
    }

    if (cmd.startsWith('AT')) {
      final body = cmd.substring(2);
      if (_busAtPrefixes.any((p) => body == p)) {
        return (cmd, CommandKind.bus);
      }
      if (_isAllowedLocalAt(body)) {
        return (cmd, CommandKind.adapterLocal);
      }
      throw ForbiddenCommandException(raw, 'AT command not on the allow-list');
    }

    if (!RegExp(r'^[0-9A-F]+$').hasMatch(cmd) || cmd.length.isOdd) {
      throw ForbiddenCommandException(raw, 'not an AT command or hex request');
    }
    final service = int.parse(cmd.substring(0, 2), radix: 16);
    final payloadBytes = cmd.length ~/ 2 - 1;
    switch (service) {
      case 0x22:
        // One or more 2-byte DIDs.
        if (payloadBytes < 2 || payloadBytes.isOdd) {
          throw ForbiddenCommandException(raw, 'malformed 0x22 request');
        }
        return (cmd, CommandKind.bus);
      case 0x01:
        // Mode 01 with 1..6 PIDs.
        if (payloadBytes < 1 || payloadBytes > 6) {
          throw ForbiddenCommandException(raw, 'malformed mode 01 request');
        }
        return (cmd, CommandKind.bus);
      default:
        throw ForbiddenCommandException(
          raw,
          'service 0x${service.toRadixString(16).padLeft(2, '0')} is not read-only',
        );
    }
  }

  static bool _isAllowedLocalAt(String body) {
    // Exact-argument commands.
    const exact = {
      'Z', 'WS', 'D', 'DP', 'DPN', 'E0', 'E1', 'S0', 'S1', 'H0', 'H1', //
      'L0', 'L1', 'CAF0', 'CAF1', 'AR', 'AT0', 'AT1', 'AT2', 'RV', 'I', '@1',
      'FCSM0', 'FCSM1',
    };
    if (exact.contains(body)) return true;

    final hex = RegExp(r'^[0-9A-F]+$');
    bool hexArg(String prefix, Set<int> lengths) =>
        body.startsWith(prefix) &&
        lengths.contains(body.length - prefix.length) &&
        hex.hasMatch(body.substring(prefix.length));

    return hexArg('SP', {1}) ||
        hexArg('SPA', {1}) ||
        hexArg('TP', {1}) ||
        hexArg('SH', {3, 6, 8}) ||
        hexArg('FCSH', {3, 6, 8}) ||
        hexArg('FCSD', {2, 4, 6, 8, 10}) ||
        hexArg('CRA', {3, 8}) ||
        hexArg('ST', {2});
  }
}
