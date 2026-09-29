import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'credentials.dart';
import 'telemetry.dart';

enum AbrpOutcome {
  ok,

  /// No connection or a timeout: worth buffering and retrying.
  network,

  /// HTTP error: usually a wrong API key (PLAN.md §2).
  http,

  /// HTTP 200 but `status` isn't "ok": ABRP rejected the data or the token.
  rejected,
}

class AbrpResult {
  const AbrpResult(this.outcome, this.message, {this.result});

  final AbrpOutcome outcome;

  /// Human-readable detail. Never contains the API key or the token.
  final String message;

  /// The `result` field of the response, if any.
  final Object? result;

  bool get ok => outcome == AbrpOutcome.ok;

  @override
  String toString() => '${outcome.name}: $message';
}

/// Iternio Telemetry API v1 (docs/abrp). The API key goes in the
/// `Authorization` header and the token in the POST body, so neither appears
/// in a URL (PLAN.md §2.1).
class AbrpClient {
  AbrpClient(
    this.credentials, {
    http.Client? httpClient,
    this.baseUrl = 'https://api.iternio.com/1/',
    this.timeout = const Duration(seconds: 15),
  }) : _http = httpClient ?? http.Client();

  final AbrpCredentials credentials;
  final http.Client _http;
  final String baseUrl;
  final Duration timeout;

  Map<String, String> get _auth => {'Authorization': 'APIKEY ${credentials.apiKey.trim()}'};

  Future<AbrpResult> send(TelemetryPoint point) => _call(
        'tlm/send',
        () => _http.post(
          Uri.parse('${baseUrl}tlm/send'),
          headers: _auth,
          body: {'token': credentials.token.trim(), 'tlm': jsonEncode(point.toJson())},
        ),
      );

  /// Several points in one call, e.g. those buffered while offline.
  Future<AbrpResult> bulk(List<TelemetryPoint> points) => _call(
        'tlm/bulk',
        () => _http.post(
          Uri.parse('${baseUrl}tlm/bulk'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'data': [
              {
                'token': credentials.token.trim(),
                'tlm_list': [for (final p in points) p.toJson()],
              },
            ],
          }),
        ),
      );

  /// The latest telemetry ABRP holds for this token (needs a key that is
  /// allowed to read).
  Future<AbrpResult> getTelemetry() => _call(
        'tlm/get_telemetry',
        () => _http.post(
          Uri.parse('${baseUrl}tlm/get_telemetry'),
          headers: _auth,
          body: {'token': credentials.token.trim()},
        ),
      );

  Future<AbrpResult> _call(String what, Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      return AbrpResult(AbrpOutcome.network, '$what: timed out');
    } on http.ClientException catch (e) {
      return AbrpResult(AbrpOutcome.network, '$what: ${_scrub(e.message)}');
    } catch (e) {
      // SocketException and friends (dart:io isn't imported so this stays
      // testable on any platform).
      return AbrpResult(AbrpOutcome.network, '$what: ${_scrub('$e')}');
    }

    if (response.statusCode != 200) {
      final hint = response.statusCode == 401 || response.statusCode == 403
          ? ' (check the API key)'
          : '';
      return AbrpResult(AbrpOutcome.http, '$what: HTTP ${response.statusCode}$hint');
    }
    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return AbrpResult(AbrpOutcome.rejected, '$what: response is not JSON');
    }
    final status = body['status'];
    if (status == 'ok') {
      return AbrpResult(AbrpOutcome.ok, 'ok', result: body['result']);
    }
    final errors = body['errors'] ?? body['result'] ?? '';
    return AbrpResult(AbrpOutcome.rejected, _scrub('$what: $status ${errors is String ? errors : jsonEncode(errors)}'.trim()),
        result: body['result']);
  }

  /// Removes the credentials from any text that might echo them.
  String _scrub(String text) {
    var out = text;
    for (final secret in [credentials.apiKey.trim(), credentials.token.trim()]) {
      if (secret.length >= 4) out = out.replaceAll(secret, AbrpCredentials.mask(secret));
    }
    return out;
  }

  void close() => _http.close();
}
