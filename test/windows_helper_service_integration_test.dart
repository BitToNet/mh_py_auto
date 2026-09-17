import 'dart:convert';
import 'dart:io';

import 'package:ai/win_workspace.dart';
import 'package:ai/windows_helper_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨进程集成测试：跑**真实的** tools/win_helper.py（serve/handle_line/cmd_*），
/// 只把最底层 Win32 换成假实现 —— 见 test/fixtures/real_helper_service.py。
///
/// windows_helper_client_test.dart 用的是手写协议桩，验证的是界面侧逻辑；
/// 这个文件验证的是"两端真的连起来"这一段：JSON-Lines 拆包/粘包、
/// 多 MB 的 base64 单行 payload、Unicode 双向、错误传播、shutdown 退出。
String get _pythonExecutable => Platform.isWindows ? 'python' : 'python3';

/// 真实 helper 的所在位置（相对包根目录，flutter test 的工作目录就是包根）。
final File _fixture = File('test/fixtures/real_helper_service.py');

/// 临时工作区里的 3 行启动器：把真正的 serve() 跑起来。
String _launcherSource(String fixturePath) => '''
import runpy
runpy.run_path(r"$fixturePath", run_name="__main__")
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late WindowsHelperClient client;
  final List<String> logs = <String>[];

  setUpAll(() {
    final probe = Process.runSync(_pythonExecutable, <String>['-c', 'print(1)']);
    if (probe.exitCode != 0) {
      fail('本机没有可用的 $_pythonExecutable，无法跑跨进程集成测试');
    }
  });

  setUp(() {
    expect(_fixture.existsSync(), isTrue,
        reason: '缺少集成测试夹具：${_fixture.path}');
    logs.clear();
    tempRoot = Directory.systemTemp.createTempSync('win_helper_integration_');
    Directory('${tempRoot.path}/tools').createSync(recursive: true);
    File('${tempRoot.path}/tools/win_helper.py')
        .writeAsStringSync(_launcherSource(_fixture.absolute.path));
    client = WindowsHelperClient(
      workspace: WinWorkspace.at(tempRoot.path),
      pythonExecutable: _pythonExecutable,
      logSink: logs.add,
      defaultTimeout: const Duration(seconds: 60),
    );
  });

  tearDown(() async {
    await client.stop();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  test('ping 与 health 走真实 handle_line', () async {
    final service = WindowsDeviceService(client);
    final ping = await service.ping();
    expect(ping['protocol'], 1);
    expect(ping['isWindows'], isTrue);

    final health = await service.health();
    expect(health['isWindows'], isTrue);
    final environment = health['environment'] as Map<String, dynamic>;
    expect(environment['python'], isNotEmpty);
    expect(environment['inputOrder'], <String>[
      'postmessage',
      'sendmessage',
      'sendinput',
    ]);
    expect(environment['captureOrder'], isNotEmpty);
    expect(logs.join('\n'), contains('服务就绪'));
  });

  test('设备列表带回中文标题（Unicode 双向）', () async {
    final service = WindowsDeviceService(client);
    expect(await service.listDeviceIds(), <String>['win:1111']);
    final devices = await service.listDevices();
    expect(devices, hasLength(1));
    expect(devices.first['title'], '梦幻西游：时空');
  });

  test('点击坐标经真实命令映射到设备层', () async {
    final service = WindowsDeviceService(client);
    final clicked = await service.tap('win:1111', 800, 450);
    expect(clicked['ok'], isTrue);
    expect(clicked['realPoint'], <int>[800, 450]);
    expect(clicked['method'], 'postmessage');
  });

  test('未知命令把 helper 的错误原样带回来', () async {
    await expectLater(
      client.send('definitely_not_a_command'),
      throwsA(
        isA<Exception>().having(
          (Object error) => error.toString(),
          'message',
          contains('未知命令'),
        ),
      ),
    );
  });

  test('多 MB 的 base64 截图能完整穿过管道', () async {
    final service = WindowsDeviceService(client);
    final base64Png = await service.capturePngBase64('win:1111');
    // 1600x900 的 PNG base64 是几 MB 的单行 JSON，缓冲/拆包有问题这里必炸
    expect(base64Png.length, greaterThan(200000));
    expect(base64Png.substring(0, 8), startsWith('iVBOR'));
    expect(base64.decode(base64Png).sublist(0, 8),
        <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  });

  test('并发请求各自拿到自己的响应', () async {
    final service = WindowsDeviceService(client);
    final futures = <Future<Object?>>[
      for (var index = 0; index < 6; index++) service.ping(),
      service.listDeviceIds(),
      service.tap('win:1111', 10 + 0, 20),
      service.health(),
    ];
    final results = await Future.wait(futures);
    expect(results.whereType<Map<String, dynamic>>(), isNotEmpty);
    for (var index = 0; index < 6; index++) {
      expect((results[index] as Map<String, dynamic>)['protocol'], 1);
    }
    expect(results[6], <String>['win:1111']);
  });

  test('stop 之后进程真的退出，且能再次启动', () async {
    final service = WindowsDeviceService(client);
    await service.ping();
    expect(client.isRunning, isTrue);
    await client.stop();
    expect(client.isRunning, isFalse);
    await service.ping();
    expect(client.isRunning, isTrue);
  });

  test('文本输入的 Unicode 完整到达 Python 侧', () async {
    final service = WindowsDeviceService(client);
    final result = await service.inputText('win:1111', '时空测试');
    expect(result['ok'], isTrue);
    expect(result['method'], isIn(<String>['unicode', 'wm_char', 'clipboard']));

    // 夹具把真实收到的请求行落盘（工作目录就是临时工作区）
    final log = File('${tempRoot.path}/helper_received_requests.jsonl');
    expect(log.existsSync(), isTrue, reason: '夹具没有记录到请求');
    final requests = log
        .readAsLinesSync()
        .where((String line) => line.trim().isNotEmpty)
        .map((String line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    final textRequest = requests.lastWhere((item) => item['cmd'] == 'text');
    final args = textRequest['args'] as Map<String, dynamic>;
    expect(args['text'], '时空测试');
    expect(args['deviceId'], 'win:1111');
    // 请求 id 是自增的整数，响应 id 必须与之一一对应
    expect(textRequest['id'], isA<int>());
  });
}
