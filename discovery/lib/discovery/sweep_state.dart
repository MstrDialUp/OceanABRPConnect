/// Saved state of the discovery sweep (PLAN.md §4.1, screen 2), so the sweep
/// can run in several short sittings. Serialised to `discovery.json`.
library;

enum ModuleSweepStatus {
  pending,
  inProgress,
  done,

  /// No reply at all to the first requests: module absent or asleep.
  silent,

  /// Replied "serviceNotSupported" to 0x22.
  noService,
}

class ModuleProgress {
  ModuleProgress({this.next = 0, this.status = ModuleSweepStatus.pending, this.answered = 0});

  /// Index into the flattened DID list of the next DID to request.
  int next;
  ModuleSweepStatus status;

  /// Requests that got any reply (positive or negative).
  int answered;

  bool get finished =>
      status == ModuleSweepStatus.done ||
      status == ModuleSweepStatus.silent ||
      status == ModuleSweepStatus.noService;

  Map<String, dynamic> toJson() => {'next': next, 'status': status.name, 'answered': answered};

  static ModuleProgress fromJson(Map<String, dynamic> j) => ModuleProgress(
        next: j['next'] as int? ?? 0,
        status: ModuleSweepStatus.values.byName(j['status'] as String? ?? 'pending'),
        answered: j['answered'] as int? ?? 0,
      );
}

/// A DID that answered: positively (it exists and returned data) or with a
/// negative response other than requestOutOfRange (it exists but refused).
class DidHit {
  DidHit({required this.module, required this.did, this.nrc, this.sample = ''});

  final String module;
  final int did;

  /// Null for a positive response.
  final int? nrc;

  /// Hex data from the first positive response.
  final String sample;

  bool get positive => nrc == null;
  String get didHex => did.toRadixString(16).padLeft(4, '0').toUpperCase();

  Map<String, dynamic> toJson() => {
        'mod': module,
        'did': didHex,
        if (nrc != null) 'nrc': nrc!.toRadixString(16).padLeft(2, '0').toUpperCase(),
        if (sample.isNotEmpty) 'sample': sample,
      };

  static DidHit fromJson(Map<String, dynamic> j) => DidHit(
        module: j['mod'] as String,
        did: int.parse(j['did'] as String, radix: 16),
        nrc: j['nrc'] == null ? null : int.parse(j['nrc'] as String, radix: 16),
        sample: j['sample'] as String? ?? '',
      );
}

class SweepState {
  SweepState({
    required this.rangesKey,
    Map<String, ModuleProgress>? modules,
    List<DidHit>? hits,
    Map<String, String>? obd,
    this.obdDone = false,
    this.monitor,
    this.updated,
  })  : modules = modules ?? {},
        hits = hits ?? [],
        obd = obd ?? {};

  /// Identifies the DID ranges the `next` indices refer to. If the ranges
  /// change, saved progress no longer applies.
  final String rangesKey;
  final Map<String, ModuleProgress> modules;
  final List<DidHit> hits;

  /// OBD mode 01 PID (hex) → data hex, or "NRC xx" / "none".
  final Map<String, String> obd;
  bool obdDone;

  /// Passive listen result: {"lines": n, "ids": [...], "sample": [...]}.
  Map<String, dynamic>? monitor;
  DateTime? updated;

  ModuleProgress progressFor(String module) =>
      modules.putIfAbsent(module, () => ModuleProgress());

  List<DidHit> get positiveHits => hits.where((h) => h.positive).toList();

  Map<String, dynamic> toJson() => {
        'ranges': rangesKey,
        'updated': updated?.toUtc().toIso8601String(),
        'modules': modules.map((k, v) => MapEntry(k, v.toJson())),
        'hits': hits.map((h) => h.toJson()).toList(),
        'obd': obd,
        'obd_done': obdDone,
        'monitor': monitor,
      };

  static SweepState fromJson(Map<String, dynamic> j) => SweepState(
        rangesKey: j['ranges'] as String? ?? '',
        updated: j['updated'] == null ? null : DateTime.parse(j['updated'] as String),
        modules: (j['modules'] as Map<String, dynamic>? ?? {}).map(
            (k, v) => MapEntry(k, ModuleProgress.fromJson(v as Map<String, dynamic>))),
        hits: [
          for (final h in j['hits'] as List<dynamic>? ?? [])
            DidHit.fromJson(h as Map<String, dynamic>),
        ],
        obd: (j['obd'] as Map<String, dynamic>? ?? {}).cast<String, String>(),
        obdDone: j['obd_done'] as bool? ?? false,
        monitor: j['monitor'] as Map<String, dynamic>?,
      );
}

/// Parses a DID list bundled with the app (`assets/signals/sweep_os-*.json`,
/// written by `tools/analyze/export_did_list.py`) into positive hits.
List<DidHit> parseBundledDidList(Map<String, dynamic> json) => [
      for (final MapEntry(key: module, value: dids)
          in (json['dids'] as Map<String, dynamic>? ?? {}).entries)
        for (final did in dids as List<dynamic>)
          DidHit(module: module, did: int.parse(did as String, radix: 16)),
    ];
