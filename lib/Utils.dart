
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

class Utils {
  static final Utils _util = Utils._internal();


  Utils._internal();

  factory Utils() => _util;

  /// 核心方法：兼容 Windows/iOS/Android/Web 的 UUID 获取
  Future<String> getDeviceUUID() async {
    final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
    String uuid = "";

    try {
      if (kIsWeb) {
        // Web 端：无系统级 UUID，生成随机唯一标识
        uuid = const Uuid().v4();
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        // Android 端：获取 androidId（无需权限）
        final AndroidDeviceInfo androidInfo = await deviceInfoPlugin.androidInfo;
        uuid = androidInfo.id ?? const Uuid().v4();
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS 端：获取设备厂商唯一标识
        final IosDeviceInfo iosInfo = await deviceInfoPlugin.iosInfo;
        uuid = iosInfo.identifierForVendor ?? const Uuid().v4();
      } else if (defaultTargetPlatform == TargetPlatform.windows) {
        // Windows 端：获取设备唯一标识（machineId 更稳定）
        final WindowsDeviceInfo windowsInfo = await deviceInfoPlugin.windowsInfo;
        // 优先用 machineId，无则用 deviceId，兜底生成随机 UUID
        uuid = windowsInfo.deviceId ?? const Uuid().v4();
      } else {
        // 其他平台（macOS/Linux 等）
        uuid = const Uuid().v4();
      }
    } catch (e) {
      // 异常兜底：生成随机 UUID
      uuid = const Uuid().v4();
      debugPrint("获取 UUID 失败：$e");
    }
    return uuid;
  }
}