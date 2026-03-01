import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:boardly_cloud/models/user_data.dart';

class AuthStorage {
  // MARK: - KEYS & CONFIG
  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';
  static const String _userDataKey = 'user_data';

  static const _secureStorage = FlutterSecureStorage();

  // MARK: - TOKEN MANAGEMENT (SECURE)
  static Future<void> saveTokens(
    String accessToken,
    String refreshToken,
  ) async {
    await _secureStorage.write(key: _accessTokenKey, value: accessToken);
    await _secureStorage.write(key: _refreshTokenKey, value: refreshToken);
  }

  static Future<String?> getAccessToken() async {
    return await _secureStorage.read(key: _accessTokenKey);
  }

  static Future<String?> getRefreshToken() async {
    return await _secureStorage.read(key: _refreshTokenKey);
  }

  // MARK: - USER DATA MANAGEMENT (PREFS)
  static Future<void> saveUserData(UserData userData) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userDataKey, jsonEncode(userData.toJson()));
  }

  static Future<UserData?> getUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final userDataJson = prefs.getString(_userDataKey);
    if (userDataJson != null) {
      try {
        final data = jsonDecode(userDataJson);
        return UserData.fromJson(data);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  // MARK: - CLEAR DATA
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userDataKey);
    await _secureStorage.delete(key: _accessTokenKey);
    await _secureStorage.delete(key: _refreshTokenKey);
  }
}
