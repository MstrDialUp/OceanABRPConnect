import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_abrp_connect/elm/ecu_module.dart';
import 'package:ocean_abrp_connect/elm/elm_client.dart';
import 'package:ocean_abrp_connect/recorder/checklist.dart';
import 'package:ocean_abrp_connect/recorder/poll_schedule.dart';
import 'package:ocean_abrp_connect/recorder/recorder.dart';
import 'package:ocean_abrp_connect/recorder/session_file.dart';
import 'package:ocean_abrp_connect/transport/elm_transport.dart';
import 'package:ocean_abrp_connect/uds/uds_client.dart';

import 'fake_elm.dart';

const bms = EcuModule('BMS', 0x7E1, 0x7E9);
const vcu = EcuModule('VCU', 0x7C2, 0x7CA);
const ecc = EcuModule('ECC', 0x7F0, 0x7F8);
const esp = EcuModule('ESP', 0x7D0, 0x7D8);

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
    test('gives priority modules three turns for every other one', () {
      final s = PollSchedule(const [
        PollTarget(bms, 0x2050),
        PollTarget(vcu, 0xEFF9),
        PollTarget(ecc, 0x2001),
        PollTarget(esp, 0x2002),
      ]);
      final counts = <String, int>{};
      for (var i = 0; i < 400; i++) {
        final t = s.next();
        counts['$t'] = (counts['$t'] ?? 0) + 1;
      }
      expect(counts['BMS:2050'], 150);
      expect(counts['VCU:EFF9'], 150);
      expect(counts['ECC:2001'], 50);
      expect(counts['ESP:2002'], 50);
    });

    test('works with only one kind of target', () {
      final s = PollSchedule(const [PollTarget(ecc, 1), PollTarget(ecc, 2)]);
      expect([s.next(), s.next(), s.next()].map((t) => t.did), [1, 2, 1]);
    });

    test('deduplicates targets', () {
      expect(PollSchedule(const [PollTarget(bms, 1), PollTarget(bms, 1)]).length, 1);
    });
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
        uds: uds,
        writer: writer,
        schedule: PollSchedule(const [PollTarget(bms, 0x2050), PollTarget(vcu, 0xEFF9)]),
        gps: gps.stream,
      );
      final done = rec.run();
      gps.add(const GpsFix(lat: 45.5, lon: -122.6, speedKmh: 50.123, headingDeg: 90));
      await Future<void>.delayed(const Duration(milliseconds: 50));
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
        uds: uds,
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
        uds: uds,
        writer: writer,
        schedule: PollSchedule(const [PollTarget(bms, 0x2050)]),
        noResponseLimit: 3,
      );
      final done = rec.run();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      rec.stop();
      await done;
      await writer.close();
      expect(fake.sent.where((c) => c == '222050').length, 3);
      expect(readLines(writer.file).any((l) => l['what'] == 'no_response_streak'), isTrue);
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
