import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';

class EncryptionService {
  // MARK: - CONSTANTS & CONFIG
  final _storage = const FlutterSecureStorage();
  static const _keyAlias = 'boardly_cloud_aes_key';

  static const int _nonceLength = 12;
  static const int _macLength = 16;
  static const int _overhead = _nonceLength + _macLength;
  static const int _chunkSize = 5 * 1024 * 1024;

  final _algorithm = AesGcm.with256bits();

  // MARK: - KEY GENERATION & MANAGEMENT
  Future<String> deriveKeyFromPassphrase(
    String mnemonic,
    String saltString,
  ) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    final secretKey = SecretKey(utf8.encode(mnemonic));
    final nonce = utf8.encode(saltString);
    final derivedKey = await pbkdf2.deriveKey(
      secretKey: secretKey,
      nonce: nonce,
    );
    final bytes = await derivedKey.extractBytes();
    return base64Encode(bytes);
  }

  Future<SecretKey> _getKey() async {
    String? base64Key = await _storage.read(key: _keyAlias);
    if (base64Key == null) {
      base64Key = generateRandomKey();
      await _storage.write(key: _keyAlias, value: base64Key);
    }
    return SecretKey(base64Decode(base64Key));
  }

  String generateRandomKey() {
    final random = Random.secure();
    final bytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Encode(bytes);
  }

  Future<String> getUserKey() async {
    final key = await _getKey();
    final bytes = await key.extractBytes();
    return base64Encode(bytes);
  }

  // MARK: - IN-MEMORY ENCRYPTION (SMALL DATA)
  Future<Uint8List> _encryptWithKey(List<int> data, SecretKey key) async {
    final nonce = _algorithm.newNonce();
    final secretBox = await _algorithm.encrypt(
      data,
      secretKey: key,
      nonce: nonce,
    );

    final result = BytesBuilder();
    result.add(secretBox.nonce);
    result.add(secretBox.cipherText);
    result.add(secretBox.mac.bytes);
    return result.toBytes();
  }

  Future<Uint8List> _decryptWithKey(
    List<int> encryptedData,
    SecretKey key,
  ) async {
    if (encryptedData.length < _overhead) throw Exception('Data too short');

    final nonce = encryptedData.sublist(0, _nonceLength);
    final mac = encryptedData.sublist(encryptedData.length - _macLength);
    final cipherText = encryptedData.sublist(
      _nonceLength,
      encryptedData.length - _macLength,
    );

    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final decryptedText = await _algorithm.decrypt(secretBox, secretKey: key);
    return Uint8List.fromList(decryptedText);
  }

  Future<Uint8List> encryptData(List<int> data) async =>
      _encryptWithKey(data, await _getKey());
  Future<Uint8List> decryptData(List<int> encryptedData) async =>
      _decryptWithKey(encryptedData, await _getKey());
  Future<String> encryptText(String text) async =>
      base64Encode(await encryptData(utf8.encode(text)));
  Future<String> decryptText(String encryptedBase64) async =>
      utf8.decode(await decryptData(base64Decode(encryptedBase64)));

  Future<String> encryptTextWithKey(String text, String base64Key) async {
    return base64Encode(
      await _encryptWithKey(
        utf8.encode(text),
        SecretKey(base64Decode(base64Key)),
      ),
    );
  }

  Future<String> decryptTextWithKey(
    String encryptedBase64,
    String base64Key,
  ) async {
    final decrypted = await _decryptWithKey(
      base64Decode(encryptedBase64),
      SecretKey(base64Decode(base64Key)),
    );
    return utf8.decode(decrypted);
  }

  Future<Uint8List> encryptDataWithKey(List<int> data, String base64Key) async {
    return _encryptWithKey(data, SecretKey(base64Decode(base64Key)));
  }

  Future<Uint8List> decryptDataWithKey(
    List<int> encryptedData,
    String base64Key,
  ) async {
    return _decryptWithKey(encryptedData, SecretKey(base64Decode(base64Key)));
  }

  // MARK: - STREAM ENCRYPTION (LARGE FILES)
  int calculateEncryptedSize(int originalSize) {
    if (originalSize == 0) return _overhead;
    int fullChunks = originalSize ~/ _chunkSize;
    int remainder = originalSize % _chunkSize;
    int totalSize = fullChunks * (_chunkSize + _overhead);
    if (remainder > 0) totalSize += (remainder + _overhead);
    return totalSize;
  }

  Stream<List<int>> encryptStreamWithKey(
    Stream<List<int>> inputStream,
    String base64Key,
  ) async* {
    final secretKey = SecretKey(base64Decode(base64Key));
    var builder = BytesBuilder(copy: false);

    await for (final chunk in inputStream) {
      builder.add(chunk);

      while (builder.length >= _chunkSize) {
        final allBytes = builder.takeBytes();
        final block = allBytes.sublist(0, _chunkSize);
        final remainder = allBytes.sublist(_chunkSize);

        final nonce = _algorithm.newNonce();
        final secretBox = await _algorithm.encrypt(
          block,
          secretKey: secretKey,
          nonce: nonce,
        );

        yield nonce;
        yield secretBox.cipherText;
        yield secretBox.mac.bytes;

        builder.add(remainder);
      }
    }

    if (builder.isNotEmpty) {
      final finalBlock = builder.takeBytes();
      final nonce = _algorithm.newNonce();
      final secretBox = await _algorithm.encrypt(
        finalBlock,
        secretKey: secretKey,
        nonce: nonce,
      );

      yield nonce;
      yield secretBox.cipherText;
      yield secretBox.mac.bytes;
    }
  }

  Stream<List<int>> decryptStreamWithKey(
    Stream<List<int>> inputStream,
    String base64Key,
  ) async* {
    final secretKey = SecretKey(base64Decode(base64Key));
    final int encryptedChunkSize = _chunkSize + _overhead;
    List<int> buffer = [];

    await for (final chunk in inputStream) {
      buffer.addAll(chunk);
      while (buffer.length >= encryptedChunkSize) {
        final block = buffer.sublist(0, encryptedChunkSize);
        buffer = buffer.sublist(encryptedChunkSize);

        final nonce = block.sublist(0, _nonceLength);
        final mac = block.sublist(block.length - _macLength);
        final cipherText = block.sublist(
          _nonceLength,
          block.length - _macLength,
        );

        final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
        yield await _algorithm.decrypt(secretBox, secretKey: secretKey);
      }
    }

    if (buffer.isNotEmpty) {
      if (buffer.length < _overhead) throw Exception('Corrupted stream');
      final nonce = buffer.sublist(0, _nonceLength);
      final mac = buffer.sublist(buffer.length - _macLength);
      final cipherText = buffer.sublist(
        _nonceLength,
        buffer.length - _macLength,
      );

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
      yield await _algorithm.decrypt(secretBox, secretKey: secretKey);
    }
  }
}
