import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:boardly_cloud/storage/auth_storage.dart';

class AuthHttpClient {
  // MARK: - DEPENDENCIES
  final http.Client _inner = http.Client();

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

    http.Response response;
    try {
      response = await _performRequest(method, url, requestHeaders, body);

      if (response.statusCode == 401) {
        final refreshed = await _refreshToken();
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
    switch (method?.toUpperCase()) {
      case 'POST':
        return await _inner.post(url, headers: headers, body: body);
      case 'PUT':
        return await _inner.put(url, headers: headers, body: body);
      case 'PATCH':
        return await _inner.patch(url, headers: headers, body: body);
      case 'DELETE':
        return await _inner.delete(url, headers: headers);
      default:
        return await _inner.get(url, headers: headers);
    }
  }

  // MARK: - TOKEN REFRESH LOGIC
  Future<bool> _refreshToken() async {
    try {
      final refreshToken = await AuthStorage.getRefreshToken();
      if (refreshToken == null) return false;

      final response = await _inner.post(
        Uri.parse('https://api.boardly.studio/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'refresh_token': refreshToken,
          'device_id': 'boardly_drive_client',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await AuthStorage.saveTokens(
          data['access_token'],
          data['refresh_token'],
        );
        return true;
      }

      if (response.statusCode == 401) {
        await AuthStorage.clearAll();
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // MARK: - CLEANUP
  void close() {
    _inner.close();
  }
}
