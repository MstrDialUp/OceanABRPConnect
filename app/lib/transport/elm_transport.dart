import 'dart:async';
import 'dart:convert';

import 'bus_gate.dart';
import 'byte_link.dart';
import 'command_policy.dart';

class BusClosedException implements Exception {
  BusClosedException(this.command);
  final String command;

  @override
  String toString() =>
      'BusClosedException: "$command" not sent, car is not on (ATRV gate closed)';
}

class ElmTimeoutException implements Exception {
  ElmTimeoutException(this.command, this.partial);
  final String command;
  final String partial;

  @override
  String toString() => 'ElmTimeoutException: no ">" after "$command" (got "$partial")';
}

/// Sends one ELM327 command at a time and returns the reply text up to the
/// `>` prompt. Every command passes [CommandPolicy] and, if it touches the
/// bus, the [BusGate]. Bus requests are spaced at least [minBusInterval]
/// apart (PLAN.md §4.5: roughly 10-12 requests per second).
class ElmTransport {
  ElmTransport(
    this._link, {
    BusGate? gate,
    this.minBusInterval = const Duration(milliseconds: 85),
    this.defaultTimeout = const Duration(seconds: 3),
  }) : gate = gate ?? BusGate() {
    _sub = _link.incoming.listen(_onBytes);
  }

  final ByteLink _link;
  final BusGate gate;
  final Duration minBusInterval;
  final Duration defaultTimeout;

  late final StreamSubscription<List<int>> _sub;
  final _buffer = StringBuffer();
  Completer<String>? _pending;
  Future<void> _queue = Future.value();
  DateTime? _lastBusSend;

  /// Called with every command and reply, for logs and debugging.
  void Function(String line)? onTrace;

  Future<String> send(String command, {Duration? timeout}) {
    final (cmd, kind) = CommandPolicy.check(command);
    final result = _queue.then((_) => _send(cmd, kind, timeout ?? defaultTimeout));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _send(String cmd, CommandKind kind, Duration timeout) async {
    if (kind == CommandKind.bus) {
      if (!gate.isOpen) throw BusClosedException(cmd);
      final last = _lastBusSend;
      if (last != null) {
        final wait = minBusInterval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _lastBusSend = DateTime.now();
    }

    _buffer.clear();
    final completer = _pending = Completer<String>();
    onTrace?.call('> $cmd');
    await _link.write(ascii.encode('$cmd\r'));
    try {
      final reply = await completer.future.timeout(timeout);
      onTrace?.call('< ${reply.replaceAll('\r', ' | ')}');
      return reply;
    } on TimeoutException {
      final partial = _buffer.toString();
      _pending = null;
      onTrace?.call('< TIMEOUT ($partial)');
      throw ElmTimeoutException(cmd, partial);
    }
  }

  void _onBytes(List<int> bytes) {
    for (final b in bytes) {
      // The ELM327 may emit NUL bytes after a reset; drop them.
      if (b == 0) continue;
      final ch = String.fromCharCode(b & 0x7F);
      if (ch == '>') {
        final reply = _clean(_buffer.toString());
        _buffer.clear();
        final p = _pending;
        _pending = null;
        if (p != null && !p.isCompleted) p.complete(reply);
      } else {
        _buffer.write(ch);
      }
    }
  }

  /// Normalises line endings and drops blank lines.
  static String _clean(String raw) => raw
      .replaceAll('\n', '\r')
      .split('\r')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join('\r');

  Future<void> close() async {
    await _sub.cancel();
    await _link.close();
  }
}
