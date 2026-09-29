import 'dart:convert';

import '../elm/ecu_module.dart';

enum SignalType { ascii, uint, int }

class SignalDecodeException implements Exception {
  SignalDecodeException(this.signalId, this.message);
  final String signalId;
  final String message;

  @override
  String toString() => 'SignalDecodeException($signalId): $message';
}

/// One row of `assets/signals/ocean.json`.
class SignalDef {
  SignalDef({
    required this.id,
    required this.name,
    required this.module,
    required this.did,
    required this.type,
    this.offset = 0,
    this.length,
    this.scale = 1,
    this.add = 0,
    this.unit,
    this.abrpField,
    this.pollSeconds = 0,
    this.verified = false,
  });

  final String id;
  final String name;
  final EcuModule module;
  final int did;
  final SignalType type;
  final int offset;

  /// Bytes to read; null means "to the end" (for ASCII).
  final int? length;
  final double scale;
  final double add;

  /// Metric unit of the decoded value.
  final String? unit;
  final String? abrpField;
  final int pollSeconds;
  final bool verified;

  String get didHex => did.toRadixString(16).padLeft(4, '0').toUpperCase();

  /// Decodes the data bytes that follow the DID echo in a 0x62 response.
  /// Returns a [String] for ASCII signals and a [double] otherwise.
  Object decode(List<int> data) {
    final end = length == null ? data.length : offset + length!;
    if (offset < 0 || end > data.length || end <= offset) {
      throw SignalDecodeException(
          id, 'needs bytes $offset..${end - 1}, got ${data.length}');
    }
    final bytes = data.sublist(offset, end);
    switch (type) {
      case SignalType.ascii:
        return String.fromCharCodes(bytes.where((b) => b >= 0x20 && b < 0x7F)).trim();
      case SignalType.uint:
      case SignalType.int:
        var raw = 0;
        for (final b in bytes) {
          raw = (raw << 8) | b;
        }
        if (type == SignalType.int && bytes.isNotEmpty && bytes.first & 0x80 != 0) {
          raw -= 1 << (8 * bytes.length);
        }
        return raw * scale + add;
    }
  }
}

class SignalTable {
  SignalTable({required this.osVersion, required this.modules, required this.signals});

  final String osVersion;
  final Map<String, EcuModule> modules;
  final List<SignalDef> signals;

  SignalDef? byId(String id) {
    for (final s in signals) {
      if (s.id == id) return s;
    }
    return null;
  }

  static SignalTable parse(String jsonText) {
    final root = jsonDecode(jsonText) as Map<String, dynamic>;
    final modules = <String, EcuModule>{};
    (root['modules'] as Map<String, dynamic>).forEach((name, v) {
      final m = v as Map<String, dynamic>;
      modules[name] = EcuModule(
        name,
        int.parse(m['tx'] as String, radix: 16),
        int.parse(m['rx'] as String, radix: 16),
      );
    });

    final signals = <SignalDef>[];
    for (final raw in root['signals'] as List<dynamic>) {
      final s = raw as Map<String, dynamic>;
      final id = s['id'] as String;
      final module = modules[s['module']];
      if (module == null) {
        throw FormatException('signal $id: unknown module ${s['module']}');
      }
      signals.add(SignalDef(
        id: id,
        name: s['name'] as String? ?? id,
        module: module,
        did: int.parse(s['did'] as String, radix: 16),
        type: SignalType.values.byName(s['type'] as String),
        offset: s['offset'] as int? ?? 0,
        length: s['length'] as int?,
        scale: (s['scale'] as num? ?? 1).toDouble(),
        add: (s['add'] as num? ?? 0).toDouble(),
        unit: s['unit'] as String?,
        abrpField: s['abrp'] as String?,
        pollSeconds: s['poll_s'] as int? ?? 0,
        verified: s['verified'] as bool? ?? false,
      ));
    }
    return SignalTable(
      osVersion: root['os_version'] as String? ?? 'unknown',
      modules: modules,
      signals: signals,
    );
  }
}
