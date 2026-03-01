import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:boardly_cloud/services/auth_http_client.dart';
import 'package:boardly_cloud/services/encryption_service.dart';

class CloudflareStorageService {
  // MARK: - DEPENDENCIES & CONFIG
  static const String _baseUrl = 'https://api.boardly.studio/storage';
  final _encryptionService = EncryptionService();
  final _uuid = const Uuid();
  final _authClient = AuthHttpClient();

  // MARK: - FILE UPLOAD (BLOBS & MULTIPART)
  Future<bool> uploadFile(String fileId, File file) async {
    try {
      final rawBytes = await file.readAsBytes();
      final encryptedBytes = await _encryptionService.encryptData(rawBytes);

      final response = await _authClient.request(
        Uri.parse('$_baseUrl/file/upload-url'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'file_id': fileId}),
      );

      if (response.statusCode != 200) return false;
      final uploadUrl = jsonDecode(response.body)['upload_url'];

      final uploadResponse = await http.put(
        Uri.parse(uploadUrl),
        body: encryptedBytes,
      );
      return uploadResponse.statusCode == 200;
    } catch (e) {
      print('[EXCEPTION] Blob Upload: $e');
      return false;
    }
  }

  Future<bool> uploadStream(
    String fileId,
    int contentLength,
    Stream<List<int>> byteStream,
  ) async {
    const int multipartThreshold = 100 * 1024 * 1024;

    if (contentLength > multipartThreshold) {
      return await _uploadMultipart(fileId, contentLength, byteStream);
    } else {
      return await _uploadSingle(fileId, contentLength, byteStream);
    }
  }

  Future<bool> _uploadSingle(
    String fileId,
    int contentLength,
    Stream<List<int>> byteStream,
  ) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/file/upload-url'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'file_id': fileId}),
      );

      if (response.statusCode != 200) return false;
      final uploadUrl = jsonDecode(response.body)['upload_url'];

      var request = http.StreamedRequest('PUT', Uri.parse(uploadUrl));
      request.contentLength = contentLength;

      byteStream.listen(
        (chunk) => request.sink.add(chunk),
        onDone: () => request.sink.close(),
        onError: (e) => request.sink.addError(e),
      );

      final streamedResponse = await request.send();
      return streamedResponse.statusCode == 200;
    } catch (e) {
      print('[EXCEPTION] Single Stream Upload: $e');
      return false;
    }
  }

  Future<bool> _uploadMultipart(
    String fileId,
    int contentLength,
    Stream<List<int>> byteStream,
  ) async {
    try {
      const int chunkSize = 50 * 1024 * 1024;
      int partsCount = (contentLength / chunkSize).ceil();

      final initRes = await _authClient.request(
        Uri.parse('$_baseUrl/file/multipart/initiate'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'file_id': fileId}),
      );
      if (initRes.statusCode != 200)
        throw Exception('Failed to initiate Multipart');

      final uploadId = jsonDecode(initRes.body)['upload_id'];

      final urlsRes = await _authClient.request(
        Uri.parse('$_baseUrl/file/multipart/presigned-urls'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'file_id': fileId,
          'upload_id': uploadId,
          'parts_count': partsCount,
        }),
      );
      if (urlsRes.statusCode != 200)
        throw Exception('Failed to get chunk URLs');

      final urlsData = jsonDecode(urlsRes.body)['urls'] as List;
      Map<int, String> partUrls = {
        for (var item in urlsData) item['part_number']: item['upload_url'],
      };

      List<Map<String, dynamic>> uploadedParts = [];
      int currentPart = 1;
      BytesBuilder chunkBuilder = BytesBuilder();

      await for (var chunk in byteStream) {
        chunkBuilder.add(chunk);

        if (chunkBuilder.length >= chunkSize) {
          final fullBytes = chunkBuilder.toBytes();
          final bytesToUpload = fullBytes.sublist(0, chunkSize);
          final remainder = fullBytes.sublist(chunkSize);

          final eTag = await _uploadChunkPut(
            partUrls[currentPart]!,
            bytesToUpload,
          );
          if (eTag == null)
            throw Exception('Error uploading part $currentPart');

          uploadedParts.add({"PartNumber": currentPart, "ETag": eTag});
          currentPart++;

          chunkBuilder = BytesBuilder();
          chunkBuilder.add(remainder);
        }
      }

      if (chunkBuilder.isNotEmpty) {
        final eTag = await _uploadChunkPut(
          partUrls[currentPart]!,
          chunkBuilder.toBytes(),
        );
        if (eTag == null) throw Exception('Error uploading final part');
        uploadedParts.add({"PartNumber": currentPart, "ETag": eTag});
      }

      final compRes = await _authClient.request(
        Uri.parse('$_baseUrl/file/multipart/complete'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'file_id': fileId,
          'upload_id': uploadId,
          'parts': uploadedParts,
        }),
      );

      return compRes.statusCode == 200;
    } catch (e) {
      print('[EXCEPTION] Multipart Upload: $e');
      return false;
    }
  }

  Future<String?> _uploadChunkPut(String url, Uint8List bytes) async {
    final request = http.Request('PUT', Uri.parse(url));
    request.bodyBytes = bytes;
    final response = await request.send();
    if (response.statusCode == 200) {
      return response.headers['etag']?.replaceAll('"', '');
    }
    return null;
  }

  // MARK: - FILE MANAGEMENT (DOWNLOAD, DELETE, CONFIRM)
  Future<String?> getFileDownloadUrl(String fileId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/file/download-url'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'file_id': fileId}),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body)['download_url'];
      }
      return null;
    } catch (e) {
      print('[EXCEPTION] Blob URL: $e');
      return null;
    }
  }

  Future<bool> deleteFile(String fileId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/file/$fileId'),
        method: 'DELETE',
        headers: {'Content-Type': 'application/json'},
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<bool> confirmFileUpload(String fileId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/file/confirm-upload'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'file_id': fileId}),
      );

      return response.statusCode == 200;
    } catch (e) {
      print('[EXCEPTION] Confirm File Upload: $e');
      return false;
    }
  }

  // MARK: - VFS NODES (JSON)
  Future<List<Map<String, dynamic>>> getCloudNodesMeta() async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/nodes/list'),
        method: 'GET',
      );
      if (response.statusCode == 200) {
        final List<dynamic> nodes = jsonDecode(response.body)['nodes'];
        return nodes.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<bool> uploadNodeJson(
    String nodeId,
    Map<String, dynamic> nodeData, {
    String? expectedEtag,
  }) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/node/upload-url'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'node_id': nodeId}),
      );

      if (response.statusCode == 200) {
        final uploadUrl = jsonDecode(response.body)['upload_url'];
        final encryptedNode = await _encryptionService.encryptText(
          jsonEncode(nodeData),
        );

        final headers = <String, String>{};
        if (expectedEtag != null && expectedEtag != 'pending_sync') {
          headers['If-Match'] = expectedEtag;
        }

        final uploadResponse = await http.put(
          Uri.parse(uploadUrl),
          headers: headers.isEmpty ? null : headers,
          body: encryptedNode,
        );

        if (uploadResponse.statusCode == 412) return false;

        return uploadResponse.statusCode == 200;
      }
      return false;
    } catch (e) {
      print('[EXCEPTION] Node Upload: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> downloadNodeJson(String nodeId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/node/download-url'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'node_id': nodeId}),
      );

      if (response.statusCode == 200) {
        final downloadUrl = jsonDecode(response.body)['download_url'];
        final fetchResponse = await http.get(Uri.parse(downloadUrl));

        if (fetchResponse.statusCode == 200) {
          final decryptedText = await _encryptionService.decryptText(
            fetchResponse.body,
          );
          return jsonDecode(decryptedText);
        }
      }
      return null;
    } catch (e) {
      print('[EXCEPTION] Node Download: $e');
      return null;
    }
  }

  Future<bool> deleteNode(String nodeId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/node/$nodeId'),
        method: 'DELETE',
        headers: {'Content-Type': 'application/json'},
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // MARK: - SHARING (LINKS & FOLDERS)
  Future<Map<String, dynamic>?> getSharedFileMetadataAndUrl(
    String shareId,
  ) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/share/download/$shareId'),
        method: 'GET',
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      return null;
    } catch (e) {
      print('[EXCEPTION] Shared File Download: $e');
      return null;
    }
  }

  Future<bool> uploadBytes(String fileId, Uint8List encryptedBytes) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/file/upload-url'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'file_id': fileId}),
      );

      if (response.statusCode != 200) return false;
      final uploadUrl = jsonDecode(response.body)['upload_url'];

      final uploadResponse = await http.put(
        Uri.parse(uploadUrl),
        body: encryptedBytes,
      );
      return uploadResponse.statusCode == 200;
    } catch (e) {
      print('[EXCEPTION] Upload Bytes: $e');
      return false;
    }
  }

  Future<String?> createShareLink(String fileId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/share/create'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'file_id': fileId}),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body)['share_id'];
      }
      return null;
    } catch (e) {
      print('[EXCEPTION] Create Share Link: $e');
      return null;
    }
  }

  Future<bool> deleteShareLink(String shareId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/share/$shareId'),
        method: 'DELETE',
        headers: {'Content-Type': 'application/json'},
      );
      return response.statusCode == 200 || response.statusCode == 404;
    } catch (e) {
      print('[EXCEPTION] Delete Share Link: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> getSharedFolderManifestUrl(
    String shareId,
  ) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/share/folder/$shareId/manifest'),
        method: 'GET',
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      return null;
    } catch (e) {
      print('[EXCEPTION] Shared Folder Manifest: $e');
      return null;
    }
  }

  Future<String?> getSharedFolderFileUrl(String shareId, String fileId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/share/folder/$shareId/file/$fileId'),
        method: 'GET',
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body)['download_url'];
      }
      return null;
    } catch (e) {
      print('[EXCEPTION] Shared Folder File URL: $e');
      return null;
    }
  }

  Future<String?> createFolderShareLink(
    String manifestId,
    String folderName,
    List<String> fileIds,
  ) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/share/folder/create'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'manifest_id': manifestId,
          'folder_name': folderName,
          'file_ids': fileIds,
        }),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body)['share_id'];
      }
      return null;
    } catch (e) {
      print('[EXCEPTION] Create Folder Share Link: $e');
      return null;
    }
  }

  // MARK: - SYSTEM RECOVERY
  Future<String> getRecoveryUploadUrl() async {
    final response = await _authClient.request(
      Uri.parse('$_baseUrl/system/recovery/upload-url'),
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body)['upload_url'];
    } else {
      throw Exception(
        'Failed to get recovery upload URL: ${response.statusCode}',
      );
    }
  }

  Future<String> getRecoveryDownloadUrl() async {
    final response = await _authClient.request(
      Uri.parse('$_baseUrl/system/recovery/download-url'),
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body)['download_url'];
    } else if (response.statusCode == 404) {
      throw Exception(
        'Сховище не знайдено. Переконайся, що ти вже створював його раніше.',
      );
    } else {
      throw Exception(
        'Failed to get recovery download URL: ${response.statusCode}',
      );
    }
  }

  // MARK: - TRASH
  Future<Map<String, dynamic>?> getTrashItems() async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/system/recovery/list-trash'),
        method: 'GET',
      );

      if (response.statusCode == 200) return jsonDecode(response.body);
      return null;
    } catch (e) {
      print('[EXCEPTION] Get Trash: $e');
      return null;
    }
  }

  Future<bool> restoreFromTrash(String itemType, String itemId) async {
    try {
      final response = await _authClient.request(
        Uri.parse('$_baseUrl/system/recovery/restore-trash'),
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'item_type': itemType, 'item_id': itemId}),
      );

      return response.statusCode == 200 ||
          (itemType == 'file' && response.statusCode == 404);
    } catch (e) {
      print('[EXCEPTION] Restore Trash: $e');
      return false;
    }
  }
}
