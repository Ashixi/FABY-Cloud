import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:collection';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

import 'package:faby/models/vfs_node.dart';
import 'package:faby/services/cloudflare_storage_service.dart';
import 'package:faby/services/encryption_service.dart';

class VfsManager {
  // MARK: - SINGLETON & CONFIG
  static final VfsManager _instance = VfsManager._internal();
  factory VfsManager() => _instance;
  VfsManager._internal();

  final _storage = CloudflareStorageService();
  final _encryption = EncryptionService();
  final _secureStorage = const FlutterSecureStorage();
  final _uuid = const Uuid();

  // MARK: - STATE & CACHE
  Database? _db;
  List<VfsNode> _memoryCache = [];

  Timer? _syncTimer;
  bool _isUploadingSnapshot = false;

  // MARK: - DATABASE INITIALIZATION & MIGRATIONS
  Future<void> initDB() async {
    if (_db != null) return;

    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

      String path = join(await getDatabasesPath(), 'vfs_cache.db');

      _db = await openDatabase(
        path,
        version: 6,
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE nodes(
            id TEXT PRIMARY KEY,
            parentId TEXT,
            name TEXT,
            isFolder INTEGER,
            isFavorite INTEGER DEFAULT 0,
            size INTEGER,
            etag TEXT,
            encryptedFileKey TEXT,
            shareId TEXT,
            shareKey TEXT, 
            encryptedShareKey TEXT
          )
        ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE nodes ADD COLUMN encryptedFileKey TEXT',
            );
          }
          if (oldVersion < 3) {
            await db.execute('ALTER TABLE nodes ADD COLUMN shareId TEXT');
            await db.execute('ALTER TABLE nodes ADD COLUMN shareKey TEXT');
          }
          if (oldVersion < 4) {
            await db.execute(
              'ALTER TABLE nodes ADD COLUMN encryptedShareKey TEXT',
            );
          }
          if (oldVersion < 5) {
            await db.execute(
              'ALTER TABLE nodes ADD COLUMN isFavorite INTEGER DEFAULT 0',
            );
          }
          if (oldVersion < 6) {
            await db.execute('ALTER TABLE nodes ADD COLUMN size INTEGER');
          }
        },
      );

      await _loadToMemory();
      print('[VFS DB] Database initialized successfully.');
    } catch (e) {
      print('[VFS DB ERROR] Failed to initialize database: $e');
      rethrow;
    }
  }

  Future<void> _loadToMemory() async {
    final List<Map<String, dynamic>> maps = await _db!.query('nodes');
    _memoryCache =
        maps
            .map(
              (map) => VfsNode(
                id: map['id'],
                parentId: map['parentId'],
                name: map['name'],
                isFolder: map['isFolder'] == 1,
                isFavorite: map['isFavorite'] == 1,
                size: map['size'],
                encryptedFileKey: map['encryptedFileKey'],
                shareId: map['shareId'],
                encryptedShareKey: map['encryptedShareKey'] ?? map['shareKey'],
              ),
            )
            .toList();
  }

  // MARK: - DATA GETTERS
  List<VfsNode> getChildren(String parentId) =>
      _memoryCache.where((n) => n.parentId == parentId).toList();
  List<VfsNode> get nodes => _memoryCache;
  List<VfsNode> get favoriteNodes =>
      _memoryCache.where((n) => n.isFavorite).toList();

  // MARK: - VFS V2 CLOUD SYNC LOGIC
  Future<void> sync() async {
    await initDB();

    if ((_syncTimer?.isActive ?? false) || _isUploadingSnapshot) {
      print(
        '[VFS SYNC] Скачування скасовано: є локальні зміни, які чекають відправки.',
      );
      return;
    }

    try {
      final cloudNodes = await _storage.getCloudNodesMeta();

      if (cloudNodes.isNotEmpty) {
        print('[VFS] Detected V1 nodes. Starting migration to V2...');
        await _migrateV1toV2(cloudNodes);
        return;
      }

      await _downloadVfsSnapshot();
    } catch (e) {
      print('[VFS SYNC ERROR] $e');
    }
  }

  // MARK: - MIGRATION LOGIC (V1 -> V2)
  Future<void> _migrateV1toV2(List<Map<String, dynamic>> cloudNodes) async {
    try {
      final localNodes = await _db!.query('nodes');
      final localEtags = {
        for (var n in localNodes) n['id'] as String: n['etag'] as String?,
      };

      final cloudIds = <String>{};
      final List<Future<void>> downloadTasks = [];

      for (var cloudNode in cloudNodes) {
        final String id = cloudNode['node_id'];
        final String etag = cloudNode['etag'];
        cloudIds.add(id);

        if (!localEtags.containsKey(id) || localEtags[id] != etag) {
          downloadTasks.add(
            _storage.downloadNodeJson(id).then((nodeData) async {
              if (nodeData != null) {
                await _db!.insert('nodes', {
                  'id': id,
                  'parentId': nodeData['parentId'],
                  'name': nodeData['name'],
                  'isFolder': nodeData['isFolder'] ? 1 : 0,
                  'isFavorite': nodeData['isFavorite'] == true ? 1 : 0,
                  'etag': etag,
                  'size': nodeData['size'],
                  'encryptedFileKey': nodeData['encryptedFileKey'],
                  'shareId': nodeData['shareId'],
                  'shareKey': nodeData['shareKey'],
                  'encryptedShareKey': nodeData['encryptedShareKey'],
                }, conflictAlgorithm: ConflictAlgorithm.replace);
              }
            }),
          );
        }
      }

      if (downloadTasks.isNotEmpty) await Future.wait(downloadTasks);

      final idsToDelete =
          localEtags.keys.where((id) {
            final isPending = localEtags[id] == 'pending_sync';
            return !cloudIds.contains(id) && !isPending;
          }).toList();

      if (idsToDelete.isNotEmpty) {
        await _db!.transaction((txn) async {
          for (var id in idsToDelete) {
            await txn.delete('nodes', where: 'id = ?', whereArgs: [id]);
          }
        });
      }

      await _loadToMemory();

      final success = await _uploadVfsSnapshot();

      if (success) {
        await _storage.upgradeVfsVersion();
        print('[VFS] Migration to V2 completed successfully!');
      }
    } catch (e) {
      print('[VFS MIGRATION ERROR] $e');
    }
  }

  // MARK: - SNAPSHOT OPERATIONS
  Future<bool> _uploadVfsSnapshot() async {
    if (_db == null || _isUploadingSnapshot) return false;
    _isUploadingSnapshot = true;

    try {
      final userMasterKey = await _secureStorage.read(key: 'user_master_key');
      if (userMasterKey == null) return false;

      final allNodes = await _db!.query('nodes');
      final jsonString = jsonEncode(allNodes);

      final encryptedBytes = await _encryption.encryptDataWithKey(
        utf8.encode(jsonString),
        userMasterKey,
      );

      final uploadUrl = await _storage.getVfsSnapshotUrl(true);
      if (uploadUrl == null) return false;

      final response = await http
          .put(Uri.parse(uploadUrl), body: encryptedBytes)
          .timeout(const Duration(seconds: 30));

      return response.statusCode == 200;
    } catch (e) {
      print('[EXCEPTION] Upload VFS Snapshot: $e');
      return false;
    } finally {
      _isUploadingSnapshot = false;
    }
  }

  Future<void> _downloadVfsSnapshot() async {
    try {
      final userMasterKey = await _secureStorage.read(key: 'user_master_key');
      if (userMasterKey == null) return;

      final downloadUrl = await _storage.getVfsSnapshotUrl(false);
      if (downloadUrl == null) return;

      final response = await http
          .get(Uri.parse(downloadUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return;

      final decryptedBytes = await _encryption.decryptDataWithKey(
        response.bodyBytes,
        userMasterKey,
      );

      final String jsonString = utf8.decode(decryptedBytes);
      final List<dynamic> nodesList = jsonDecode(jsonString);

      await _db!.transaction((txn) async {
        await txn.delete('nodes');
        for (var nodeMap in nodesList) {
          await txn.insert('nodes', nodeMap as Map<String, dynamic>);
        }
      });

      await _loadToMemory();
    } catch (e) {
      print('[EXCEPTION] Download VFS Snapshot (might be new user): $e');
    }
  }

  // MARK: - DEBOUNCED UPLOAD MECHANISM
  void _triggerDebouncedSync() {
    if (_syncTimer?.isActive ?? false) {
      _syncTimer!.cancel();
    }

    _syncTimer = Timer(const Duration(seconds: 3), () async {
      await _uploadVfsSnapshot();
    });
  }

  Future<void> forceSyncNow() async {
    if (_syncTimer?.isActive ?? false) {
      _syncTimer!.cancel();
      await _uploadVfsSnapshot();
    }
  }

  // MARK: - CREATE & UPDATE OPERATIONS
  Future<String?> createFolder(String name, String parentId) async {
    final id = _uuid.v4();
    final success = await _saveNode(id, name, parentId, true);
    return success ? id : null;
  }

  Future<bool> addFileNode(
    String fileId,
    String name,
    String parentId, {
    String? encryptedFileKey,
    int? size,
  }) async {
    return await _saveNode(
      fileId,
      name,
      parentId,
      false,
      encryptedFileKey: encryptedFileKey,
      size: size,
    );
  }

  Future<bool> _saveNode(
    String id,
    String name,
    String parentId,
    bool isFolder, {
    bool isFavorite = false,
    int? size,
    String? encryptedFileKey,
    String? shareId,
    String? shareKey,
    String? encryptedShareKey,
  }) async {
    await _db!.insert('nodes', {
      'id': id,
      'parentId': parentId,
      'name': name,
      'isFolder': isFolder ? 1 : 0,
      'isFavorite': isFavorite ? 1 : 0,
      'size': size,
      'etag': 'v2_synced',
      'encryptedFileKey': encryptedFileKey,
      'shareId': shareId,
      'shareKey': shareKey,
      'encryptedShareKey': encryptedShareKey,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await _loadToMemory();

    _triggerDebouncedSync();

    return true;
  }

  Future<void> toggleFavorite(String nodeId) async {
    final index = _memoryCache.indexWhere((n) => n.id == nodeId);
    if (index == -1) return;

    final node = _memoryCache[index];
    final newFavoriteStatus = !node.isFavorite;

    await _db!.update(
      'nodes',
      {'isFavorite': newFavoriteStatus ? 1 : 0},
      where: 'id = ?',
      whereArgs: [nodeId],
    );

    _memoryCache[index] = node.copyWith(isFavorite: newFavoriteStatus);

    _triggerDebouncedSync();
  }

  // MARK: - DELETE & SHARE OPERATIONS
  Future<bool> deleteNodes(List<String> initialNodeIds) async {
    final queue = Queue<String>.from(initialNodeIds);
    List<Map<String, dynamic>> itemsToDelete = [];
    List<String> localIdsToRemove = [];

    while (queue.isNotEmpty) {
      final id = queue.removeFirst();
      final node = _memoryCache.firstWhere(
        (n) => n.id == id,
        orElse: () => VfsNode(id: '', parentId: '', name: '', isFolder: false),
      );

      if (node.id.isEmpty) continue;

      localIdsToRemove.add(id);
      itemsToDelete.add({'id': id, 'type': 'node', 'size': 0});

      if (node.isFolder) {
        final children = getChildren(id);
        queue.addAll(children.map((c) => c.id));
      } else {
        itemsToDelete.add({'id': id, 'type': 'file', 'size': node.size ?? 0});
      }
    }

    if (itemsToDelete.isEmpty) return true;

    final success = await _storage.logicalDeleteToTrash(itemsToDelete);
    if (!success) return false;

    await _db!.transaction((txn) async {
      for (var id in localIdsToRemove) {
        await txn.delete('nodes', where: 'id = ?', whereArgs: [id]);
      }
    });

    await _loadToMemory();

    _triggerDebouncedSync();

    return true;
  }

  Future<void> updateNodeShareData(
    String nodeId,
    String? shareId,
    String? encryptedShareKey,
  ) async {
    if (_db == null) return;

    final index = _memoryCache.indexWhere((n) => n.id == nodeId);
    if (index == -1) return;

    final node = _memoryCache[index];

    await _db!.update(
      'nodes',
      {'shareId': shareId, 'encryptedShareKey': encryptedShareKey},
      where: 'id = ?',
      whereArgs: [nodeId],
    );

    _memoryCache[index] = node.copyWith(
      shareId: shareId,
      encryptedShareKey: encryptedShareKey,
      clearShareData: shareId == null,
    );

    _triggerDebouncedSync();
  }
}
