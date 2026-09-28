import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../elm/elm_client.dart';
import '../elm/elm_response.dart';
import '../signals/signal_table.dart';
import '../transport/ble_uart_link.dart';
import '../transport/elm_transport.dart';
import '../uds/uds_client.dart';

enum LinkState { idle, scanning, connecting, connected, failed }

/// Result of reading one known signal, for display next to the dash value.
class SignalReading {
  SignalReading(this.signal, this.result, {this.value, this.error});

  final SignalDef signal;
  final ReadResult? result;
  final Object? value;
  final String? error;

  String get rawHex => switch (result) {
        ReadValue(:final data) => bytesToHex(data),
        _ => '',
      };

  String get status => switch (result) {
        ReadValue() => error ?? 'ok',
        ReadNegative(:final nrc, :final description) =>
          'NRC 0x${nrc.toRadixString(16).padLeft(2, '0').toUpperCase()} $description',
        ReadNoResponse(:final reason) => 'no response ($reason)',
        null => error ?? '',
      };
}

/// Drives the Connect screen: scan, connect, ELM setup, ATRV and reading the
/// known values (PLAN.md §4.1, screen 1).
class ConnectController extends ChangeNotifier {
  ConnectController(this.table);

  final SignalTable table;

  LinkState state = LinkState.idle;
  String? error;
  List<ScanResult> scanResults = [];
  String? adapterId;
  String? linkDescription;
  double? volts;
  bool busy = false;
  List<SignalReading> readings = [];
  final trace = <String>[];

  BleUartLink? _link;
  ElmTransport? _transport;
  ElmClient? _elm;
  UdsClient? _uds;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  bool get carOn => _transport?.gate.isOpen ?? false;

  static bool looksLikeAdapter(ScanResult r) {
    final name = r.device.platformName.toLowerCase();
    return name.contains('vlink') || name.contains('obd') || name.contains('elm');
  }

  Future<void> startScan() async {
    error = null;
    scanResults = [];
    state = LinkState.scanning;
    notifyListeners();
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      scanResults = results.where((r) => r.device.platformName.isNotEmpty).toList()
        ..sort((a, b) {
          final byAdapter = (looksLikeAdapter(b) ? 1 : 0) - (looksLikeAdapter(a) ? 1 : 0);
          return byAdapter != 0 ? byAdapter : b.rssi.compareTo(a.rssi);
        });
      notifyListeners();
    });
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } catch (e) {
      _fail('Scan failed: $e');
      return;
    }
    if (state == LinkState.scanning) {
      state = LinkState.idle;
      notifyListeners();
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    state = LinkState.connecting;
    error = null;
    trace.clear();
    notifyListeners();
    try {
      final link = _link = await BleUartLink.connect(device);
      linkDescription = link.description;
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && state == LinkState.connected) {
          _fail('Adapter disconnected');
        }
      });
      final transport = _transport = ElmTransport(link)..onTrace = _addTrace;
      final elm = _elm = ElmClient(transport);
      _uds = UdsClient(elm);
      await elm.initialize();
      adapterId = await elm.adapterId();
      volts = await elm.readVoltage();
      state = LinkState.connected;
      notifyListeners();
    } catch (e) {
      await _teardown();
      _fail('Connect failed: $e');
    }
  }

  /// Re-reads ATRV (nothing is sent on the CAN bus).
  Future<void> checkVoltage() => _guard(() async {
        volts = await _elm!.readVoltage();
      });

  /// Reads each known signal once. Only runs if ATRV shows the car on.
  Future<void> readKnownValues() => _guard(() async {
        volts = await _elm!.readVoltage();
        if (!carOn) {
          error = 'Car appears off (${volts?.toStringAsFixed(1) ?? '?'} V). '
              'Nothing sent on the bus.';
          return;
        }
        readings = [];
        for (final s in table.signals) {
          readings.add(await _readSignal(s));
          notifyListeners();
        }
        if (readings.every((r) => r.result is ReadNoResponse)) {
          // PLAN.md §5.4: no answers → stop and fall back to the ATRV check.
          _transport!.gate.close();
          error = 'No module answered. Stopped; check the car is in Ready.';
        }
      });

  Future<SignalReading> _readSignal(SignalDef s) async {
    try {
      final r = await _uds!.readDid(s.module, s.did);
      if (r is ReadValue) {
        try {
          return SignalReading(s, r, value: s.decode(r.data));
        } on SignalDecodeException catch (e) {
          return SignalReading(s, r, error: e.message);
        }
      }
      return SignalReading(s, r);
    } catch (e) {
      return SignalReading(s, null, error: '$e');
    }
  }

  Future<void> disconnect() async {
    await _teardown();
    state = LinkState.idle;
    readings = [];
    adapterId = null;
    volts = null;
    notifyListeners();
  }

  Future<void> _guard(Future<void> Function() body) async {
    if (busy || _elm == null) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _addTrace(String line) {
    trace.add(line);
    if (trace.length > 300) trace.removeRange(0, trace.length - 300);
    notifyListeners();
  }

  void _fail(String message) {
    error = message;
    state = LinkState.failed;
    notifyListeners();
  }

  Future<void> _teardown() async {
    await _connSub?.cancel();
    _connSub = null;
    final t = _transport;
    _transport = null;
    _elm = null;
    _uds = null;
    try {
      if (t != null) {
        await t.close();
      } else {
        await _link?.close();
      }
    } catch (_) {}
    _link = null;
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _teardown();
    super.dispose();
  }
}
