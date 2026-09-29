import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_discovery/discovery/sweep_state.dart';
import 'package:ocean_obd/elm/ecu_module.dart';
import 'package:ocean_obd/elm/elm_client.dart';
import 'package:ocean_discovery/recorder/checklist.dart';
import 'package:ocean_discovery/recorder/poll_schedule.dart';
import 'package:ocean_discovery/recorder/recorder.dart';
import 'package:ocean_obd/platform/gps_fix.dart';
import 'package:ocean_discovery/recorder/session_file.dart';
import 'package:ocean_obd/signals/signal_table.dart';
import 'package:ocean_obd/transport/elm_transport.dart';
import 'package:ocean_obd/uds/uds_client.dart';
import 'package:ocean_discovery/ui/discovery_controller.dart';

import 'package:ocean_obd/testing/fake_elm.dart';

const bms = EcuModule('BMS', 0x7E1, 0x7E9);
const vcu = EcuModule('VCU', 0x7C2, 0x7CA);
const ecc = EcuModule('ECC', 0x7F0, 0x7F8);
const esp = EcuModule('ESP', 0x7D0, 0x7D8);

/// Waits until [cond] holds (timers are coarse on some platforms).
Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw StateError('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

List<Map<String, dynamic>> readLines(File f) => const LineSplitter()
    .convert(f.readAsStringSync())
    .map((l) => jsonDecode(l) as Map<String, dynamic>)
    .toList();

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('ocean_rec'));
  tearDown(() async => dir.delete(recursive: true));

  Future<SessionWriter> newWriter() => SessionWriter.create(
        dir,
        SessionHeader(appVersion: 'test', carOs: '2.2.3', start: DateTime(2026, 9, 28, 8), adapter: 'ELM327 v2.2'),
      );

  group('PollSchedule', () {
    test('reads each module back to back; priority modules every round', () {
      final s = PollSchedule(const [
        PollTarget(bms, 0x2050),
        PollTarget(ecc, 0x2001),
        PollTarget(bms, 0x2003),
        PollTarget(vcu, 0xEFF9),
        PollTarget(esp, 0xFD00),
        PollTarget(ecc, 0x2002),
      ], priorityModules: const {'BMS', 'VCU'});
      final order = [for (var i = 0; i < 12; i++) s.next().toString()];
      expect(order, [
        'BMS:2050', 'BMS:2003', 'VCU:EFF9', 'ECC:2001', 'ECC:2002', //
        'BMS:2050', 'BMS:2003', 'VCU:EFF9', 'ESP:FD00',
        'BMS:2050', 'BMS:2003', 'VCU:EFF9',
      ]);
    });

    test('module switches are rare', () {
      final targets = [
        for (var d = 0; d < 60; d++) PollTarget(bms, 0x2000 + d),
        for (var d = 0; d < 40; d++) PollTarget(ecc, 0x3400 + d),
      ];
      final s = PollSchedule(targets);
      final seq = [for (var i = 0; i < 1000; i++) s.next().module.name];
      var switches = 0;
      for (var i = 1; i < seq.length; i++) {
        if (seq[i] != seq[i - 1]) switches++;
      }
      expect(switches, lessThan(25));
    });

    test('works with only one kind of target', () {
      final s = PollSchedule(const [PollTarget(ecc, 1), PollTarget(ecc, 2)]);
      expect([s.next(), s.next(), s.next()].map((t) => t.did), [1, 2, 1]);
    });

    test('deduplicates targets', () {
      expect(PollSchedule(const [PollTarget(bms, 1), PollTarget(bms, 1)]).length, 1);
    });

    test('identification DIDs', () {
      expect(isIdentificationDid(0xF190), isTrue);
      expect(isIdentificationDid(0xEFF7), isFalse); // live: vehicle speed
      expect(isIdentificationDid(0x2050), isFalse);
      expect(isIdentificationDid(0xFD00), isFalse);
    });
  });

  test('splitRecordTargets polls live DIDs and reads identification DIDs once', () {
    final table = SignalTable.parse(File('../packages/ocean_obd/assets/signals/ocean.json').readAsStringSync());
    final state = SweepState(rangesKey: 'x', hits: [
      DidHit(module: 'BMS', did: 0x2003, sample: '0F22'),
      DidHit(module: 'BMS', did: 0xF187, sample: '46'),
      DidHit(module: 'VCU', did: 0xEFF9, sample: '36EE'), // known, polled
      DidHit(module: 'VCU', did: 0xEFF7, sample: '0000'), // live speed
      DidHit(module: 'ESP', did: 0xFD0A, nrc: 0x10), // refused: skipped
      DidHit(module: 'NOPE', did: 0x1234, sample: '00'), // unknown module
    ]);
    final t = splitRecordTargets(table, state);
    final poll = t.poll.map((e) => '$e').toSet();
    expect(poll, containsAll(['BMS:2003', 'BMS:2050', 'BCM:3409', 'VCU:EFF9', 'VCU:EFF7']));
    expect(poll.intersection({'BMS:F187', 'VCU:F190', 'ESP:FD0A', 'NOPE:1234'}), isEmpty);
    expect(t.once.map((e) => '$e').toSet(), {'BMS:F187', 'VCU:F190'});
  });

  test('bundled DID list parses and feeds recording targets', () {
    final table = SignalTable.parse(File('../packages/ocean_obd/assets/signals/ocean.json').readAsStringSync());
    final bundled = parseBundledDidList(
        jsonDecode(File('../packages/ocean_obd/assets/signals/sweep_os-2.2.3.json').readAsStringSync())
            as Map<String, dynamic>);
    expect(bundled.length, 272);
    expect(bundled.every((h) => h.positive && h.sample.isEmpty), isTrue);
    final t = splitRecordTargets(table, SweepState(rangesKey: 'x'), bundled: bundled);
    final poll = t.poll.map((e) => '$e').toSet();
    expect(poll, containsAll(['VCU:EFF7', 'BMS:2004', 'BMS:2107', 'ESP:FD00', 'BCM:3427']));
    expect(t.once.every((e) => e.did >= 0xF100 && e.did <= 0xF1FF), isTrue);
    expect(t.poll.length + t.once.length, 272);
  });

  group('Recorder', () {
    test('writes header, DID values, NRCs, GPS, voltage and footer', () async {
      final fake = FakeElm(replies: {
        'ATRV': '14.1V',
        '222050': '7E905622050038A',
        '22EFF9': '7CA037F2231',
      });
      final uds = UdsClient(ElmClient(ElmTransport(fake, minBusInterval: Duration.zero)));
      final writer = await newWriter();
      final gps = StreamController<GpsFix>();
      final rec = Recorder(
        uds: () => uds,
        writer: writer,
        schedule: PollSchedule(const [PollTarget(bms, 0x2050), PollTarget(vcu, 0xEFF9)]),
        gps: gps.stream,
      );
      final done = rec.run();
      gps.add(const GpsFix(lat: 45.5, lon: -122.6, speedKmh: 50.123, headingDeg: 90));
      await waitFor(() => rec.stats.values >= 2 && rec.stats.negatives >= 2);
      rec.stop();
      await done;
      await writer.finish(StopReport(checked: {'city', 'heating'}, socPercent: 90, notes: 'test'));

      final lines = readLines(writer.file);
      expect(lines.first['type'], 'header');
      expect(lines.first['car_os'], '2.2.3');
      expect(lines.last['type'], 'footer');
      expect(lines.last['checklist'], ['city', 'heating']);
      expect(lines.last['dash'], {'soc': 90});

      final dids = lines.where((l) => l['type'] == 'did').toList();
      expect(dids, isNotEmpty);
      expect(dids.first, containsPair('raw', '038A'));
      expect(dids.first, containsPair('mod', 'BMS'));
      expect(lines.where((l) => l['type'] == 'nrc').first['nrc'], '31');
      expect(lines.where((l) => l['type'] == 'atrv').first['v'], 14.1);
      final fix = lines.firstWhere((l) => l['type'] == 'gps');
      expect(fix['spd'], 50.12);
      expect(rec.stats.values, greaterThan(0));
      expect(rec.stats.gpsFixes, 1);
    });

    test('does not poll while the car is off', () async {
      final fake = FakeElm(replies: {'ATRV': '12.2V'});
      final uds = UdsClient(ElmClient(ElmTransport(fake)));
      final writer = await newWriter();
      final rec = Recorder(
        uds: () => uds,
        writer: writer,
        schedule: PollSchedule(const [PollTarget(bms, 0x2050)]),
        carOffRecheck: const Duration(milliseconds: 10),
      );
      final done = rec.run();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      rec.stop();
      await done;
      await writer.close();
      expect(fake.sent.where((c) => !c.startsWith('AT')), isEmpty);
      expect(fake.sent.where((c) => c == 'ATRV').length, greaterThan(1));
      expect(rec.stats.carOn, isFalse);
    });

    test('closes the gate after a run of unanswered requests', () async {
      final fake = FakeElm(replies: {'ATRV': '14.0V', '222050': 'NO DATA'});
      final uds = UdsClient(ElmClient(ElmTransport(fake, minBusInterval: Duration.zero)));
      final writer = await newWriter();
      final rec = Recorder(
        uds: () => uds,
        writer: writer,
        schedule: PollSchedule(const [PollTarget(bms, 0x2050)]),
        noResponseLimit: 3,
      );
      final done = rec.run();
      await waitFor(() => !rec.stats.carOn && rec.stats.noResponses >= 3);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      rec.stop();
      await done;
      await writer.close();
      expect(fake.sent.where((c) => c == '222050').length, 3);
      expect(readLines(writer.file).any((l) => l['what'] == 'no_response_streak'), isTrue);
    });
  });

  group('Recorder link handling', () {
    test('reads once-targets once, then polls', () async {
      final fake = FakeElm(replies: {
        'ATRV': '14.1V',
        '22F190': '7CA0562F1904142',
        '222050': '7E905622050038A',
      });
      final uds = UdsClient(ElmClient(ElmTransport(fake, minBusInterval: const Duration(milliseconds: 1))));
      final writer = await newWriter();
      final rec = Recorder(
        uds: () => uds,
        writer: writer,
        schedule: PollSchedule(const [PollTarget(bms, 0x2050)]),
        onceTargets: const [PollTarget(vcu, 0xF190)],
      );
      final done = rec.run();
      await waitFor(() => fake.sent.where((c) => c == '222050').length > 3);
      rec.stop();
      await done;
      await writer.close();
      expect(fake.sent.where((c) => c == '22F190').length, 1);
      expect(fake.sent.where((c) => c == '222050').length, greaterThan(3));
    });

    test('keeps going through a dropped link and resumes on a new session', () async {
      final fake1 = FakeElm(replies: {'ATRV': '14.1V', '222050': '7E905622050038A'});
      final fake2 = FakeElm(replies: {'ATRV': '14.1V', '222050': '7E905622050038B'});
      UdsClient mk(FakeElm f) =>
          UdsClient(ElmClient(ElmTransport(f, minBusInterval: const Duration(milliseconds: 1))));
      UdsClient? current = mk(fake1);
      final writer = await newWriter();
      final gps = StreamController<GpsFix>();
      final rec = Recorder(
        uds: () => current,
        writer: writer,
        schedule: PollSchedule(const [PollTarget(bms, 0x2050)]),
        gps: gps.stream,
        linkRecheck: const Duration(milliseconds: 5),
      );
      final done = rec.run();
      await waitFor(() => rec.stats.values > 0);

      // BLE drops: writes fail, then the controller withdraws the session.
      fake1.linkDown = true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      current = null;
      gps.add(const GpsFix(lat: 1, lon: 2));
      await waitFor(() => rec.stats.status.contains('reconnecting'));

      // Reconnected with a fresh session (gate closed until ATRV).
      current = mk(fake2);
      await waitFor(() => fake2.sent.contains('222050'));
      rec.stop();
      await done;
      await writer.close();

      expect(fake2.sent.first, 'ATRV');
      expect(fake2.sent.where((c) => c == '222050'), isNotEmpty);
      final lines = readLines(writer.file);
      final events = lines.where((l) => l['type'] == 'event').map((l) => l['what'] as String);
      expect(events, containsAll(['link_lost', 'link_restored']));
      expect(lines.where((l) => l['type'] == 'gps'), isNotEmpty);
      expect(lines.where((l) => l['raw'] == '038B'), isNotEmpty);
    });
  });

  group('SessionSummary', () {
    test('reads duration and checklist from a finished session', () async {
      var now = DateTime(2026, 9, 28, 8);
      final w = await SessionWriter.create(
        dir,
        SessionHeader(appVersion: 't', carOs: '2.2.3', start: now),
        clock: () => now,
      );
      w.voltage(14.0);
      now = now.add(const Duration(minutes: 25));
      await w.finish(StopReport(checked: {'highway'}));
      final s = await SessionSummary.read(w.file);
      expect(s.duration, const Duration(minutes: 25));
      expect(s.hasFooter, isTrue);
      expect(s.checklist, ['highway']);
      expect(s.name, 'session_20260928_080000.jsonl');
    });

    test('handles a session that never got its footer', () async {
      var now = DateTime(2026, 9, 28, 8);
      final w = await SessionWriter.create(
        dir,
        SessionHeader(appVersion: 't', carOs: '2.2.3', start: now),
        clock: () => now,
      );
      now = now.add(const Duration(minutes: 3));
      w.voltage(14.0);
      await w.close();
      final s = await SessionSummary.read(w.file);
      expect(s.hasFooter, isFalse);
      expect(s.duration, const Duration(minutes: 3));
    });
  });

  test('StopReport keeps checklist order and omits empty dash readings', () {
    final j = StopReport(checked: {'dc_charging', 'parked_ready'}, rangeKm: 300).toJson();
    expect(j['checklist'], ['parked_ready', 'dc_charging']);
    expect(j['dash'], {'range_km': 300});
  });

  test('ElmTransport.monitor collects lines and stops ATMA with a space', () async {
    final fake = FakeElm(replies: {'ATRV': '14.0V'})..monitorLines = ['7E8034100', '3A1112233'];
    final t = ElmTransport(fake);
    await ElmClient(t).readVoltage();
    final lines = await t.monitor(const Duration(milliseconds: 20));
    expect(lines, ['7E8034100', '3A1112233']);
    expect(fake.sent, ['ATRV', 'ATMA', ' ']);
    // The transport is usable afterwards.
    expect(await t.send('ATI'), 'OK');
  });
}
