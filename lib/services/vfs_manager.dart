import 'dart:io';
import 'dart:collection';
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:boardly_cloud/models/vfs_node.dart';
import 'package:boardly_cloud/services/cloudflare_storage_service.dart';

class VfsManager {
  // MARK: - SINGLETON & CONFIG
  static final VfsManager _instance = VfsManager._internal();
  factory VfsManager() => _instance;
  VfsManager._internal();

  final _storage = CloudflareStorageService();
  final _uuid = const Uuid();

  // MARK: - STATE & CACHE
  Database? _db;
  List<VfsNode> _memoryCache = [];

  // MARK: - DATABASE INITIALIZATION & MIGRATIONS
  Future<void> initDB() async {
    if (_db != null) return;

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
        if (oldVersion < 2)
          await db.execute(
            'ALTER TABLE nodes ADD COLUMN encryptedFileKey TEXT',
          );
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE nodes ADD COLUMN shareId TEXT');
          await db.execute('ALTER TABLE nodes ADD COLUMN shareKey TEXT');
        }
        if (oldVersion < 4)
          await db.execute(
            'ALTER TABLE nodes ADD COLUMN encryptedShareKey TEXT',
          );
        if (oldVersion < 5)
          await db.execute(
            'ALTER TABLE nodes ADD COLUMN isFavorite INTEGER DEFAULT 0',
          );
        if (oldVersion < 6)
          await db.execute('ALTER TABLE nodes ADD COLUMN size INTEGER');
      },
    );
    await _loadToMemory();
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
  List<VfsNode> getChildren(String parentId) {
    return _memoryCache.where((n) => n.parentId == parentId).toList();
  }

  List<VfsNode> get nodes => _memoryCache;

  List<VfsNode> get favoriteNodes =>
      _memoryCache.where((n) => n.isFavorite).toList();

  // MARK: - CLOUD SYNC LOGIC
  Future<void> sync() async {
    await initDB();

    try {
      final cloudNodes = await _storage.getCloudNodesMeta();
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
            final notInCloud = !cloudIds.contains(id);
            return notInCloud && !isPending;
          }).toList();

      if (idsToDelete.isNotEmpty) {
        await _db!.transaction((txn) async {
          for (var id in idsToDelete) {
            await txn.delete('nodes', where: 'id = ?', whereArgs: [id]);
          }
        });
      }

      await _loadToMemory();
    } catch (e) {
      print('[VFS SYNC ERROR] $e');
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
    final nodeData = {
      'id': id,
      'parentId': parentId,
      'name': name,
      'isFolder': isFolder,
      'isFavorite': isFavorite,
      'size': size,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      if (encryptedFileKey != null) 'encryptedFileKey': encryptedFileKey,
      if (shareId != null) 'shareId': shareId,
      if (shareKey != null) 'shareKey': shareKey,
      if (encryptedShareKey != null) 'encryptedShareKey': encryptedShareKey,
    };

    final success = await _storage.uploadNodeJson(id, nodeData);
    if (!success) return false;

    await _db!.insert('nodes', {
      'id': id,
      'parentId': parentId,
      'name': name,
      'isFolder': isFolder ? 1 : 0,
      'isFavorite': isFavorite ? 1 : 0,
      'size': size,
      'etag': 'pending_sync',
      'encryptedFileKey': encryptedFileKey,
      'shareId': shareId,
      'shareKey': shareKey,
      'encryptedShareKey': encryptedShareKey,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await _loadToMemory();
    return true;
  }

  Future<void> toggleFavorite(String nodeId) async {
    final index = _memoryCache.indexWhere((n) => n.id == nodeId);
    if (index == -1) return;

    final node = _memoryCache[index];
    final newFavoriteStatus = !node.isFavorite;

    final nodeData = node.copyWith(isFavorite: newFavoriteStatus).toJson();
    nodeData['updatedAt'] = DateTime.now().millisecondsSinceEpoch;

    final success = await _storage.uploadNodeJson(nodeId, nodeData);
    if (!success) return;

    await _db!.update(
      'nodes',
      {'isFavorite': newFavoriteStatus ? 1 : 0},
      where: 'id = ?',
      whereArgs: [nodeId],
    );

    _memoryCache[index] = node.copyWith(isFavorite: newFavoriteStatus);
  }

  // MARK: - DELETE & SHARE OPERATIONS
  Future<bool> deleteNodes(List<String> initialNodeIds) async {
    bool allSuccess = true;
    final queue = Queue<String>.from(initialNodeIds);

    while (queue.isNotEmpty) {
      final id = queue.removeFirst();
      final node = _memoryCache.firstWhere(
        (n) => n.id == id,
        orElse: () => VfsNode(id: '', parentId: '', name: '', isFolder: false),
      );

      if (node.id.isEmpty) continue;

      if (node.isFolder) {
        final children = getChildren(id);
        queue.addAll(children.map((c) => c.id));
      } else {
        await _storage.deleteFile(id);
      }

      await _storage.deleteNode(id);
      await _db!.delete('nodes', where: 'id = ?', whereArgs: [id]);
    }

    await _loadToMemory();
    return allSuccess;
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

    final nodeData = {
      'id': node.id,
      'parentId': node.parentId,
      'name': node.name,
      'isFolder': node.isFolder,
      'isFavorite': node.isFavorite,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      if (node.encryptedFileKey != null)
        'encryptedFileKey': node.encryptedFileKey,
      'shareId': shareId,
      'encryptedShareKey': encryptedShareKey,
    };

    await _storage.uploadNodeJson(nodeId, nodeData);

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
  }
}
