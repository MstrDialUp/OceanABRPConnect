import 'dart:typed_data';

import '../elm/elm_response.dart';

class IsoTpException implements Exception {
  IsoTpException(this.message);
  final String message;

  @override
  String toString() => 'IsoTpException: $message';
}

/// A complete ISO-TP message from one sender.
class IsoTpMessage {
  IsoTpMessage(this.canId, this.payload);

  final int canId;
  final Uint8List payload;

  @override
  String toString() =>
      '${canId.toRadixString(16).toUpperCase()}: ${bytesToHex(payload)}';
}

/// Reassembles ISO 15765-2 frames (classic CAN, 8-byte frames) into
/// messages. Frames from different CAN IDs are reassembled independently, in
/// arrival order. Flow-control frames are ignored (the adapter sends ours).
class IsoTpReassembler {
  static List<IsoTpMessage> reassemble(Iterable<CanFrame> frames) {
    final done = <IsoTpMessage>[];
    final inProgress = <int, _Partial>{};

    for (final f in frames) {
      if (f.data.isEmpty) continue;
      final pci = f.data[0] >> 4;
      switch (pci) {
        case 0x0: // single frame
          final len = f.data[0] & 0x0F;
          if (len == 0 || len > f.data.length - 1) {
            throw IsoTpException('bad single-frame length in $f');
          }
          done.add(IsoTpMessage(f.id, Uint8List.fromList(f.data.sublist(1, 1 + len))));
        case 0x1: // first frame
          if (f.data.length < 2) throw IsoTpException('short first frame $f');
          final len = ((f.data[0] & 0x0F) << 8) | f.data[1];
          if (len == 0) {
            throw IsoTpException('32-bit first-frame length not supported: $f');
          }
          final p = _Partial(len);
          p.add(f.data.sublist(2));
          inProgress[f.id] = p;
        case 0x2: // consecutive frame
          final p = inProgress[f.id];
          if (p == null) throw IsoTpException('consecutive frame without first frame: $f');
          final sn = f.data[0] & 0x0F;
          if (sn != p.nextSeq) {
            throw IsoTpException('sequence ${p.nextSeq} expected, got $sn in $f');
          }
          p.nextSeq = (p.nextSeq + 1) & 0x0F;
          p.add(f.data.sublist(1));
        case 0x3: // flow control
          continue;
        default:
          throw IsoTpException('unknown PCI in $f');
      }

      final p = inProgress[f.id];
      if (p != null && p.isComplete) {
        done.add(IsoTpMessage(f.id, p.bytes));
        inProgress.remove(f.id);
      }
    }

    if (inProgress.isNotEmpty) {
      final ids = inProgress.keys.map((k) => k.toRadixString(16).toUpperCase());
      throw IsoTpException('incomplete message from ${ids.join(', ')}');
    }
    return done;
  }
}

class _Partial {
  _Partial(this.length);

  final int length;
  final _data = BytesBuilder(copy: false);
  int nextSeq = 1;

  void add(List<int> chunk) => _data.add(chunk);

  bool get isComplete => _data.length >= length;

  Uint8List get bytes => Uint8List.fromList(_data.toBytes().sublist(0, length));
}
