import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_obd/transport/command_policy.dart';

void main() {
  group('CommandPolicy allows', () {
    for (final cmd in [
      'ATZ', 'ATE0', 'ATS0', 'ATH1', 'ATL0', 'ATSP6', 'ATRV', 'ATI', 'AT@1', //
      'ATSH7E1', 'ATFCSH7E1', 'ATCRA7E9', 'ATFCSD300000', 'ATFCSM1', 'ATAR',
      'ATST32', 'atsh 7c2', 'ATDPN',
    ]) {
      test('$cmd as adapter-local', () {
        expect(CommandPolicy.check(cmd).$2, CommandKind.adapterLocal);
      });
    }

    for (final cmd in ['222050', '22F190', '22 34 09', '222050F190', '0100', '010D', '015B', 'ATMA']) {
      test('$cmd as bus traffic', () {
        expect(CommandPolicy.check(cmd).$2, CommandKind.bus);
      });
    }

    test('normalises case and spaces', () {
      expect(CommandPolicy.check('22 f1 90').$1, '22F190');
    });
  });

  group('CommandPolicy rejects', () {
    final forbidden = {
      '14FFFFFF': 'ClearDiagnosticInformation',
      '04': 'OBD clear DTCs',
      '2EF19001': 'WriteDataByIdentifier',
      '3101FF00': 'RoutineControl',
      '1101': 'ECUReset',
      '1003': 'DiagnosticSessionControl',
      '2701': 'SecurityAccess',
      '3E00': 'TesterPresent',
      '85 02': 'ControlDTCSetting',
      '28 03 01': 'CommunicationControl',
      '2F': 'InputOutputControl',
      '3D': 'WriteMemoryByAddress',
      '0902': 'mode 09 (not allowed)',
      '22': '0x22 with no DID',
      '22205': 'odd-length hex',
      '22F1': '0x22 with 1-byte DID',
      'ATPP0CSV01': 'programmable parameter write',
      'ATWM8110F13E': 'wakeup message',
      'ATBRD23': 'baud rate change',
      'STPX': 'STN extension',
      'ATSH7E1\r14FF': 'embedded carriage return',
      'ATZ\n': 'embedded newline',
      '': 'empty',
      'HELLO': 'not hex',
      '01': 'mode 01 with no PID',
    };
    forbidden.forEach((cmd, why) {
      test('"${cmd.replaceAll('\r', r'\r').replaceAll('\n', r'\n')}" ($why)', () {
        expect(() => CommandPolicy.check(cmd), throwsA(isA<ForbiddenCommandException>()));
      });
    });
  });
}
