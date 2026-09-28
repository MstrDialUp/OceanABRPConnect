import 'dart:typed_data';

import '../elm/ecu_module.dart';
import '../elm/elm_client.dart';
import '../elm/elm_response.dart';
import 'isotp.dart';

/// Outcome of a single read.
sealed class ReadResult {
  const ReadResult();
}

class ReadValue extends ReadResult {
  const ReadValue(this.data, this.rawPayload);

  /// Data bytes after the service/DID (or PID) echo.
  final Uint8List data;

  /// The full response payload, e.g. `62 2050 03E8`.
  final Uint8List rawPayload;
}

class ReadNegative extends ReadResult {
  const ReadNegative(this.nrc);
  final int nrc;

  String get description => negativeResponseName(nrc);
}

class ReadNoResponse extends ReadResult {
  const ReadNoResponse(this.reason);
  final String reason;
}

/// ISO 14229 negative response codes likely to be seen with 0x22.
String negativeResponseName(int nrc) => switch (nrc) {
      0x10 => 'generalReject',
      0x11 => 'serviceNotSupported',
      0x12 => 'subFunctionNotSupported',
      0x13 => 'incorrectMessageLengthOrInvalidFormat',
      0x14 => 'responseTooLong',
      0x21 => 'busyRepeatRequest',
      0x22 => 'conditionsNotCorrect',
      0x31 => 'requestOutOfRange',
      0x33 => 'securityAccessDenied',
      0x78 => 'requestCorrectlyReceivedResponsePending',
      0x7F => 'serviceNotSupportedInActiveSession',
      _ => 'NRC 0x${nrc.toRadixString(16).padLeft(2, '0').toUpperCase()}',
    };

/// UDS ReadDataByIdentifier (0x22) and OBD-II mode 01, built on [ElmClient].
class UdsClient {
  UdsClient(this.elm);

  final ElmClient elm;

  Future<ReadResult> readDid(EcuModule module, int did) async {
    await elm.select(module);
    final didHex = did.toRadixString(16).padLeft(4, '0').toUpperCase();
    final response = await elm.request('22$didHex');
    return interpretDidResponse(response, module, did);
  }

  Future<ReadResult> readObdPid(int pid) async {
    await elm.select(EcuModule.functional);
    final pidHex = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
    final response = await elm.request('01$pidHex');
    return interpretObdResponse(response, pid);
  }

  static ReadResult interpretDidResponse(ElmResponse r, EcuModule module, int did) {
    final (messages, failure) = _reassemble(r);
    if (failure != null) return failure;
    return _pick(messages.where((m) => m.canId == module.rx), 0x22, (p) {
      if (p.length < 3) return null;
      final echoed = (p[1] << 8) | p[2];
      return echoed == did ? 3 : null;
    });
  }

  static ReadResult interpretObdResponse(ElmResponse r, int pid) {
    final (messages, failure) = _reassemble(r);
    if (failure != null) return failure;
    return _pick(messages, 0x01, (p) {
      if (p.length < 2) return null;
      return p[1] == pid ? 2 : null;
    });
  }

  static (List<IsoTpMessage>, ReadNoResponse?) _reassemble(ElmResponse r) {
    if (!r.hasFrames) return (const [], ReadNoResponse(r.status.name));
    try {
      return (IsoTpReassembler.reassemble(r.frames), null);
    } on IsoTpException catch (e) {
      return (const [], ReadNoResponse(e.message));
    }
  }

  /// Picks the first positive response for [service] whose echo matches
  /// ([dataOffset] returns the data start, or null on mismatch). A final
  /// negative response is reported if there is no positive one; "response
  /// pending" (0x78) is skipped.
  static ReadResult _pick(
    Iterable<IsoTpMessage> messages,
    int service,
    int? Function(Uint8List payload) dataOffset,
  ) {
    ReadNegative? negative;
    for (final m in messages) {
      final p = m.payload;
      if (p.isEmpty) continue;
      if (p[0] == service + 0x40) {
        final off = dataOffset(p);
        if (off != null) return ReadValue(Uint8List.sublistView(p, off), p);
      } else if (p[0] == 0x7F && p.length >= 3 && p[1] == service && p[2] != 0x78) {
        negative = ReadNegative(p[2]);
      }
    }
    return negative ?? const ReadNoResponse('no matching response');
  }
}
