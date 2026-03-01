import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:path/path.dart' as p;

import 'package:boardly_cloud/models/vfs_node.dart';
import 'package:boardly_cloud/models/user_data.dart';
import 'package:boardly_cloud/services/auth_http_client.dart';
import 'package:boardly_cloud/storage/auth_storage.dart';
import 'package:boardly_cloud/services/cloudflare_storage_service.dart';
import 'package:boardly_cloud/services/vfs_manager.dart';
import 'package:boardly_cloud/services/encryption_service.dart';
import 'package:boardly_cloud/widgets/side_file_manager.dart';
import '../translations.dart';
import '../main.dart';

class CloudStorageScreen extends StatefulWidget {
  const CloudStorageScreen({super.key});

  @override
  State<CloudStorageScreen> createState() => _CloudStorageScreenState();
}

class _CloudStorageScreenState extends State<CloudStorageScreen>
    with WidgetsBindingObserver {
  // MARK: - STATE & SERVICES
  final _storageService = CloudflareStorageService();
  final _vfsManager = VfsManager();
  final _encryption = EncryptionService();
  final _uuid = const Uuid();
  final FocusNode _focusNode = FocusNode();
  final _secureStorage = const FlutterSecureStorage();

  final Set<String> _selectedIds = {};
  bool _isDragging = false;
  final TextEditingController _importLinkController = TextEditingController();

  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  bool _isCheckingKey = true;
  bool _needsKeySetup = false;
  bool _showCreateFlow = false;
  bool _showRecoverFlow = false;
  List<String> _generatedMnemonic = [];
  bool _hasSavedMnemonic = false;
  final TextEditingController _recoveryController = TextEditingController();

  bool _isLoading = true;
  bool _isProcessing = false;
  String _processText = "";

  UserData? _currentUserData;

  final List<VfsNode> _pathStack = [
    VfsNode(id: 'root', parentId: '', name: 'root', isFolder: true),
  ];
  String get _currentFolderId => _pathStack.last.id;

  // MARK: - LIFECYCLE
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.dispose();
    _recoveryController.dispose();
    _importLinkController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (!_needsKeySetup && !_isCheckingKey) {
        _silentRefresh();
      }
    }
  }

  // MARK: - CORE DATA & AUTH
  Future<void> _initializeApp() async {
    _currentUserData = await AuthStorage.getUserData();
    await _silentRefresh();
    await _checkMasterKey();
    _focusNode.requestFocus();
    _refreshUserDataFromServer();
  }

  Future<void> _silentRefresh() async {
    await _vfsManager.sync();
    if (mounted) setState(() {});
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    await _vfsManager.initDB();
    await _vfsManager.sync();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _refreshUserDataFromServer() async {
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse('https://api.boardly.studio/user/me'),
        method: 'GET',
      );

      if (response.statusCode == 200) {
        final userData = jsonDecode(response.body);
        final currentData = await AuthStorage.getUserData();
        if (currentData != null) {
          final newData = UserData(
            userId: currentData.userId,
            username: currentData.username,
            email: currentData.email,
            publicId: currentData.publicId,
            isPro: userData['is_pro'] ?? false,
            storageLimitMb: userData['storage_limit_mb'] ?? 500,
            storageUsedMb: (userData['storage_used_mb'] ?? 0).toDouble(),
          );
          await AuthStorage.saveUserData(newData);
          if (mounted) {
            setState(() {
              _currentUserData = newData;
            });
          }
        }
      }
    } finally {
      client.close();
    }
  }

  Future<void> _logout() async {
    await AuthStorage.clearAll();
    if (mounted) {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const AuthScreen()));
    }
  }

  // MARK: - VAULT & SECURITY FLOW
  Future<void> _checkMasterKey() async {
    setState(() => _isCheckingKey = true);
    try {
      final key = await _secureStorage.read(key: 'user_master_key');
      if (key == null || key.isEmpty) {
        setState(() {
          _needsKeySetup = true;
          _isCheckingKey = false;
        });
      } else {
        setState(() {
          _needsKeySetup = false;
          _isCheckingKey = false;
        });
        await _loadInitialData();
      }
    } catch (e) {
      setState(() {
        _needsKeySetup = true;
        _isCheckingKey = false;
      });
    }
  }

  Future<void> _startCreateVaultFlow() async {
    String mnemonic = bip39.generateMnemonic();
    setState(() {
      _generatedMnemonic = mnemonic.split(' ');
      _showCreateFlow = true;
      _showRecoverFlow = false;
      _hasSavedMnemonic = false;
    });
  }

  Future<void> _confirmAndCreateVault() async {
    if (!_hasSavedMnemonic) return;
    _setProcessing(true, tr(context, 'creating_vault'));

    try {
      final String randomSalt = _uuid.v4();
      final String seedPhrase = _generatedMnemonic.join(' ');
      final kek = await _encryption.deriveKeyFromPassphrase(
        seedPhrase,
        randomSalt,
      );
      final userMasterKey = _encryption.generateRandomKey();
      final encryptedMasterKeyBytes = await _encryption.encryptDataWithKey(
        Uint8List.fromList(utf8.encode(userMasterKey)),
        kek,
      );
      final combinedPayload = Uint8List.fromList(
        utf8.encode(randomSalt) + encryptedMasterKeyBytes,
      );
      final uploadUrl = await _storageService.getRecoveryUploadUrl();
      final response = await http.put(
        Uri.parse(uploadUrl),
        body: combinedPayload,
      );

      if (response.statusCode == 200) {
        await _secureStorage.write(
          key: 'user_master_key',
          value: userMasterKey,
        );
        setState(() => _needsKeySetup = false);
        await _loadInitialData();
      }
    } catch (e) {
      _showSnackBar('Error: $e', Colors.redAccent);
    } finally {
      _setProcessing(false);
    }
  }

  Future<void> _recoverVault() async {
    final seedPhrase = _recoveryController.text.trim().toLowerCase();
    if (seedPhrase.split(RegExp(r'\s+')).length != 12) {
      _showSnackBar(tr(context, 'phrase_length_err'), Colors.orangeAccent);
      return;
    }

    _setProcessing(true, tr(context, 'restoring'));
    try {
      final downloadUrl = await _storageService.getRecoveryDownloadUrl();
      final response = await http.get(Uri.parse(downloadUrl));

      if (response.statusCode == 200) {
        final fullBytes = response.bodyBytes;
        if (fullBytes.length < 36) throw Exception("Corrupted file");

        final saltBytes = fullBytes.sublist(0, 36);
        final extractedSalt = utf8.decode(saltBytes);
        final encryptedData = fullBytes.sublist(36);

        final kek = await _encryption.deriveKeyFromPassphrase(
          seedPhrase,
          extractedSalt,
        );
        final decryptedBytes = await _encryption.decryptDataWithKey(
          encryptedData,
          kek,
        );
        final recoveredMasterKey = utf8.decode(decryptedBytes);

        await _secureStorage.write(
          key: 'user_master_key',
          value: recoveredMasterKey,
        );
        setState(() => _needsKeySetup = false);
        await _loadInitialData();
        _showSnackBar(tr(context, 'restored_success'), const Color(0xFF00E5FF));
      } else if (response.statusCode == 404) {
        _showSnackBar(tr(context, 'restore_not_found'), Colors.redAccent);
      } else {
        _showSnackBar(
          '${tr(context, 'server_error')} ${response.statusCode}',
          Colors.redAccent,
        );
      }
    } catch (e) {
      _showSnackBar(tr(context, 'invalid_phrase'), Colors.redAccent);
    } finally {
      _setProcessing(false);
    }
  }

  // MARK: - UPLOAD & DOWNLOAD LOGIC
  Future<void> _processDroppedFiles(List<XFile> droppedFiles) async {
    _setProcessing(true, tr(context, 'processing'));
    int successCount = 0;

    for (var xFile in droppedFiles) {
      final path = xFile.path;
      if (await FileSystemEntity.isDirectory(path)) {
        await _uploadDirectory(Directory(path), _currentFolderId);
        successCount++;
      } else if (await FileSystemEntity.isFile(path)) {
        final file = File(path);
        final fileName = p.basename(path);
        bool success = await _uploadLocalFile(file, fileName, _currentFolderId);
        if (success) successCount++;
      }
    }

    _setProcessing(false);
    if (successCount > 0) {
      _showSnackBar(
        '${tr(context, 'files_uploaded')} $successCount',
        const Color(0xFF00E5FF),
      );
      await _silentRefresh();
      await _refreshUserDataFromServer();
    }
  }

  Future<void> _uploadDirectory(Directory dir, String parentFolderId) async {
    final dirName = p.basename(dir.path);
    final newFolderId = await _vfsManager.createFolder(dirName, parentFolderId);
    if (newFolderId == null) return;

    final entities = await dir.list().toList();
    for (var entity in entities) {
      if (entity is Directory) {
        await _uploadDirectory(entity, newFolderId);
      } else if (entity is File) {
        final fileName = p.basename(entity.path);
        await _uploadLocalFile(entity, fileName, newFolderId);
      }
    }
  }

  Future<bool> _uploadLocalFile(
    File file,
    String fileName,
    String targetFolderId,
  ) async {
    final userMasterKey = await _secureStorage.read(key: 'user_master_key');
    if (userMasterKey == null) return false;

    String fileId = _uuid.v4();
    final rawFileKey = _encryption.generateRandomKey();

    try {
      final originalSize = await file.length();
      final encryptedSize = _encryption.calculateEncryptedSize(originalSize);
      final fileStream = file.openRead();
      final encryptedStream = _encryption.encryptStreamWithKey(
        fileStream,
        rawFileKey,
      );

      bool uploadSuccess = await _storageService.uploadStream(
        fileId,
        encryptedSize,
        encryptedStream,
      );

      if (uploadSuccess) {
        await _storageService.confirmFileUpload(fileId);
        final encryptedFileKey = await _encryption.encryptTextWithKey(
          rawFileKey,
          userMasterKey,
        );

        bool nodeCreated = await _vfsManager.addFileNode(
          fileId,
          fileName,
          targetFolderId,
          encryptedFileKey: encryptedFileKey,
          size: encryptedSize,
        );

        return nodeCreated;
      }
    } catch (e) {
      print('[EXCEPTION] Upload Local File Error: $e');
    }
    return false;
  }

  Future<void> _pickAndUploadFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    int successCount = 0;
    final currentChildren = _vfsManager.getChildren(_currentFolderId);
    final userMasterKey = await _secureStorage.read(key: 'user_master_key');
    if (userMasterKey == null) return;

    for (var platformFile in result.files) {
      if (platformFile.path == null) continue;

      bool fileExists = currentChildren.any(
        (n) => !n.isFolder && n.name == platformFile.name,
      );
      if (fileExists) {
        bool proceed =
            await showDialog<bool>(
              context: context,
              builder:
                  (context) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1D24),
                    title: Text(
                      tr(context, 'file_exists'),
                      style: const TextStyle(color: Colors.white),
                    ),
                    content: Text(
                      '${platformFile.name} ${tr(context, 'file_exists_desc')}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(
                          tr(context, 'skip'),
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(tr(context, 'upload')),
                      ),
                    ],
                  ),
            ) ??
            false;
        if (!proceed) continue;
      }

      _setProcessing(
        true,
        "${tr(context, 'uploading')} ${platformFile.name}...",
      );
      File file = File(platformFile.path!);
      String fileId = _uuid.v4();
      final rawFileKey = _encryption.generateRandomKey();

      try {
        final originalSize = await file.length();
        final encryptedSize = _encryption.calculateEncryptedSize(originalSize);
        final fileStream = file.openRead();
        final encryptedStream = _encryption.encryptStreamWithKey(
          fileStream,
          rawFileKey,
        );

        bool uploadSuccess = await _storageService.uploadStream(
          fileId,
          encryptedSize,
          encryptedStream,
        );

        if (uploadSuccess) {
          await _storageService.confirmFileUpload(fileId);
          final encryptedFileKey = await _encryption.encryptTextWithKey(
            rawFileKey,
            userMasterKey,
          );

          bool nodeCreated = await _vfsManager.addFileNode(
            fileId,
            platformFile.name,
            _currentFolderId,
            encryptedFileKey: encryptedFileKey,
            size: encryptedSize,
          );

          if (nodeCreated) {
            successCount++;
          }
        }
      } catch (e) {
        _showSnackBar(
          '${tr(context, 'upload_error')} ${platformFile.name}',
          Colors.redAccent,
        );
      }
    }

    _setProcessing(false);
    if (successCount > 0) {
      _showSnackBar(
        '${tr(context, 'files_uploaded')} $successCount',
        const Color(0xFF00E5FF),
      );
      await _silentRefresh();
      await _refreshUserDataFromServer();
    }
    _clearSelection();
  }

  Future<void> _downloadNodes(List<VfsNode> nodes) async {
    final filesToDownload = nodes.where((n) => !n.isFolder).toList();
    if (filesToDownload.isEmpty) return;

    _setProcessing(true, tr(context, 'downloading'));
    final userMasterKey = await _secureStorage.read(key: 'user_master_key');

    for (var node in filesToDownload) {
      try {
        if (node.encryptedFileKey == null || userMasterKey == null) continue;
        String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save ${node.name}',
          fileName: node.name,
        );
        if (savePath != null) {
          final url = await _storageService.getFileDownloadUrl(node.id);
          if (url != null) {
            final request = http.Request('GET', Uri.parse(url));
            final streamedResponse = await http.Client().send(request);
            if (streamedResponse.statusCode == 200) {
              final rawFileKey = await _encryption.decryptTextWithKey(
                node.encryptedFileKey!,
                userMasterKey,
              );
              final localFile = File(savePath);
              await localFile.create(recursive: true);
              final writeSink = localFile.openWrite();
              final decryptedStream = _encryption.decryptStreamWithKey(
                streamedResponse.stream,
                rawFileKey,
              );
              await decryptedStream.pipe(writeSink);
            }
          }
        }
      } catch (e) {}
    }
    _setProcessing(false);
    _clearSelection();
    _showSnackBar(tr(context, 'download_done'), const Color(0xFF00E5FF));
  }

  // MARK: - SHARING LOGIC
  Future<void> _shareFolder(VfsNode folder) async {
    _setProcessing(true, tr(context, 'generating_folder_access'));
    try {
      final allFiles = _getAllFilesRecursive(folder.id);
      if (allFiles.isEmpty) {
        _showSnackBar(tr(context, 'folder_empty_warn'), Colors.orange);
        return;
      }

      final userMasterKey = await _secureStorage.read(key: 'user_master_key');
      if (userMasterKey == null) throw Exception("Master key not found");

      final folderShareKey = _encryption.generateRandomKey();
      List<Map<String, dynamic>> manifestFiles = [];
      List<String> fileIdsForBackend = [];

      for (var file in allFiles) {
        if (file.encryptedFileKey == null) continue;
        final rawFileKey = await _encryption.decryptTextWithKey(
          file.encryptedFileKey!,
          userMasterKey,
        );
        manifestFiles.add({
          'id': file.id,
          'name': file.name,
          'key': rawFileKey,
          'size': file.size,
        });
        fileIdsForBackend.add(file.id);
      }

      final manifestJson = jsonEncode({
        "folderName": folder.name,
        "files": manifestFiles,
      });
      final encryptedManifest = await _encryption.encryptDataWithKey(
        Uint8List.fromList(utf8.encode(manifestJson)),
        folderShareKey,
      );

      final manifestId = "fmanifest_${_uuid.v4()}";
      bool uploadSuccess = await _storageService.uploadBytes(
        manifestId,
        encryptedManifest,
      );

      if (uploadSuccess) {
        final shareId = await _storageService.createFolderShareLink(
          manifestId,
          folder.name,
          fileIdsForBackend,
        );
        if (shareId != null) {
          final encodedName = Uri.encodeComponent(folder.name);
          final encodedKey = Uri.encodeComponent(folderShareKey);
          final shareUrl =
              'https://boardly.studio/share/folder/$shareId#name=$encodedName&key=$encodedKey';

          await Clipboard.setData(ClipboardData(text: shareUrl));
          final encryptedShareKeyForDb = await _encryption.encryptTextWithKey(
            folderShareKey,
            userMasterKey,
          );
          await _vfsManager.updateNodeShareData(
            folder.id,
            shareId,
            encryptedShareKeyForDb,
          );
          await _silentRefresh();

          _showSnackBar(
            tr(context, 'folder_link_copied'),
            const Color(0xFF00BFA5),
          );
        }
      }
    } catch (e) {
      _showSnackBar('${tr(context, 'error')}: $e', Colors.redAccent);
    } finally {
      _setProcessing(false);
    }
  }

  Future<void> _shareNode(VfsNode node) async {
    _setProcessing(true, tr(context, 'generating_link'));
    try {
      if (node.isFolder) {
        await _shareFolder(node);
        return;
      }

      final userMasterKey = await _secureStorage.read(key: 'user_master_key');
      if (userMasterKey == null) throw Exception("Master key not found");

      final String? shareId = await _storageService.createShareLink(node.id);
      if (shareId != null && node.encryptedFileKey != null) {
        final rawFileKey = await _encryption.decryptTextWithKey(
          node.encryptedFileKey!,
          userMasterKey,
        );
        final encodedName = Uri.encodeComponent(node.name);
        final encodedKey = Uri.encodeComponent(rawFileKey);
        final shareUrl =
            'https://boardly.studio/share/$shareId#name=$encodedName&key=$encodedKey';

        await Clipboard.setData(ClipboardData(text: shareUrl));
        final encryptedShareKeyForDb = await _encryption.encryptTextWithKey(
          rawFileKey,
          userMasterKey,
        );
        await _vfsManager.updateNodeShareData(
          node.id,
          shareId,
          encryptedShareKeyForDb,
        );
        await _silentRefresh();

        _showSnackBar(tr(context, 'link_copied'), const Color(0xFF00BFA5));
      }
    } catch (e) {
      _showSnackBar('${tr(context, 'error')}: $e', Colors.redAccent);
    } finally {
      _setProcessing(false);
    }
  }

  // MARK: - IMPORT LOGIC
  Future<void> _processImportLink(String link) async {
    FocusScope.of(context).unfocus();
    try {
      final cleanLink = link.trim();
      final uri = Uri.parse(cleanLink);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) throw Exception(tr(context, 'invalid_link'));

      final bool isFolder = segments.contains('folder');
      final String shareId = segments.last;

      String fragment = uri.fragment;
      Map<String, String> params = {};
      if (fragment.contains('=')) {
        params = Uri.splitQueryString(fragment);
      } else {
        params['key'] = fragment;
      }

      final String? key = params['key'] ?? params['k'];
      String name =
          (params['name']?.isNotEmpty == true)
              ? params['name']!
              : (isFolder ? "Imported Folder" : "Imported File");

      if (key == null || key.isEmpty) throw Exception("Key missing");

      _setProcessing(true, tr(context, 'loading_metadata'));

      if (isFolder) {
        final manifestInfo = await _storageService.getSharedFolderManifestUrl(
          shareId,
        );
        if (manifestInfo == null)
          throw Exception(tr(context, 'folder_not_found'));

        final response = await http.get(
          Uri.parse(manifestInfo['download_url']),
        );
        final decryptedBytes = await _encryption.decryptDataWithKey(
          response.bodyBytes,
          key,
        );
        final manifest = jsonDecode(utf8.decode(decryptedBytes));

        _setProcessing(false);
        _showFolderPreviewDialog(
          shareId,
          name,
          List<Map<String, dynamic>>.from(manifest['files']),
          key,
        );
      } else {
        final shareData = await _storageService.getSharedFileMetadataAndUrl(
          shareId,
        );
        if (shareData == null) throw Exception(tr(context, 'file_unavailable'));

        _setProcessing(false);
        final int fileSize = shareData['size'] ?? 0;

        final bool? confirm = await _showImportConfirmationDialog(
          name,
          fileSize,
        );
        if (confirm == true) {
          await _executeSingleFileImport(name, shareData['download_url'], key);
        }
      }
    } catch (e) {
      _showSnackBar(tr(context, 'invalid_link_format'), Colors.redAccent);
    } finally {
      if (_isProcessing) _setProcessing(false);
    }
  }

  Future<void> _executeSingleFileImport(
    String name,
    String url,
    String key,
  ) async {
    _setProcessing(true, tr(context, 'importing_file'));
    try {
      final userMasterKey = await _secureStorage.read(key: 'user_master_key');
      final response = await http.Client().send(
        http.Request('GET', Uri.parse(url)),
      );

      if (response.statusCode == 200) {
        final newFileId = _uuid.v4();
        final newFileKey = _encryption.generateRandomKey();

        final processedStream = _encryption.encryptStreamWithKey(
          _encryption.decryptStreamWithKey(response.stream, key),
          newFileKey,
        );

        bool success = await _storageService.uploadStream(
          newFileId,
          response.contentLength ?? 0,
          processedStream,
        );

        if (success) {
          await _storageService.confirmFileUpload(newFileId);
          final encKey = await _encryption.encryptTextWithKey(
            newFileKey,
            userMasterKey!,
          );

          bool nodeCreated = await _vfsManager.addFileNode(
            newFileId,
            name,
            _currentFolderId,
            encryptedFileKey: encKey,
            size: response.contentLength,
          );

          if (nodeCreated) {
            _showSnackBar(
              "${tr(context, 'imported_success')} $name",
              Colors.green,
            );
            await _silentRefresh();
          }
        }
      }
    } catch (e) {
      _showSnackBar("${tr(context, 'import_error')} $e", Colors.red);
    } finally {
      _setProcessing(false);
    }
  }

  Future<void> _executeSingleFileFromFolderImport(
    String shareId,
    Map<String, dynamic> fileData,
    String sourceFolderName,
  ) async {
    _setProcessing(
      true,
      "${tr(context, 'importing_file')} ${fileData['name']}...",
    );
    try {
      final fileUrl = await _storageService.getSharedFolderFileUrl(
        shareId,
        fileData['id'],
      );
      if (fileUrl == null) throw Exception(tr(context, 'file_unavailable'));

      final userMasterKey = await _secureStorage.read(key: 'user_master_key');
      if (userMasterKey == null) throw Exception("Master key not found");

      final response = await http.Client().send(
        http.Request('GET', Uri.parse(fileUrl)),
      );
      if (response.statusCode == 200) {
        final newFileId = _uuid.v4();
        final newRawKey = _encryption.generateRandomKey();

        final reEncryptedStream = _encryption.encryptStreamWithKey(
          _encryption.decryptStreamWithKey(response.stream, fileData['key']),
          newRawKey,
        );

        bool success = await _storageService.uploadStream(
          newFileId,
          response.contentLength ?? 0,
          reEncryptedStream,
        );

        if (success) {
          await _storageService.confirmFileUpload(newFileId);
          final encKeyForDb = await _encryption.encryptTextWithKey(
            newRawKey,
            userMasterKey,
          );

          bool nodeCreated = await _vfsManager.addFileNode(
            newFileId,
            fileData['name'],
            _currentFolderId,
            encryptedFileKey: encKeyForDb,
            size: response.contentLength,
          );

          if (nodeCreated) {
            _showSnackBar(
              "${tr(context, 'imported_success')} ${fileData['name']}",
              const Color(0xFF00BFA5),
            );
            await _silentRefresh();
          }
        }
      }
    } catch (e) {
      _showSnackBar("${tr(context, 'import_error')} $e", Colors.redAccent);
    } finally {
      _setProcessing(false);
    }
  }

  Future<void> _executeFolderImport(
    String shareId,
    String folderName,
    List<Map<String, dynamic>> files,
    String folderKey,
  ) async {
    _setProcessing(true, tr(context, 'creating_folder'));
    try {
      final targetFolderId = await _vfsManager.createFolder(
        folderName,
        _currentFolderId,
      );
      if (targetFolderId == null) throw Exception("Could not create folder");

      final userMasterKey = await _secureStorage.read(key: 'user_master_key');

      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        _setProcessing(
          true,
          "${tr(context, 'importing_file')} ${i + 1}/${files.length}: ${file['name']}",
        );

        final fileUrl = await _storageService.getSharedFolderFileUrl(
          shareId,
          file['id'],
        );
        if (fileUrl == null) continue;

        final response = await http.Client().send(
          http.Request('GET', Uri.parse(fileUrl)),
        );
        if (response.statusCode == 200) {
          final newFileId = _uuid.v4();
          final newRawKey = _encryption.generateRandomKey();

          final reEncryptedStream = _encryption.encryptStreamWithKey(
            _encryption.decryptStreamWithKey(response.stream, file['key']),
            newRawKey,
          );

          bool success = await _storageService.uploadStream(
            newFileId,
            response.contentLength ?? 0,
            reEncryptedStream,
          );

          if (success) {
            await _storageService.confirmFileUpload(newFileId);
            final encKeyForDb = await _encryption.encryptTextWithKey(
              newRawKey,
              userMasterKey!,
            );

            await _vfsManager.addFileNode(
              newFileId,
              file['name'],
              targetFolderId,
              encryptedFileKey: encKeyForDb,
            );
          }
        }
      }
      _showSnackBar(
        "${tr(context, 'import_title')} '$folderName' ${tr(context, 'folder_imported_fully')}",
        const Color(0xFF00BFA5),
      );
      await _silentRefresh();
    } catch (e) {
      _showSnackBar("${tr(context, 'import_error')} $e", Colors.redAccent);
    } finally {
      _setProcessing(false);
    }
  }

  // MARK: - TRASH LOGIC
  Future<Map<String, dynamic>?> _getTrashItems() async {
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse(
          'https://api.boardly.studio/storage/system/recovery/list-trash',
        ),
        method: 'GET',
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
    } finally {
      client.close();
    }
    return null;
  }

  Future<bool> _restoreTrashItem(String type, String id) async {
    final client = AuthHttpClient();
    try {
      final response = await client.request(
        Uri.parse(
          'https://api.boardly.studio/storage/system/recovery/restore-trash',
        ),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"item_type": type, "item_id": id}),
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    } finally {
      client.close();
    }
  }

  // MARK: - VFS HELPER METHODS
  List<VfsNode> _getAllFilesRecursive(String folderId) {
    List<VfsNode> results = [];
    final children = _vfsManager.getChildren(folderId);
    for (var child in children) {
      if (child.isFolder) {
        results.addAll(_getAllFilesRecursive(child.id));
      } else {
        results.add(child);
      }
    }
    return results;
  }

  Future<void> _deleteNodes(List<String> nodeIds) async {
    _setProcessing(true, tr(context, 'deleting'));
    bool success = await _vfsManager.deleteNodes(nodeIds);
    _setProcessing(false);
    _clearSelection();

    if (success) {
      _showSnackBar(tr(context, 'success_delete'), Colors.white54);
      await _silentRefresh();
      await _refreshUserDataFromServer();
    }
  }

  Future<void> _createNewFolder() async {
    final TextEditingController controller = TextEditingController();
    final folderName = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1A1D24),
            title: Text(
              tr(context, 'new_folder'),
              style: const TextStyle(color: Colors.white),
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(hintText: tr(context, 'folder_name')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  tr(context, 'cancel'),
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: Text(tr(context, 'create')),
              ),
            ],
          ),
    );

    if (folderName != null && folderName.isNotEmpty) {
      final name = folderName.trim();
      final currentChildren = _vfsManager.getChildren(_currentFolderId);
      bool folderExists = currentChildren.any(
        (n) => n.isFolder && n.name == name,
      );

      if (folderExists) {
        bool proceed =
            await showDialog<bool>(
              context: context,
              builder:
                  (context) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1D24),
                    title: Text(
                      tr(context, 'folder_exists'),
                      style: const TextStyle(color: Colors.white),
                    ),
                    content: Text(
                      '"$name" ${tr(context, 'folder_exists_desc')}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(
                          tr(context, 'cancel'),
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(tr(context, 'create')),
                      ),
                    ],
                  ),
            ) ??
            false;
        if (!proceed) return;
      }
      _setProcessing(true, tr(context, 'creating_folder'));
      await _vfsManager.createFolder(name, _currentFolderId);
      _setProcessing(false);
      await _silentRefresh();
    }
  }

  void _clearSelection() => setState(() => _selectedIds.clear());
  void _toggleSelection(String id) {
    setState(() {
      _selectedIds.contains(id)
          ? _selectedIds.remove(id)
          : _selectedIds.add(id);
    });
  }

  void _openFolder(VfsNode folder) {
    _clearSelection();
    setState(() => _pathStack.add(folder));
  }

  void _navigateToCrumb(int index) {
    _clearSelection();
    setState(() {
      _pathStack.removeRange(index + 1, _pathStack.length);
    });
  }

  bool _navigateBack() {
    if (_isSelectionMode) {
      _clearSelection();
      return false;
    }
    if (_pathStack.length > 1) {
      setState(() => _pathStack.removeLast());
      return false;
    }
    return true;
  }

  void _setProcessing(bool isProcessing, [String text = ""]) {
    setState(() {
      _isProcessing = isProcessing;
      _processText = text;
    });
  }

  void _showSnackBar(String message, Color color) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(color: Colors.white)),
          backgroundColor:
              color == const Color(0xFF00E5FF)
                  ? const Color(0xFF00BFA5)
                  : color,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // MARK: - THEMING
  ThemeData _getDarkTurquoiseTheme() {
    const Color bgGrey = Color.fromARGB(255, 0, 0, 0);
    const Color surfaceGrey = Color.fromARGB(255, 15, 18, 24);
    const Color deepTeal = Color(0xFF008B8B);
    const Color lightTeal = Color(0xFF00E5FF);

    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: bgGrey,
      primaryColor: deepTeal,
      colorScheme: const ColorScheme.dark(
        primary: deepTeal,
        onPrimary: Colors.white,
        secondary: lightTeal,
        surface: surfaceGrey,
        onSurface: Colors.white,
        primaryContainer: Color(0xFF005F5F),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF15181E),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white60,
        indicatorColor: lightTeal,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: deepTeal,
        foregroundColor: Colors.white,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF1A1D24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dividerColor: Colors.white12,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF23272A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: Colors.white10),
      ),
    );
  }

  // MARK: - BUILD MAIN
  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _getDarkTurquoiseTheme(),
      child: Builder(
        builder: (context) {
          if (_isCheckingKey) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (_needsKeySetup) return _buildKeySetupScreen(context);

          return DefaultTabController(
            length: 2,
            child: KeyboardListener(
              focusNode: _focusNode,
              onKeyEvent: (KeyEvent event) {},
              child: WillPopScope(
                onWillPop: () async => _navigateBack(),
                child: Scaffold(
                  body: Row(
                    children: [
                      _buildSidebar(context),
                      Expanded(
                        child: Scaffold(
                          appBar: _buildAppBar(context),
                          body: DropTarget(
                            onDragEntered:
                                (details) => setState(() => _isDragging = true),
                            onDragExited:
                                (details) =>
                                    setState(() => _isDragging = false),
                            onDragDone: (details) {
                              setState(() => _isDragging = false);
                              if (details.files.isNotEmpty) {
                                _processDroppedFiles(details.files);
                              }
                            },
                            child: Stack(
                              children: [
                                TabBarView(
                                  children: [
                                    _buildVfsTab(),
                                    _buildFavoritesTab(),
                                  ],
                                ),
                                if (_isDragging) _buildDragOverlay(),
                                if (!_isProcessing &&
                                    !_isSelectionMode &&
                                    !_isDragging)
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 24.0,
                                      ),
                                      child: _buildFloatingImportField(context),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          floatingActionButton:
                              _isProcessing || _isSelectionMode || _isDragging
                                  ? null
                                  : _buildFloatingActionButtons(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // MARK: - UI COMPONENTS (AppBar, Sidebar, Tabs)
  AppBar _buildAppBar(BuildContext context) {
    if (_isSelectionMode) {
      return AppBar(
        backgroundColor: const Color(0xFF004D40),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _clearSelection,
        ),
        title: Text('${_selectedIds.length} ${tr(context, 'selected')}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: tr(context, 'download'),
            onPressed:
                () => _downloadNodes(
                  _vfsManager.nodes
                      .where((n) => _selectedIds.contains(n.id))
                      .toList(),
                ),
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            tooltip: tr(context, 'delete'),
            onPressed: () => _deleteNodes(_selectedIds.toList()),
          ),
        ],
      );
    }

    final isRoot = _pathStack.length == 1;

    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: isRoot ? NavigationToolbar.kMiddleSpacing : 0,
      title:
          isRoot
              ? Text(
                tr(context, 'my_files'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              )
              : _buildAppBarBreadcrumbs(),
      centerTitle: isRoot,
      scrolledUnderElevation: 1,
      leading:
          isRoot
              ? null
              : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _navigateBack(),
              ),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: tr(context, 'trash'),
          onPressed: _isProcessing ? null : _showTrashSheet,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.language),
          tooltip: 'Language / Мова / Sprache',
          onSelected: (String langCode) {
            setState(() {
              appLocale.value = Locale(langCode);
            });
          },
          itemBuilder:
              (BuildContext context) => <PopupMenuEntry<String>>[
                _buildLanguageItem('uk', '🇺🇦', 'Українська'),
                _buildLanguageItem('en', '🇺🇸', 'English'),
                _buildLanguageItem('de', '🇩🇪', 'Deutsch'),
              ],
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.account_circle_outlined),
          tooltip: tr(context, 'profile'),
          onSelected: (value) {
            if (value == 'logout') _logout();
          },
          itemBuilder:
              (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  enabled: false,
                  child: FutureBuilder<UserData?>(
                    future: AuthStorage.getUserData(),
                    builder: (ctx, snapshot) {
                      final email =
                          snapshot.data?.email ?? (tr(context, 'loading'));
                      return Text(
                        email,
                        style: const TextStyle(color: Colors.white70),
                      );
                    },
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: 'logout',
                  child: Row(
                    children: [
                      const Icon(
                        Icons.exit_to_app,
                        color: Colors.redAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        tr(context, 'logout'),
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                  ),
                ),
              ],
        ),
        const SizedBox(width: 8),
      ],
      bottom: TabBar(
        indicatorSize: TabBarIndicatorSize.tab,
        tabs: [
          Tab(
            icon: const Icon(Icons.folder_outlined),
            text: tr(context, 'my_files'),
          ),
          Tab(
            icon: const Icon(Icons.star_border_rounded),
            text: tr(context, 'favorites'),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBarBreadcrumbs() {
    return SizedBox(
      height: kToolbarHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: _pathStack.length,
        padding: const EdgeInsets.only(right: 16),
        separatorBuilder:
            (context, index) => const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Icon(Icons.chevron_right, color: Colors.white38, size: 20),
            ),
        itemBuilder: (context, index) {
          final isLast = index == _pathStack.length - 1;
          final node = _pathStack[index];
          final String displayName =
              index == 0 ? (tr(context, 'my_cloud')) : node.name;

          final Widget content =
              index == 0
                  ? const Icon(
                    Icons.home_outlined,
                    size: 22,
                    color: Colors.white70,
                  )
                  : Text(
                    displayName,
                    style: TextStyle(
                      fontWeight: isLast ? FontWeight.bold : FontWeight.w500,
                      color: isLast ? const Color(0xFF00E5FF) : Colors.white70,
                      fontSize: 16,
                    ),
                  );

          return InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: isLast ? null : () => _navigateToCrumb(index),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: content,
            ),
          );
        },
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: const Color(0xFF15181E),
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 128.0,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.white12, width: 1),
              ),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.cloud_circle_rounded,
                  color: Color(0xFF008B8B),
                  size: 32,
                ),
                SizedBox(width: 12),
                Text(
                  'FABY Cloud',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SideFileManager(
              onFileTap: (node) {
                if (node.isFolder) {
                  _openFolder(node);
                } else {
                  _showItemOptionsSheet(node);
                }
              },
            ),
          ),
          _buildStorageStatusSidebar(context),
        ],
      ),
    );
  }

  Widget _buildStorageStatusSidebar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Builder(
        builder: (context) {
          final userData = _currentUserData;
          final limitMb = userData?.storageLimitMb ?? 500;
          final usedMb = userData?.storageUsedMb ?? 0.0;
          final percent =
              limitMb > 0 ? (usedMb / limitMb).clamp(0.0, 1.0) : 0.0;

          String sizeTextLimit =
              limitMb >= 1024
                  ? "${(limitMb / 1024).toStringAsFixed(1)} GB"
                  : "$limitMb MB";
          String sizeTextUsed =
              usedMb >= 1024
                  ? "${(usedMb / 1024).toStringAsFixed(2)} GB"
                  : "${usedMb.toStringAsFixed(1)} MB";

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(color: Colors.white10, height: 1, thickness: 1),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Icon(
                    Icons.cloud_outlined,
                    color: Colors.white70,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    tr(context, 'storage'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: percent,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Colors.white54,
                  ),
                  minHeight: 4,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "$sizeTextUsed / $sizeTextLimit",
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () async {
                    _setProcessing(true, tr(context, 'processing'));
                    try {
                      final token = await AuthStorage.getAccessToken();
                      if (token != null) {
                        final baseWebUrl = 'https://api.boardly.studio/pricing';
                        final currentLang = appLocale.value.languageCode;
                        final urlWithToken = Uri.parse(
                          '$baseWebUrl?token=$token&lang=$currentLang',
                        );
                        if (!await launchUrl(
                          urlWithToken,
                          mode: LaunchMode.externalApplication,
                        )) {
                          _showSnackBar(
                            tr(context, 'network_error'),
                            Colors.red,
                          );
                        }
                      } else {
                        _showSnackBar(tr(context, 'auth_error'), Colors.red);
                      }
                    } catch (e) {
                      _showSnackBar('${tr(context, 'error')}: $e', Colors.red);
                    } finally {
                      _setProcessing(false);
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(tr(context, 'increase_space')),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVfsTab() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_isProcessing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _processText,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final childrenNodes = _vfsManager.getChildren(_currentFolderId);
    if (childrenNodes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.folder_open_rounded,
              size: 100,
              color: Colors.white12,
            ),
            const SizedBox(height: 24),
            Text(
              tr(context, 'empty_folder'),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    childrenNodes.sort((a, b) {
      if (a.isFolder && !b.isFolder) return -1;
      if (!a.isFolder && b.isFolder) return 1;
      return a.name.compareTo(b.name);
    });

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100, top: 8),
      itemCount: childrenNodes.length,
      itemBuilder: (context, index) => _buildNodeTile(childrenNodes[index]),
    );
  }

  Widget _buildFavoritesTab() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    final favoriteNodes = _vfsManager.favoriteNodes;
    if (favoriteNodes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.star_border_rounded,
              size: 100,
              color: Colors.white12,
            ),
            const SizedBox(height: 24),
            Text(
              tr(context, 'no_favorites'),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr(context, 'fav_desc'),
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100, top: 8),
      itemCount: favoriteNodes.length,
      itemBuilder:
          (context, index) =>
              _buildNodeTile(favoriteNodes[index], isFromFavoritesTab: true),
    );
  }

  Widget _buildNodeTile(VfsNode node, {bool isFromFavoritesTab = false}) {
    final isSelected = _selectedIds.contains(node.id);
    return Container(
      color:
          isSelected
              ? const Color(0xFF004D40).withOpacity(0.4)
              : Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color:
                node.isFolder
                    ? Colors.amber.withOpacity(0.15)
                    : Theme.of(context).colorScheme.primary.withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            node.isFolder
                ? Icons.folder_rounded
                : Icons.insert_drive_file_rounded,
            color:
                node.isFolder
                    ? Colors.amber.shade400
                    : Theme.of(context).colorScheme.primary,
            size: 28,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                node.name,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 16,
                  color: Colors.white,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (node.isFavorite) ...[
              const SizedBox(width: 8),
              Icon(Icons.star, size: 18, color: Colors.amber.shade400),
            ],
            if (node.shareId != null) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: tr(context, 'access_opened_tooltip'),
                child: Icon(
                  Icons.link_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
                ),
              ),
            ],
          ],
        ),
        subtitle:
            node.isFolder
                ? null
                : Row(
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 12,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      tr(context, 'encrypted'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ],
                ),
        trailing:
            _isSelectionMode
                ? Checkbox(
                  value: isSelected,
                  onChanged: (_) => _toggleSelection(node.id),
                  activeColor: Theme.of(context).colorScheme.primary,
                  checkColor: Theme.of(context).colorScheme.onPrimary,
                )
                : IconButton(
                  icon: const Icon(Icons.more_vert, color: Colors.white54),
                  onPressed: () => _showItemOptionsSheet(node),
                ),
        onTap: () {
          if (_isSelectionMode) {
            _toggleSelection(node.id);
          } else if (node.isFolder) {
            if (isFromFavoritesTab)
              DefaultTabController.of(context)?.animateTo(0);
            _openFolder(node);
          } else {
            _showItemOptionsSheet(node);
          }
        },
        onLongPress: () {
          HapticFeedback.selectionClick();
          _toggleSelection(node.id);
        },
      ),
    );
  }

  // MARK: - UI COMPONENTS (Overlays, Floating Elements)
  Widget _buildDragOverlay() {
    return Container(
      color: const Color(0xFF15181E).withOpacity(0.85),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF008B8B).withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cloud_upload_outlined,
                size: 80,
                color: Color(0xFF00E5FF),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              tr(context, 'drop_to_upload') ?? 'Відпустіть для завантаження',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr(context, 'folders_supported') ??
                  'Підтримуються файли та цілі папки',
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingActionButtons() {
    return Builder(
      builder: (context) {
        final bool isStorageFull =
            _currentUserData != null &&
            _currentUserData!.storageUsedMb >= _currentUserData!.storageLimitMb;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton(
              heroTag: "fab_folder",
              onPressed:
                  isStorageFull
                      ? () => _showSnackBar(
                        tr(context, 'notEnoughSpace'),
                        Colors.orangeAccent,
                      )
                      : _createNewFolder,
              elevation: 3,
              backgroundColor:
                  isStorageFull
                      ? Colors.grey.shade800
                      : const Color(0xFF23272A),
              foregroundColor: isStorageFull ? Colors.white38 : null,
              child: const Icon(Icons.create_new_folder_outlined, size: 28),
            ),
            const SizedBox(width: 16),
            FloatingActionButton(
              heroTag: "fab_file",
              onPressed:
                  isStorageFull
                      ? () => _showSnackBar(
                        tr(context, 'notEnoughSpace'),
                        Colors.orangeAccent,
                      )
                      : _pickAndUploadFile,
              elevation: 3,
              backgroundColor: isStorageFull ? Colors.grey.shade800 : null,
              foregroundColor: isStorageFull ? Colors.white38 : null,
              child: const Icon(Icons.add, size: 28),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFloatingImportField(BuildContext context) {
    return Container(
      width: MediaQuery.of(context).size.width * 0.85,
      constraints: const BoxConstraints(maxWidth: 500),
      height: 56,
      decoration: BoxDecoration(
        color: const Color(0xFF15181E).withOpacity(0.9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: const Color(0xFF00E5FF).withOpacity(0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withOpacity(0.1),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: TextField(
          controller: _importLinkController,
          style: const TextStyle(color: Colors.white, fontSize: 15),
          cursorColor: const Color(0xFF00E5FF),
          decoration: InputDecoration(
            hintText: tr(context, 'import_hint'),
            hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
            prefixIcon: const Icon(
              Icons.link_rounded,
              color: Color(0xFF00E5FF),
              size: 22,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            suffixIcon: Container(
              margin: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                color: Color(0xFF008B8B),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                onPressed: () {
                  if (_importLinkController.text.isNotEmpty)
                    _processImportLink(_importLinkController.text.trim());
                },
              ),
            ),
          ),
          onSubmitted: (value) {
            if (value.isNotEmpty) _processImportLink(value.trim());
          },
        ),
      ),
    );
  }

  PopupMenuItem<String> _buildLanguageItem(
    String code,
    String flag,
    String name,
  ) {
    final bool isSelected = appLocale.value.languageCode == code;
    return PopupMenuItem<String>(
      value: code,
      child: Row(
        children: [
          Text(flag, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Text(
            name,
            style: TextStyle(
              color: isSelected ? const Color(0xFF00E5FF) : Colors.white,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (isSelected) ...[
            const Spacer(),
            const Icon(Icons.check, size: 16, color: Color(0xFF00E5FF)),
          ],
        ],
      ),
    );
  }

  // MARK: - UI COMPONENTS (Dialogs & Sheets)
  void _showTrashSheet() async {
    _setProcessing(true, tr(context, 'processing'));
    final trashData = await _getTrashItems();
    _setProcessing(false);

    if (trashData == null) {
      _showSnackBar(tr(context, 'error'), Colors.redAccent);
      return;
    }

    final rawFiles = List<Map<String, dynamic>>.from(trashData['files'] ?? []);
    final rawNodes = List<Map<String, dynamic>>.from(trashData['nodes'] ?? []);
    final Map<String, Map<String, dynamic>> logicalItems = {};

    for (var node in rawNodes) {
      logicalItems[node['id']] = {
        'id': node['id'],
        'deleted_at': node['deleted_at'],
        'has_node': true,
        'has_file': false,
      };
    }
    for (var file in rawFiles) {
      final id = file['id'];
      if (logicalItems.containsKey(id)) {
        logicalItems[id]!['has_file'] = true;
      } else {
        logicalItems[id] = {
          'id': id,
          'deleted_at': file['deleted_at'],
          'has_node': false,
          'has_file': true,
        };
      }
    }

    final allItems = logicalItems.values.toList();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1D24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 0.8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.delete_sweep_outlined,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${tr(context, 'trash')} (${allItems.length})\n${tr(context, 'trash_desc')}',
                      style: const TextStyle(
                        fontSize: 20,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              Expanded(
                child:
                    allItems.isEmpty
                        ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.auto_delete_outlined,
                                size: 64,
                                color: Colors.white10,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                tr(context, 'trash_empty'),
                                style: const TextStyle(color: Colors.white38),
                              ),
                            ],
                          ),
                        )
                        : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: allItems.length,
                          itemBuilder:
                              (context, index) =>
                                  _buildTrashTile(allItems[index]),
                        ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTrashTile(Map<String, dynamic> item) {
    final dateStr =
        item['deleted_at']?.toString().split('T').first ?? 'Unknown';
    final isJustNode = item['has_node'] == true && item['has_file'] == false;

    return ListTile(
      leading: Icon(
        isJustNode
            ? Icons.folder_delete_outlined
            : Icons.insert_drive_file_outlined,
        color: Colors.white54,
      ),
      title: Text(
        item['id'] ?? 'Unknown',
        style: const TextStyle(color: Colors.white, fontSize: 14),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${tr(context, 'deleted_on')} $dateStr',
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.restore, color: Color(0xFF00E5FF)),
        tooltip: tr(context, 'restore'),
        onPressed: () async {
          Navigator.pop(context);
          _setProcessing(true, tr(context, 'processing'));
          bool success = true;
          if (item['has_node'] == true)
            success = success && await _restoreTrashItem('node', item['id']);
          if (item['has_file'] == true)
            success = success && await _restoreTrashItem('file', item['id']);
          _setProcessing(false);

          if (success) {
            _showSnackBar(
              tr(context, 'success_restore'),
              const Color(0xFF00BFA5),
            );
            await _loadInitialData();
            _refreshUserDataFromServer();
          } else {
            _showSnackBar(tr(context, 'restore_error'), Colors.orangeAccent);
          }
        },
      ),
    );
  }

  void _showItemOptionsSheet(VfsNode node) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1D24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder:
          (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          node.isFolder
                              ? Icons.folder
                              : Icons.insert_drive_file,
                          color:
                              node.isFolder
                                  ? Colors.amber.shade400
                                  : const Color(0xFF00E5FF),
                          size: 32,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            node.name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 24),
                  ListTile(
                    leading: Icon(
                      node.isFavorite ? Icons.star : Icons.star_border,
                      color: Colors.amber.shade400,
                    ),
                    title: Text(
                      node.isFavorite
                          ? (tr(context, 'remove_fav'))
                          : (tr(context, 'add_fav')),
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      await _vfsManager.toggleFavorite(node.id);
                      setState(() {});
                    },
                  ),
                  if (!node.isFolder)
                    ListTile(
                      leading: const Icon(
                        Icons.download,
                        color: Color(0xFF00E5FF),
                      ),
                      title: Text(
                        tr(context, 'download'),
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _downloadNodes([node]);
                      },
                    ),
                  ListTile(
                    leading: const Icon(
                      Icons.share_rounded,
                      color: Color(0xFF00BFA5),
                    ),
                    title: Text(
                      tr(context, 'share'),
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      if (node.shareId != null) {
                        _showAccessManagerDialog(node);
                      } else {
                        _shareNode(node);
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                    ),
                    title: Text(
                      tr(context, 'delete'),
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _deleteNodes([node.id]);
                    },
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Future<void> _showAccessManagerDialog(VfsNode node) async {
    String rawShareKey = "error_key";
    try {
      final userMasterKey = await _secureStorage.read(key: 'user_master_key');
      if (userMasterKey != null && node.encryptedShareKey != null) {
        rawShareKey = await _encryption.decryptTextWithKey(
          node.encryptedShareKey!,
          userMasterKey,
        );
      }
    } catch (e) {}

    final shareType = node.isFolder ? 'folder/' : '';
    final encodedName = Uri.encodeComponent(node.name);
    final encodedKey = Uri.encodeComponent(rawShareKey);
    final currentLink =
        'https://boardly.studio/share/$shareType${node.shareId}#name=$encodedName&key=$encodedKey';

    if (!mounted) return;

    await showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1A1D24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              tr(context, 'access_management'),
              style: const TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'object_available_at'),
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF23272A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: SelectableText(
                    currentLink,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF00E5FF),
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  tr(context, 'regenerate_warning'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.orangeAccent,
                  ),
                ),
              ],
            ),
            actionsAlignment: MainAxisAlignment.spaceBetween,
            actions: [
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(context);
                  _setProcessing(true, tr(context, 'removing_access'));
                  try {
                    final success = await _storageService.deleteShareLink(
                      node.shareId!,
                    );
                    if (success) {
                      await _vfsManager.updateNodeShareData(
                        node.id,
                        null,
                        null,
                      );
                      await _silentRefresh();
                      _showSnackBar(
                        tr(context, 'access_closed'),
                        Colors.white54,
                      );
                    }
                  } catch (e) {
                    _showSnackBar(
                      '${tr(context, 'error')}: $e',
                      Colors.redAccent,
                    );
                  } finally {
                    _setProcessing(false);
                  }
                },
                icon: const Icon(
                  Icons.link_off,
                  color: Colors.redAccent,
                  size: 18,
                ),
                label: Text(
                  tr(context, 'delete'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF008B8B),
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  Navigator.pop(context);
                  _setProcessing(true, tr(context, 'updating_link'));
                  try {
                    await _storageService.deleteShareLink(node.shareId!);
                    await _vfsManager.updateNodeShareData(node.id, null, null);
                    _setProcessing(false);
                    await _shareNode(node);
                  } catch (e) {
                    _setProcessing(false);
                    _showSnackBar(
                      '${tr(context, 'update_error')} $e',
                      Colors.redAccent,
                    );
                  }
                },
                icon: const Icon(Icons.autorenew, size: 18),
                label: Text(tr(context, 'update_btn')),
              ),
            ],
          ),
    );
  }

  Future<bool?> _showImportConfirmationDialog(
    String name,
    int size, {
    List<String>? files,
  }) async {
    final double sizeInMb = size / (1024 * 1024);
    return showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1A1D24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                const Icon(
                  Icons.cloud_download_outlined,
                  color: Color(0xFF00E5FF),
                ),
                const SizedBox(width: 12),
                Text(tr(context, 'import_confirm')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "${tr(context, 'file_name')}: $name",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "${tr(context, 'size')}: ${sizeInMb.toStringAsFixed(2)} MB",
                  style: const TextStyle(color: Colors.white70),
                ),
                if (files != null && files.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    tr(context, 'folder_content'),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    width: double.infinity,
                    child: ListView(
                      shrinkWrap: true,
                      children:
                          files
                              .map(
                                (f) => Text(
                                  "• $f",
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  tr(context, 'import_warn'),
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  tr(context, 'cancel'),
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF008B8B),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr(context, 'import_btn')),
              ),
            ],
          ),
    );
  }

  void _showFolderPreviewDialog(
    String shareId,
    String folderName,
    List<Map<String, dynamic>> files,
    String folderKey,
  ) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1A1D24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                const Icon(Icons.folder_shared, color: Color(0xFF00E5FF)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${tr(context, 'import_title')} $folderName',
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${tr(context, 'files_in_folder')} ${files.length}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF23272A),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: files.length,
                        separatorBuilder:
                            (_, __) =>
                                const Divider(color: Colors.white12, height: 1),
                        itemBuilder: (context, i) {
                          final file = files[i];
                          return ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.insert_drive_file_outlined,
                              color: Colors.white54,
                              size: 20,
                            ),
                            title: Text(
                              file['name'],
                              style: const TextStyle(color: Colors.white),
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.download,
                                color: Color(0xFF00E5FF),
                                size: 20,
                              ),
                              tooltip: tr(context, 'import_single_file'),
                              onPressed: () {
                                Navigator.pop(context);
                                _executeSingleFileFromFolderImport(
                                  shareId,
                                  file,
                                  folderName,
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  tr(context, 'cancel'),
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF008B8B),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.download_done, size: 18),
                label: Text(tr(context, 'import_all')),
                onPressed: () {
                  Navigator.pop(context);
                  _executeFolderImport(shareId, folderName, files, folderKey);
                },
              ),
            ],
          ),
    );
  }

  // MARK: - UI COMPONENTS (Vault Setup Screens)
  Widget _buildKeySetupScreen(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child:
                  _isProcessing
                      ? _buildProcessingState(colorScheme)
                      : _showCreateFlow
                      ? _buildCreateFlow(colorScheme)
                      : _showRecoverFlow
                      ? _buildRecoverFlow(colorScheme)
                      : _buildInitialSetupChoice(colorScheme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInitialSetupChoice(ColorScheme colorScheme) {
    return Padding(
      key: const ValueKey('initial'),
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.security_rounded, size: 80, color: colorScheme.primary),
          const SizedBox(height: 24),
          Text(
            tr(context, 'privacy_setup'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr(context, 'privacy_desc'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              color: Colors.white70,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 48),
          ElevatedButton.icon(
            onPressed: _startCreateVaultFlow,
            icon: const Icon(Icons.add_circle_outline_rounded, size: 24),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                tr(context, 'create_vault'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              elevation: 4,
              shadowColor: colorScheme.primary.withOpacity(0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => setState(() => _showRecoverFlow = true),
            icon: const Icon(Icons.restore_rounded, size: 24),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                tr(context, 'have_phrase'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.primary,
              side: BorderSide(
                color: colorScheme.primary.withOpacity(0.5),
                width: 1.5,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateFlow(ColorScheme colorScheme) {
    return Padding(
      key: const ValueKey('create'),
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => setState(() => _showCreateFlow = false),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr(context, 'secret_phrase'),
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orangeAccent.withOpacity(0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orangeAccent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr(context, 'secret_warn'),
                    style: TextStyle(
                      color: Colors.orangeAccent.shade100,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF15181E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 2.5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: _generatedMnemonic.length,
              itemBuilder: (context, index) {
                return Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF23272A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '${index + 1}. ',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 13,
                          ),
                        ),
                        TextSpan(
                          text: _generatedMnemonic[index],
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: _generatedMnemonic.join(' ')),
              );
              _showSnackBar(
                tr(context, 'phrase_copied'),
                const Color(0xFF00BFA5),
              );
            },
            icon: Icon(
              Icons.copy_rounded,
              size: 20,
              color: colorScheme.primary,
            ),
            label: Text(
              tr(context, 'copy_phrase'),
              style: TextStyle(color: colorScheme.primary, fontSize: 16),
            ),
          ),
          const SizedBox(height: 16),
          Theme(
            data: Theme.of(
              context,
            ).copyWith(unselectedWidgetColor: Colors.white54),
            child: CheckboxListTile(
              value: _hasSavedMnemonic,
              onChanged:
                  (val) => setState(() => _hasSavedMnemonic = val ?? false),
              title: Text(
                tr(context, 'saved_phrase_check'),
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              activeColor: colorScheme.primary,
              checkColor: colorScheme.onPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _hasSavedMnemonic ? _confirmAndCreateVault : null,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              disabledBackgroundColor: Colors.white12,
              disabledForegroundColor: Colors.white38,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              tr(context, 'create_my_vault'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecoverFlow(ColorScheme colorScheme) {
    return Padding(
      key: const ValueKey('recover'),
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () {
                setState(() {
                  _showRecoverFlow = false;
                  _recoveryController.clear();
                });
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr(context, 'restore_access'),
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tr(context, 'enter_words'),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 15,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _recoveryController,
            maxLines: 4,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: tr(context, 'phrase_example'),
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: const Color(0xFF23272A),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colorScheme.primary, width: 2),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _recoveryController,
            builder: (context, value, child) {
              final words =
                  value.text
                      .trim()
                      .split(RegExp(r'\s+'))
                      .where((w) => w.isNotEmpty)
                      .toList();
              final isComplete = words.length == 12;
              final isOver = words.length > 12;

              return Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '${tr(context, 'words_count')} ${words.length}/12',
                    style: TextStyle(
                      color:
                          isComplete
                              ? const Color(0xFF00BFA5)
                              : (isOver ? Colors.redAccent : Colors.white54),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 32),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _recoveryController,
            builder: (context, value, child) {
              final words =
                  value.text
                      .trim()
                      .split(RegExp(r'\s+'))
                      .where((w) => w.isNotEmpty)
                      .toList();
              final isValid = words.length == 12;
              return ElevatedButton.icon(
                onPressed: isValid ? _recoverVault : null,
                icon: const Icon(Icons.lock_open_rounded),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    tr(context, 'unlock'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  disabledBackgroundColor: Colors.white12,
                  disabledForegroundColor: Colors.white38,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildProcessingState(ColorScheme colorScheme) {
    return Padding(
      key: const ValueKey('processing'),
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: colorScheme.primary),
          const SizedBox(height: 24),
          Text(
            _processText,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
