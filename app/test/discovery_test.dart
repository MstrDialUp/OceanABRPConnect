import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_abrp_connect/discovery/discovery_sweep.dart';
import 'package:ocean_abrp_connect/discovery/sweep_state.dart';
import 'package:ocean_abrp_connect/elm/ecu_module.dart';
import 'package:ocean_abrp_connect/elm/elm_client.dart';
import 'package:ocean_abrp_connect/transport/command_policy.dart';
import 'package:ocean_abrp_connect/transport/elm_transport.dart';
import 'package:ocean_abrp_connect/uds/uds_client.dart';

import 'fake_elm.dart';

const bms = EcuModule('BMS', 0x7E1, 0x7E9);
const vcu = EcuModule('VCU', 0x7C2, 0x7CA);
const bcm = EcuModule('BCM', 0x7C1, 0x7C9);
const ranges = [(0x2000, 0x2003), (0xF190, 0xF191)];

/// A car where BMS answers some DIDs, VCU doesn't support 0x22 and BCM is
/// absent.
FakeElm fakeCar({String volts = '14.2V'}) {
  var header = '';
  return FakeElm(handler: (cmd) {
    if (cmd == 'ATRV') return volts;
    if (cmd.startsWith('ATSH')) {
      header = cmd.substring(4);
      return null;
    }
    if (cmd.startsWith('AT')) return null;
    if (cmd == '0100') return '7E8064100BE3FA813';
    if (cmd.startsWith('01')) return 'NO DATA';
    final did = cmd.substring(2);
    return switch (header) {
      '7E1' => switch (did) {
          '2001' => '7E905622001ABCD',
          '2002' => '7E9037F2222',
          _ => '7E9037F2231',
        },
      '7C2' => '7CA037F2211',
      _ => 'NO DATA',
    };
  });
}

DiscoverySweep sweepFor(FakeElm fake, SweepState state, {List<SweepState>? saves}) {
  final elm = ElmClient(ElmTransport(fake, minBusInterval: Duration.zero));
  return DiscoverySweep(
    uds: UdsClient(elm),
    modules: const [bms, vcu, bcm],
    state: state,
    save: (s) async => saves?.add(s),
    ranges: ranges,
    obdPids: const [0x00, 0x0D],
    monitorDuration: const Duration(milliseconds: 20),
    silentAfter: 3,
    saveEvery: 2,
  );
}

SweepState newState() => SweepState(rangesKey: DiscoverySweep.rangesKeyFor(ranges));

void main() {
  test('full sweep records hits, skips unsupported and silent modules', () async {
    final fake = fakeCar()..monitorLines = ['7E8034100', '3A10011223344', '7E8034100'];
    final state = newState();
    final sweep = sweepFor(fake, state);
    await sweep.run(isCancelled: () => false);

    expect(sweep.finished, isTrue);
    expect(state.modules['BMS']!.status, ModuleSweepStatus.done);
    expect(state.modules['VCU']!.status, ModuleSweepStatus.noService);
    expect(state.modules['BCM']!.status, ModuleSweepStatus.silent);
    expect(state.positiveHits.single.didHex, '2001');
    expect(state.positiveHits.single.sample, 'ABCD');
    expect(state.hits.where((h) => !h.positive).single.nrc, 0x22);

    // VCU stopped after its first request, BCM after silentAfter requests.
    expect(fake.sent.where((c) => c.startsWith('22')).length, 6 + 1 + 3);

    expect(state.obd['00'], 'BE3FA813');
    expect(state.obd['0D'], 'none');
    expect(state.monitor!['lines'], 3);
    expect(state.monitor!['ids'], ['3A1', '7E8']);
  });

  test('every command the sweep sends passes the allow-list', () async {
    final fake = fakeCar()..monitorLines = [];
    await sweepFor(fake, newState()).run(isCancelled: () => false);
    for (final c in fake.sent.where((c) => c.trim().isNotEmpty)) {
      expect(() => CommandPolicy.check(c), returnsNormally, reason: c);
    }
  });

  test('resumes from saved progress without repeating requests', () async {
    final fake = fakeCar()..monitorLines = [];
    final state = newState();
    var calls = 0;
    await sweepFor(fake, state).run(isCancelled: () => ++calls > 3);
    final firstRun = fake.sent.where((c) => c.startsWith('22')).toList();
    expect(firstRun, ['222000', '222001', '222002']);
    expect(state.modules['BMS']!.next, 3);

    // Round-trip through JSON, as the app does.
    final restored = SweepState.fromJson(state.toJson());
    fake.sent.clear();
    await sweepFor(fake, restored).run(isCancelled: () => false);
    expect(fake.sent.where((c) => c.startsWith('22')).first, '222003');
    expect(restored.positiveHits.length, 1);
  });

  test('pauses without touching the bus when the car is off', () async {
    final fake = fakeCar(volts: '12.4V');
    final state = newState();
    await expectLater(
      sweepFor(fake, state).run(isCancelled: () => false),
      throwsA(isA<SweepPaused>()),
    );
    expect(fake.sent, ['ATRV']);
  });
}
