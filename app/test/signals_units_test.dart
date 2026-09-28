import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_abrp_connect/elm/elm_response.dart';
import 'package:ocean_abrp_connect/uds/uds_client.dart';
import 'package:ocean_abrp_connect/signals/signal_table.dart';
import 'package:ocean_abrp_connect/util/units.dart';

void main() {
  late SignalTable table;

  setUpAll(() {
    table = SignalTable.parse(File('assets/signals/ocean.json').readAsStringSync());
  });

  group('ocean.json', () {
    test('loads modules and the known signals', () {
      expect(table.modules['BMS']!.tx, 0x7E1);
      expect(table.modules['BMS']!.rx, 0x7E9);
      expect(table.signals.map((s) => s.id), containsAll(['vin', 'odometer', 'soc', 'aux_voltage']));
    });

    test('every module replies on tx + 8', () {
      for (final m in table.modules.values) {
        expect(m.rx, m.tx + 8, reason: m.name);
      }
    });

    test('decodes SOC: uint16 / 10', () {
      expect(table.byId('soc')!.decode([0x03, 0x84]), closeTo(90.0, 1e-9));
    });

    test('decodes odometer: uint32 / 100 km', () {
      expect(table.byId('odometer')!.decode([0x00, 0x2D, 0xC6, 0xC0]), closeTo(30000.0, 1e-9));
    });

    test('decodes 12 V: uint16 / 1000', () {
      expect(table.byId('aux_voltage')!.decode([0x31, 0x9C]), closeTo(12.7, 1e-9));
    });

    test('decodes VIN as ASCII', () {
      expect(table.byId('vin')!.decode('VCF1ZBU27PG000042'.codeUnits), 'VCF1ZBU27PG000042');
    });

    test('short data throws', () {
      expect(() => table.byId('odometer')!.decode([0x01, 0x02]),
          throwsA(isA<SignalDecodeException>()));
    });
  });

  // Replies captured on the car (OS 2.2.3, 2026-09-28) and checked against the
  // dash. The VIN reply is left out on purpose.
  group('captured on the car', () {
    for (final (id, reply, expected) in [
      ('odometer', '7C907623409003B2950', 38772.0),
      ('odometer', '7C907623409003B2964', 38772.2),
      ('soc', '7E9056220500280', 64.0),
      ('soc', '7E905622050027F', 63.9),
      ('aux_voltage', '7CA0562EFF936FC', 14.076),
      ('aux_voltage', '7CA0562EFF93728', 14.12),
    ]) {
      test('$id $reply', () {
        final s = table.byId(id)!;
        final r = UdsClient.interpretDidResponse(ElmResponse.parse(reply), s.module, s.did);
        expect(s.decode((r as ReadValue).data), closeTo(expected, 1e-9));
      });
    }
  });

  test('signed decoding', () {
    final def = SignalDef(
      id: 'current',
      name: 'Current',
      module: table.modules['BMS']!,
      did: 0x2000,
      type: SignalType.int,
      length: 2,
      scale: 0.1,
    );
    expect(def.decode([0xFF, 0x9C]), closeTo(-10.0, 1e-9));
    expect(def.decode([0x00, 0x64]), closeTo(10.0, 1e-9));
  });

  group('units', () {
    test('metric passes through', () {
      final d = toDisplay(100, 'km/h', UnitSystem.metric);
      expect((d.value, d.unit), (100.0, 'km/h'));
    });

    test('imperial conversions', () {
      expect(toDisplay(100, 'km', UnitSystem.imperial).value, closeTo(62.137, 1e-3));
      expect(toDisplay(100, 'km/h', UnitSystem.imperial).unit, 'mph');
      expect(toDisplay(20, '°C', UnitSystem.imperial).value, closeTo(68, 1e-9));
      expect(toDisplay(250, 'kPa', UnitSystem.imperial).value, closeTo(36.26, 1e-2));
      expect(toDisplay(200, 'Wh/km', UnitSystem.imperial).value, closeTo(3.107, 1e-3));
      expect(toDisplay(80, '%', UnitSystem.imperial).unit, '%');
    });

    test('fromDisplay inverts toDisplay', () {
      for (final unit in ['km', 'km/h', '°C', 'kPa', 'Wh/km', '%']) {
        final shown = toDisplay(123.4, unit, UnitSystem.imperial).value;
        expect(fromDisplay(shown, unit, UnitSystem.imperial), closeTo(123.4, 1e-9), reason: unit);
      }
      expect(displayUnit('km', UnitSystem.imperial), 'mi');
      expect(displayUnit('km', UnitSystem.metric), 'km');
    });

    test('format', () {
      expect(const DisplayValue(12.345, 'V').format(decimals: 2), '12.35 V');
    });
  });
}
