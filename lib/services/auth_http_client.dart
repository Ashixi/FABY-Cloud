import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:faby/storage/auth_storage.dart';

class AuthHttpClient {
  final http.Client _inner = http.Client();

  static bool _isRefreshing = false;
  static Completer<bool>? _refreshCompleter;

  // MARK: - CORE REQUEST LOGIC
  Future<http.Response> request(
    Uri url, {
    String? method,
    Map<String, String>? headers,
    dynamic body,
  }) async {
    String? accessToken = await AuthStorage.getAccessToken();
    final requestHeaders = {...?headers};

    if (accessToken != null) {
      requestHeaders['Authorization'] = 'Bearer $accessToken';
    }

    try {
      var response = await _performRequest(method, url, requestHeaders, body);

      if (response.statusCode == 401) {
        bool refreshed;

        if (_isRefreshing) {
          print('[AUTH] Refresh already in progress, waiting for result...');
          refreshed = await _refreshCompleter!.future;
        } else {
          _isRefreshing = true;
          _refreshCompleter = Completer<bool>();

          print('[AUTH] Token expired. Starting single refresh process...');
          refreshed = await _refreshToken();

          _refreshCompleter!.complete(refreshed);
          _isRefreshing = false;
        }

        if (refreshed) {
          accessToken = await AuthStorage.getAccessToken();
          if (accessToken != null) {
            requestHeaders['Authorization'] = 'Bearer $accessToken';
            response = await _performRequest(method, url, requestHeaders, body);
          }
        }
      }
      return response;
    } catch (e) {
      rethrow;
    }
  }

  Future<http.Response> _performRequest(
    String? method,
    Uri url,
    Map<String, String> headers,
    dynamic body,
  ) async {
    const timeout = Duration(seconds: 15);

    switch (method?.toUpperCase()) {
      case 'POST':
        return await _inner
            .post(url, headers: headers, body: body)
            .timeout(timeout);
      case 'PUT':
        return await _inner
            .put(url, headers: headers, body: body)
            .timeout(timeout);
      case 'PATCH':
        return await _inner
            .patch(url, headers: headers, body: body)
            .timeout(timeout);
      case 'DELETE':
        return await _inner.delete(url, headers: headers).timeout(timeout);
      default:
        return await _inner.get(url, headers: headers).timeout(timeout);
    }
  }

  // MARK: - TOKEN REFRESH LOGIC
  Future<bool> _refreshToken() async {
    try {
      final refreshToken = await AuthStorage.getRefreshToken();
      if (refreshToken == null) {
        print('[AUTH] No refresh token available.');
        return false;
      }

      final response = await _inner
          .post(
            Uri.parse('https://api.boardly.studio/auth/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'refresh_token': refreshToken,
              'device_id': 'boardly_drive_client',
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await AuthStorage.saveTokens(
          data['access_token'],
          data['refresh_token'],
        );
        print('[AUTH] Tokens refreshed successfully.');
        return true;
      }

      if (response.statusCode == 401) {
        print('[AUTH] Refresh token is invalid. Logging out.');
        await AuthStorage.clearAll();
      }
      return false;
    } catch (e) {
      print('[AUTH] Exception during token refresh: $e');
      return false;
    }
  }

  // MARK: - CLEANUP
  void close() {
    _inner.close();
  }
}
