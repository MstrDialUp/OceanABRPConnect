import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The user's own ABRP API key and vehicle token (PLAN.md §0, ABRP
/// credentials). Entered in the app, stored only in the app's secure
/// storage, never logged or put in a URL.
class AbrpCredentials {
  const AbrpCredentials({required this.apiKey, required this.token});

  final String apiKey;
  final String token;

  bool get isComplete => apiKey.trim().isNotEmpty && token.trim().isNotEmpty;

  /// Last four characters only, for showing that a value is set.
  static String mask(String secret) {
    final s = secret.trim();
    if (s.isEmpty) return 'not set';
    return s.length <= 4 ? '••••' : '••••${s.substring(s.length - 4)}';
  }

  @override
  String toString() => 'AbrpCredentials(apiKey: ${mask(apiKey)}, token: ${mask(token)})';
}

abstract class CredentialStore {
  Future<AbrpCredentials?> load();
  Future<void> save(AbrpCredentials credentials);
  Future<void> clear();
}

/// Android Keystore-backed storage via flutter_secure_storage.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _keyApiKey = 'abrp_api_key';
  static const _keyToken = 'abrp_token';

  @override
  Future<AbrpCredentials?> load() async {
    final apiKey = await _storage.read(key: _keyApiKey);
    final token = await _storage.read(key: _keyToken);
    if (apiKey == null && token == null) return null;
    return AbrpCredentials(apiKey: apiKey ?? '', token: token ?? '');
  }

  @override
  Future<void> save(AbrpCredentials credentials) async {
    await _storage.write(key: _keyApiKey, value: credentials.apiKey.trim());
    await _storage.write(key: _keyToken, value: credentials.token.trim());
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _keyApiKey);
    await _storage.delete(key: _keyToken);
  }
}

/// For tests.
class MemoryCredentialStore implements CredentialStore {
  AbrpCredentials? value;

  @override
  Future<AbrpCredentials?> load() async => value;

  @override
  Future<void> save(AbrpCredentials credentials) async => value = credentials;

  @override
  Future<void> clear() async => value = null;
}
