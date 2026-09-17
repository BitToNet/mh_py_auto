import 'dart:io';
import 'package:path/path.dart' as path; // 需添加 path 依赖

class FileUtils {
  static final FileUtils _util = FileUtils._internal();


  FileUtils._internal();

  factory FileUtils() => _util;

  /// 删除指定路径的文件（适配 Windows 平台）
  Future<bool> deleteTargetFile() async {
    // 1. 定义目标文件路径（Windows 路径处理：要么用双反斜杠，要么用原始字符串 r''）
    final String filePath =
        r'C:\flutter\py_auto\build\windows\x64\runner\Release\data\flutter_assets\scripts\phone_click_simulator_more.py';
    final File targetFile = File(filePath);

    try {
      // 2. 先检查文件是否存在
      if (await targetFile.exists()) {
        // 3. 删除文件
        await targetFile.delete();
        print("文件删除成功：$filePath");
        return true;
      } else {
        print("文件不存在，无需删除");
        return false;
      }
    } catch (e) {
      // 4. 捕获删除失败的异常（如权限不足、文件被占用等）
      print("文件删除失败：$e");
      return false;
    }
  }

  /// 复制源目录下的所有文件到目标目录（适配 Windows 平台）
  /// [sourceDirPath] 源目录路径
  /// [targetDirPath] 目标目录路径
  /// [includeSubDir] 是否复制子目录中的文件（默认 true）
  Future<bool> copyDirectoryFiles({
    required String sourceDirPath,
    required String targetDirPath,
    bool includeSubDir = true,
  }) async {

    final Directory sourceDir = Directory(sourceDirPath);
    final Directory targetDir = Directory(targetDirPath);

    try {
      // 1. 检查源目录是否存在
      if (!await sourceDir.exists()) {
        print("源目录不存在：$sourceDirPath");
        return false;
      }

      // 2. 目标目录不存在则创建
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true); // recursive: true 支持创建多级目录
        print("目标目录已创建：$targetDirPath");
      }

      // 3. 遍历源目录下的所有文件
      await for (FileSystemEntity entity in sourceDir.list(
        recursive: includeSubDir, // 是否递归遍历子目录
        followLinks: false, // 不跟随符号链接
      )) {
        // 仅处理文件（跳过目录本身）
        if (entity is File) {
          // 拼接目标文件路径（保留源文件的相对路径结构）
          final String relativePath = path.relative(entity.path, from: sourceDirPath);
          final String targetFilePath = path.join(targetDirPath, relativePath);

          // 确保目标文件的父目录存在（比如子目录下的文件）
          final String targetFileDir = path.dirname(targetFilePath);
          await Directory(targetFileDir).create(recursive: true);

          // 复制文件（覆盖已存在的同名文件）
          await entity.copy(targetFilePath);
          print("文件复制成功：${entity.path} -> $targetFilePath");
        }
      }

      print("所有文件复制完成！");
      return true;
    } catch (e) {
      print("文件复制失败：$e");
      return false;
    }
  }

// 调用示例（比如按钮点击事件/初始化逻辑中）
  void onCopyFiles() async {
    // 定义源目录和目标目录（使用原始字符串避免转义错误）
    const String sourceDir = r'C:\Users\50257\Documents\scripts';
    const String targetDir = r'C:\flutter\py_auto\build\windows\x64\runner\Release\data\flutter_assets\scripts';

    // 执行复制
    bool isSuccess = await copyDirectoryFiles(
      sourceDirPath: sourceDir,
      targetDirPath: targetDir,
      includeSubDir: true, // 如需仅复制一级文件，设为 false
    );

    if (isSuccess) {
      // 复制成功后的逻辑（如提示用户）
      print("✅ 文件复制全部完成");
    } else {
      // 复制失败后的逻辑
      print("❌ 文件复制失败，请检查路径/权限");
    }
  }
}
