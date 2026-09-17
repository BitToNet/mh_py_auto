import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';

const int version = 1001002;
const String versionCode = "1.1.2";
class EncryptUtil {
  static final EncryptUtil _encryptUtil = EncryptUtil._internal();


  EncryptUtil._internal();

  factory EncryptUtil() => _encryptUtil;

  Key? _aesKey;

  init() {
    _aesKey ??= Key(Uint8List.fromList(List.generate(16, (index) => 0)));
    // _aesKey ??= Key(Uint8List.fromList("1234567890abcdef".codeUnits.toList()));
  }

  String encrypt(String data) {
    init();
    final encrypter = Encrypter(AES(_aesKey!, mode: AESMode.cbc));
    final encrypted = encrypter.encrypt(data, iv: IV(_aesKey!.bytes));
    return encrypted.base64;
  }

  Future<Uint8List> encryptBytes(List<int> data) async {
    init();
    final encrypter = Encrypter(AES(_aesKey!, mode: AESMode.cbc));
    final encrypted = encrypter.encryptBytes(data, iv: IV(_aesKey!.bytes));
    return encrypted.bytes;
  }

  String decrypt(String data) {
    init();
    final encrypter = Encrypter(AES(_aesKey!, mode: AESMode.cbc));
    final decrypted =
        encrypter.decrypt(Encrypted.fromBase64(data), iv: IV(_aesKey!.bytes));
    return decrypted;
  }

  Future<String> decryptFile(String encryptedFilePath) async {
    try {
      // 1. 读取加密文件内容
      final encryptedFile = File(encryptedFilePath);
      if (!await encryptedFile.exists()) {
        throw Exception("加密文件不存在：$encryptedFilePath");
      }
      String encryptedData = await encryptedFile.readAsString();

      String decryptedContent = decrypt(encryptedData);

      print("文件解密成功");
      return decryptedContent;
    } catch (e) {
      print("文件解密失败：$e");
      rethrow;
    }
  }
  Future<void> encryptFile(String originalContent, String encryptedFilePath) async {
    try {
      // 5. 加密内容
      final encrypted = encrypt(originalContent);

      final encryptedFile = File(encryptedFilePath);
      await encryptedFile.writeAsString(encrypted);

      print("文件加密成功，保存路径：$encryptedFilePath");
    } catch (e) {
      print("文件加密失败：$e");
      rethrow;
    }
  }
}
