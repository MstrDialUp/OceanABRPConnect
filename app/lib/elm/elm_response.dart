import 'dart:typed_data';

/// One CAN frame as printed by the ELM327 with headers on (`ATH1`) and
/// spaces off (`ATS0`), e.g. `7E9101462F190574631` → id 0x7E9, 8 data bytes.
class CanFrame {
  CanFrame(this.id, this.data);

  final int id;
  final Uint8List data;

  @override
  String toString() => '${id.toRadixString(16).toUpperCase()} ${bytesToHex(data)}';
}

/// ELM327 status words that can appear instead of (or as well as) data.
enum ElmStatus {
  ok,
  noData,
  canError,
  bufferFull,
  busBusy,
  busError,
  dataError,
  rxError,
  stopped,
  unableToConnect,
  unknownCommand,
}

class ElmResponse {
  ElmResponse(this.frames, this.status, this.raw);

  final List<CanFrame> frames;
  final ElmStatus status;
  final String raw;

  bool get hasFrames => frames.isNotEmpty;

  static const _statusWords = <String, ElmStatus>{
    'NO DATA': ElmStatus.noData,
    'NODATA': ElmStatus.noData,
    'CAN ERROR': ElmStatus.canError,
    'CANERROR': ElmStatus.canError,
    'BUFFER FULL': ElmStatus.bufferFull,
    'BUFFERFULL': ElmStatus.bufferFull,
    'BUS BUSY': ElmStatus.busBusy,
    'BUSBUSY': ElmStatus.busBusy,
    'BUS ERROR': ElmStatus.busError,
    'BUSERROR': ElmStatus.busError,
    'DATA ERROR': ElmStatus.dataError,
    'DATAERROR': ElmStatus.dataError,
    'STOPPED': ElmStatus.stopped,
    'UNABLE TO CONNECT': ElmStatus.unableToConnect,
    'UNABLETOCONNECT': ElmStatus.unableToConnect,
    '?': ElmStatus.unknownCommand,
  };

  /// Parses the reply to a bus request. [idHexLength] is 3 for 11-bit CAN
  /// IDs (ATSP6) and 8 for 29-bit IDs.
  static ElmResponse parse(String raw, {int idHexLength = 3}) {
    final frames = <CanFrame>[];
    var status = ElmStatus.ok;
    for (final rawLine in raw.split('\r')) {
      final line = rawLine.trim().toUpperCase();
      if (line.isEmpty || line.startsWith('SEARCHING')) continue;
      if (line.startsWith('<RX ERROR')) {
        status = ElmStatus.rxError;
        continue;
      }
      final word = _statusWords[line];
      if (word != null) {
        status = word;
        continue;
      }
      final compact = line.replaceAll(' ', '');
      if (compact.length > idHexLength &&
          RegExp(r'^[0-9A-F]+$').hasMatch(compact) &&
          (compact.length - idHexLength).isEven) {
        final id = int.parse(compact.substring(0, idHexLength), radix: 16);
        frames.add(CanFrame(id, hexToBytes(compact.substring(idHexLength))));
      }
      // Anything else (e.g. a stray echo) is ignored.
    }
    if (frames.isEmpty && status == ElmStatus.ok) status = ElmStatus.noData;
    return ElmResponse(frames, status, raw);
  }
}

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
