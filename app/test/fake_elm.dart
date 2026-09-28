import 'dart:async';
import 'dart:convert';

import 'package:ocean_abrp_connect/transport/byte_link.dart';

/// A scripted ELM327: replies to each command from [replies] (or with
/// [defaultReply]) followed by the `>` prompt, optionally split into chunks
/// to mimic BLE notifications.
class FakeElm implements ByteLink {
  FakeElm({Map<String, String>? replies, this.defaultReply = 'OK', this.chunkSize = 7})
      : replies = replies ?? {};

  final Map<String, String> replies;
  final String defaultReply;
  final int chunkSize;

  /// Commands received, without the trailing `\r`.
  final sent = <String>[];

  /// When false, commands get no reply at all (to test timeouts).
  bool responsive = true;

  final _incoming = StreamController<List<int>>();

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final cmd = ascii.decode(bytes).replaceAll('\r', '');
    sent.add(cmd);
    if (!responsive) return;
    final reply = '${replies[cmd] ?? defaultReply}\r\r>';
    final data = ascii.encode(reply);
    scheduleMicrotask(() {
      for (var i = 0; i < data.length; i += chunkSize) {
        _incoming.add(data.sublist(i, i + chunkSize > data.length ? data.length : i + chunkSize));
      }
    });
  }

  @override
  Future<void> close() => _incoming.close();
}
