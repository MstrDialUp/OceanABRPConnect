import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_obd/elm/ecu_module.dart';
import 'package:ocean_obd/elm/elm_client.dart';
import 'package:ocean_obd/elm/elm_response.dart';
import 'package:ocean_obd/transport/elm_transport.dart';
import 'package:ocean_obd/uds/isotp.dart';
import 'package:ocean_obd/uds/uds_client.dart';

import 'package:ocean_obd/testing/fake_elm.dart';

const bms = EcuModule('BMS', 0x7E1, 0x7E9);
const vcu = EcuModule('VCU', 0x7C2, 0x7CA);

// VIN "1FTEST0CEAN0000042" is 17 chars; a 0x62 F190 reply is 20 bytes:
// FF 14 62 F1 90 + 3 VIN bytes, then two CFs of 7.
const vinReply = '7CA101462F190314654\r'
    '7CA2145535430434541\r'
    '7CA224E303030303432';

void main() {
  group('ElmResponse.parse', () {
    test('parses 11-bit frames with headers and no spaces', () {
      final r = ElmResponse.parse('7E9056220500384');
      expect(r.status, ElmStatus.ok);
      expect(r.frames.single.id, 0x7E9);
      expect(bytesToHex(r.frames.single.data), '056220500384');
    });

    test('tolerates spaces and SEARCHING...', () {
      final r = ElmResponse.parse('SEARCHING...\r7E8 06 41 00 BE 3F A8 13');
      expect(r.frames.single.id, 0x7E8);
      expect(r.frames.single.data.length, 7);
    });

    for (final (text, status) in [
      ('NO DATA', ElmStatus.noData),
      ('CAN ERROR', ElmStatus.canError),
      ('?', ElmStatus.unknownCommand),
      ('BUFFER FULL', ElmStatus.bufferFull),
      ('', ElmStatus.noData),
    ]) {
      test('status "$text"', () {
        final r = ElmResponse.parse(text);
        expect(r.hasFrames, isFalse);
        expect(r.status, status);
      });
    }
  });

  group('IsoTpReassembler', () {
    test('single frame, ignoring padding', () {
      final m = IsoTpReassembler.reassemble(
          ElmResponse.parse('7E9056220500384AA').frames);
      expect(bytesToHex(m.single.payload), '6220500384');
    });

    test('multi-frame message', () {
      final m = IsoTpReassembler.reassemble(ElmResponse.parse(vinReply).frames);
      expect(m.single.canId, 0x7CA);
      expect(m.single.payload.length, 20);
      expect(String.fromCharCodes(m.single.payload.sublist(3)), '1FTEST0CEAN000042');
    });

    test('ignores flow control frames', () {
      final m = IsoTpReassembler.reassemble(
          ElmResponse.parse('7C2300000\r7E9056220500384').frames);
      expect(m.single.canId, 0x7E9);
    });

    test('separates interleaved senders', () {
      final m = IsoTpReassembler.reassemble(ElmResponse.parse(
        '7E8064100BE3FA813\r7E906410080000001',
      ).frames);
      expect(m.map((e) => e.canId), [0x7E8, 0x7E9]);
    });

    test('rejects out-of-sequence consecutive frames', () {
      expect(
        () => IsoTpReassembler.reassemble(ElmResponse.parse(
          '7CA101462F190314654\r7CA224E303030303432',
        ).frames),
        throwsA(isA<IsoTpException>()),
      );
    });

    test('rejects an incomplete message', () {
      expect(
        () => IsoTpReassembler.reassemble(
            ElmResponse.parse('7CA101462F190314654').frames),
        throwsA(isA<IsoTpException>()),
      );
    });

    test('sequence numbers wrap from F to 0', () {
      // 8 + 7*16 = 120 bytes: FF(6 data) + 16 CFs (SN 1..F, 0), last one partial.
      const len = 6 + 7 * 16;
      final lines = <String>['7E910${len.toRadixString(16).padLeft(2, '0').toUpperCase()}620001020304'];
      for (var i = 1; i <= 16; i++) {
        final sn = (i & 0x0F).toRadixString(16).toUpperCase();
        lines.add('7E92$sn${'11' * 7}');
      }
      final m = IsoTpReassembler.reassemble(ElmResponse.parse(lines.join('\r')).frames);
      expect(m.single.payload.length, len);
    });
  });

  group('UdsClient', () {
    test('positive response returns data after the DID', () {
      final r = UdsClient.interpretDidResponse(
          ElmResponse.parse('7E9056220500384'), bms, 0x2050);
      expect(r, isA<ReadValue>());
      expect(bytesToHex((r as ReadValue).data), '0384');
    });

    test('negative response', () {
      final r = UdsClient.interpretDidResponse(
          ElmResponse.parse('7E9037F2231'), bms, 0x2050);
      expect((r as ReadNegative).nrc, 0x31);
      expect(r.description, 'requestOutOfRange');
    });

    test('response pending then positive', () {
      final r = UdsClient.interpretDidResponse(
          ElmResponse.parse('7E9037F2278\r7E9056220500384'), bms, 0x2050);
      expect(r, isA<ReadValue>());
    });

    test('ignores replies from other modules and mismatched DIDs', () {
      expect(
        UdsClient.interpretDidResponse(ElmResponse.parse('7CA056220500384'), bms, 0x2050),
        isA<ReadNoResponse>(),
      );
      expect(
        UdsClient.interpretDidResponse(ElmResponse.parse('7E9056220510384'), bms, 0x2050),
        isA<ReadNoResponse>(),
      );
    });

    test('NO DATA is no response', () {
      final r = UdsClient.interpretDidResponse(ElmResponse.parse('NO DATA'), bms, 0x2050);
      expect((r as ReadNoResponse).reason, 'noData');
    });

    test('OBD mode 01 response', () {
      final r = UdsClient.interpretObdResponse(ElmResponse.parse('7E803410D32'), 0x0D);
      expect((r as ReadValue).data, [0x32]);
    });

    test('readDid addresses the module once and reads a multi-frame VIN', () async {
      final fake = FakeElm(replies: {'ATRV': '14.2V', '22F190': vinReply, '222050': 'NO DATA'});
      final elm = ElmClient(ElmTransport(fake, minBusInterval: Duration.zero));
      final uds = UdsClient(elm);
      await elm.readVoltage();

      final r = await uds.readDid(vcu, 0xF190);
      await uds.readDid(vcu, 0xF190);
      expect(String.fromCharCodes((r as ReadValue).data), '1FTEST0CEAN000042');
      expect(fake.sent, [
        'ATRV', 'ATSH7C2', 'ATFCSH7C2', 'ATCRA7CA', 'ATFCSM1', '22F190', '22F190', //
      ]);

      fake.sent.clear();
      await uds.readObdPid(0x0D);
      expect(fake.sent, ['ATSH7DF', 'ATAR', 'ATFCSM0', '010D']);
    });
  });
}
