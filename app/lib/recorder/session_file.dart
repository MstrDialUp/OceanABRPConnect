import 'dart:convert';
import 'dart:io';

import 'checklist.dart';

/// Session files are JSONL (PLAN.md §4.3): a header line, one line per
/// reading, and a footer line. Everything is metric; `t` is epoch ms.
const sessionFormatVersion = 1;

class SessionHeader {
  SessionHeader({
    required this.appVersion,
    required this.carOs,
    required this.start,
    this.adapter,
    this.vin,
    this.gitSha,
  });

  final String appVersion;
  final String? gitSha;
  final String carOs;
  final DateTime start;
  final String? adapter;
  final String? vin;

  Map<String, dynamic> toJson() => {
        'type': 'header',
        'format': sessionFormatVersion,
        't': start.millisecondsSinceEpoch,
        'start': start.toUtc().toIso8601String(),
        'app': appVersion,
        'git': ?gitSha,
        'car_os': carOs,
        'adapter': adapter,
        'vin': vin,
      };
}

class SessionWriter {
  SessionWriter._(this.file, this._sink, this._clock);

  final File file;
  final IOSink _sink;
  final DateTime Function() _clock;
  int lines = 0;
  bool _closed = false;

  static Future<SessionWriter> create(
    Directory dir,
    SessionHeader header, {
    DateTime Function()? clock,
  }) async {
    await dir.create(recursive: true);
    final file = File('${dir.path}/${fileNameFor(header.start)}');
    final w = SessionWriter._(file, file.openWrite(), clock ?? DateTime.now);
    w._line(header.toJson());
    await w.flush();
    return w;
  }

  static String fileNameFor(DateTime start) {
    String two(int v) => v.toString().padLeft(2, '0');
    final s = start.toLocal();
    return 'session_${s.year}${two(s.month)}${two(s.day)}_'
        '${two(s.hour)}${two(s.minute)}${two(s.second)}.jsonl';
  }

  int get _now => _clock().millisecondsSinceEpoch;

  void did(String module, String didHex, String rawHex) =>
      _line({'t': _now, 'type': 'did', 'mod': module, 'did': didHex, 'raw': rawHex});

  void nrc(String module, String didHex, int nrc) => _line({
        't': _now,
        'type': 'nrc',
        'mod': module,
        'did': didHex,
        'nrc': nrc.toRadixString(16).padLeft(2, '0').toUpperCase(),
      });

  /// [speedKmh] and [headingDeg] may be null when the fix doesn't have them.
  void gps({
    required double lat,
    required double lon,
    double? speedKmh,
    double? headingDeg,
    double? altitudeM,
    double? accuracyM,
    int? fixTimeMs,
  }) =>
      _line({
        't': _now,
        'type': 'gps',
        'lat': lat,
        'lon': lon,
        if (speedKmh != null) 'spd': _round(speedKmh, 2),
        if (headingDeg != null) 'hdg': _round(headingDeg, 1),
        if (altitudeM != null) 'alt': _round(altitudeM, 1),
        if (accuracyM != null) 'acc': _round(accuracyM, 1),
        'fix_t': ?fixTimeMs,
      });

  void voltage(double? volts) => _line({'t': _now, 'type': 'atrv', 'v': volts});

  void event(String what) => _line({'t': _now, 'type': 'event', 'what': what});

  Future<void> flush() => _sink.flush();

  Future<void> finish(StopReport report) async {
    if (_closed) return;
    final now = _clock();
    _line({
      'type': 'footer',
      't': now.millisecondsSinceEpoch,
      'stop': now.toUtc().toIso8601String(),
      ...report.toJson(),
    });
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.flush();
    await _sink.close();
  }

  void _line(Map<String, dynamic> obj) {
    if (_closed) return;
    _sink.writeln(jsonEncode(obj));
    lines++;
  }

  static double _round(double v, int places) {
    final f = [1, 10, 100, 1000][places];
    return (v * f).roundToDouble() / f;
  }
}

/// What the Sessions screen shows for a file.
class SessionSummary {
  SessionSummary({
    required this.file,
    required this.sizeBytes,
    this.start,
    this.duration,
    this.carOs,
    this.checklist = const [],
    this.hasFooter = false,
    this.notes = '',
  });

  final File file;
  final int sizeBytes;
  final DateTime? start;
  final Duration? duration;
  final String? carOs;
  final List<String> checklist;
  final bool hasFooter;
  final String notes;

  String get name => file.uri.pathSegments.last;

  /// Reads the header and the last line. A session without a footer (the app
  /// was killed before the checklist) uses the last reading's time.
  static Future<SessionSummary> read(File file) async {
    final size = await file.length();
    final lines = const LineSplitter().convert(await file.readAsString());
    Map<String, dynamic>? decode(String l) {
      try {
        return jsonDecode(l) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }

    final header = lines.isEmpty ? null : decode(lines.first);
    Map<String, dynamic>? last;
    for (var i = lines.length - 1; i > 0 && last == null; i--) {
      last = decode(lines[i]);
    }
    final startMs = header?['t'] as int?;
    final endMs = last?['t'] as int?;
    final footer = last?['type'] == 'footer' ? last : null;
    return SessionSummary(
      file: file,
      sizeBytes: size,
      start: startMs == null ? null : DateTime.fromMillisecondsSinceEpoch(startMs),
      duration: startMs != null && endMs != null ? Duration(milliseconds: endMs - startMs) : null,
      carOs: header?['car_os'] as String?,
      checklist: [for (final k in footer?['checklist'] as List<dynamic>? ?? []) k as String],
      hasFooter: footer != null,
      notes: footer?['notes'] as String? ?? '',
    );
  }
}
