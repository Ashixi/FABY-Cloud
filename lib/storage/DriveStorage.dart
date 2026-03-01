import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class DriveStorage {
  // MARK: - STATE & CONSTANTS
  static const String _rootPathKey = 'drive_root_path';
  static String? _cachedRootPath;

  // MARK: - PATH RESOLUTION
  static Future<String?> getRootPath() async {
    if (_cachedRootPath != null) return _cachedRootPath;

    final prefs = await SharedPreferences.getInstance();
    String? storedPath = prefs.getString(_rootPathKey);

    if (storedPath != null && await Directory(storedPath).exists()) {
      _cachedRootPath = storedPath;
      return storedPath;
    }

    final appDir = await getApplicationSupportDirectory();
    final defaultPath = path.join(appDir.path, 'Boardly_Drive');

    if (!await Directory(defaultPath).exists()) {
      await Directory(defaultPath).create(recursive: true);
    }

    _cachedRootPath = defaultPath;
    return defaultPath;
  }

  static Future<String> getDownloadsDir() async {
    final root = await getRootPath();
    final downloadsDir = Directory(path.join(root!, 'downloads'));

    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }

    return downloadsDir.path;
  }
}
