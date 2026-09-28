import 'dart:convert';
import 'dart:io';

/// A JSON object persisted to one file, written atomically (temp + rename).
class JsonFileStore {
  JsonFileStore(this.file);

  final File file;

  Future<Map<String, dynamic>?> load() async {
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }

  Future<void> save(Map<String, dynamic> json) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(json), flush: true);
    await tmp.rename(file.path);
  }

  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}
