import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

class NetworkTimeUtil {
  /// 备用方案：调用百度时间 API
  static Future<int> getAliyunNetworkTimestamp() async {
    final url = Uri.parse('http://www.taobao.com');
    final response = await HttpClient()
        .getUrl(url)
        .timeout(const Duration(seconds: 5))
        .then((request) => request.close());

    // 从响应头获取时间（Date 字段）
    final timestampStr = response.headers.value('ali-swift-global-savetime');
    if (timestampStr == null) return 0;

    return int.parse(timestampStr);
  }

  /// 兜底方案：优先用阿里云，失败则用百度
  // static Future<int?> getNetworkTimestamp() async {
  //   int? timestamp = await getAliyunNetworkTimestamp();
  //   if (timestamp != null) return timestamp;
  //
  //   timestamp = await getBaiduNetworkTimestamp();
  //   return timestamp;
  // }
}
