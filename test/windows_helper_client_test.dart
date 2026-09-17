import 'dart:io';

import 'package:ai/win_workspace.dart';
import 'package:ai/windows_helper_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 helper：实现 win_helper 的 JSON-Lines 协议（只有测试用到的几条命令）。
const String _fakeHelperSource = r'''
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        request = json.loads(line)
    except Exception as exc:
        sys.stdout.write(json.dumps({"id": None, "ok": False, "error": str(exc)}) + "\n")
        sys.stdout.flush()
        continue
    request_id = request.get("id")
    cmd = request.get("cmd")
    args = request.get("args") or {}
    if cmd == "ping":
        payload = {"id": request_id, "ok": True, "data": {"protocol": 1}, "error": None}
    elif cmd == "list_devices":
        payload = {"id": request_id, "ok": True, "error": None,
                   "data": {"count": 1, "devices": [{"deviceId": "win:1111", "pid": 1111}]}}
    elif cmd == "click":
        payload = {"id": request_id, "ok": True, "error": None,
                   "data": {"ok": True, "method": "postmessage",
                            "realPoint": [args.get("x"), args.get("y")]}}
    elif cmd == "capture":
        payload = {"id": request_id, "ok": True, "error": None,
                   "data": {"path": args.get("savePath", ""), "width": 1600, "height": 900}}
    elif cmd == "boom":
        payload = {"id": request_id, "ok": False, "error": "设备不存在", "data": {"ok": False}}
    elif cmd == "shutdown":
        sys.stdout.write(json.dumps({"id": request_id, "ok": True, "data": {}, "error": None}) + "\n")
        sys.stdout.flush()
        break
    else:
        payload = {"id": request_id, "ok": False, "error": "未知命令：" + str(cmd)}
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()
sys.stderr.write("fake helper exited\n")
''';

String get _pythonExecutable => Platform.isWindows ? 'python' : 'python3';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late WinWorkspace workspace;
  late WindowsHelperClient client;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('win_ws_test_');
    Directory('${tempRoot.path}/tools').createSync(recursive: true);
    Directory('${tempRoot.path}/scripts/win').createSync(recursive: true);
    File('${tempRoot.path}/tools/win_helper.py').writeAsStringSync(_fakeHelperSource);
    File('${tempRoot.path}/scripts/win/win_device.py').writeAsStringSync('# marker\n');
    workspace = WinWorkspace.at(tempRoot.path);
    client = WindowsHelperClient(
      workspace: workspace,
      pythonExecutable: _pythonExecutable,
      defaultTimeout: const Duration(seconds: 20),
    );
  });

  tearDown(() async {
    await client.stop();
    tempRoot.deleteSync(recursive: true);
  });

  group('WinWorkspace', () {
    test('extracts helper paths from the root', () {
      expect(workspace.helperScript, '${tempRoot.path}/tools/win_helper.py');
      expect(workspace.flowRunnerScript, '${tempRoot.path}/scripts/win/flow_runner_win.py');
      expect(workspace.recordRunnerScript, '${tempRoot.path}/scripts/win/record_runner_win.py');
      expect(workspace.isAvailable, isTrue);
    });

    test('locate finds the marker files upwards', () {
      final nested = Directory('${tempRoot.path}/build/windows/x64/runner/Release')
        ..createSync(recursive: true);
      final found = WinWorkspace.locate(startDirectory: nested);
      expect(found, isNotNull);
      expect(found!.root, tempRoot.path);
    });

    test('locate returns null when markers are missing', () {
      final empty = Directory.systemTemp.createTempSync('win_ws_empty_');
      addTearDown(() => empty.deleteSync(recursive: true));
      expect(
        WinWorkspace.locate(startDirectory: empty, includeFallbacks: false),
        isNull,
      );
      // 默认会回退到当前工作目录（flutter test 的 cwd 就是工程根）
      expect(WinWorkspace.locate(startDirectory: empty), isNotNull);
    });

    test('bundled file list matches the files on disk', () {
      // 发布版靠这份清单把脚本解包出来；与 pubspec assets 一起保证不漂移
      final pythonFiles = Directory('scripts/win')
          .listSync()
          .whereType<File>()
          .map((file) => file.path)
          .where((path) => path.endsWith('.py') && !path.endsWith('build_win_runners.py'))
          .toList()
        ..sort();
      final declared = WinWorkspace.bundledFiles
          .where((path) => path.startsWith('scripts/win/') && path.endsWith('.py'))
          .toList()
        ..sort();
      expect(declared, pythonFiles);
      expect(WinWorkspace.bundledFiles, contains('tools/win_helper.py'));
    });

    test('materializeFromAssets unpacks the bundled python runtime', () async {
      final temp = await Directory.systemTemp.createTemp('win_runtime_test_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final workspace = await WinWorkspace.materializeFromAssets(temp);
      expect(workspace, isNotNull, reason: 'assets 里必须能找到 win_device.py');
      expect(File(workspace!.helperScript).existsSync(), isTrue);
      expect(File(workspace.flowRunnerScript).existsSync(), isTrue);
      expect(File(workspace.recordRunnerScript).existsSync(), isTrue);
      expect(
        File(workspace.path('scripts/win/win_record.py')).existsSync(),
        isTrue,
      );
      expect(
        File(workspace.path('scripts/win/win_device.py')).lengthSync(),
        greaterThan(1000),
      );
      // 解包出来的目录必须能直接被当成工作区使用
      expect(workspace.isAvailable, isTrue);
    });

    test('missingHint mentions the search start', () {
      final missing = WinWorkspace.at('${tempRoot.path}/nowhere');
      expect(missing.isAvailable, isFalse);
      expect(missing.missingHint, contains('scripts/win/win_device.py'));
    });
  });

  group('WindowsHelperClient', () {
    test('starts lazily and answers ping', () async {
      expect(client.isRunning, isFalse);
      final pong = await client.send('ping');
      expect(pong['protocol'], 1);
      expect(client.isRunning, isTrue);
    });

    test('service maps list_devices and click', () async {
      final service = WindowsDeviceService(client);
      expect(await service.listDeviceIds(), <String>['win:1111']);
      final click = await service.tap('win:1111', 800, 450);
      expect(click['realPoint'], <int>[800, 450]);
    });

    test('capture returns the save path', () async {
      final service = WindowsDeviceService(client);
      final path = await service.capture('win:1111', '/tmp/shot.png');
      expect(path, '/tmp/shot.png');
    });

    test('operation failure is promoted to an exception', () async {
      await expectLater(
        client.send('boom'),
        throwsA(predicate((Object e) => e.toString().contains('设备不存在'))),
      );
    });

    test('unknown command raises with the helper message', () async {
      await expectLater(
        client.send('nope'),
        throwsA(predicate((Object e) => e.toString().contains('未知命令'))),
      );
    });

    test('requests stay correlated when sent concurrently', () async {
      final results = await Future.wait(<Future<Map<String, dynamic>>>[
        client.send('click', args: <String, dynamic>{'x': 1, 'y': 1}),
        client.send('click', args: <String, dynamic>{'x': 2, 'y': 2}),
        client.send('ping'),
        client.send('click', args: <String, dynamic>{'x': 3, 'y': 3}),
      ]);
      expect(results[0]['realPoint'], <int>[1, 1]);
      expect(results[1]['realPoint'], <int>[2, 2]);
      expect(results[3]['realPoint'], <int>[3, 3]);
    });

    test('timeout surfaces a readable error', () async {
      final idleRoot = Directory.systemTemp.createTempSync('win_ws_idle_');
      addTearDown(() => idleRoot.deleteSync(recursive: true));
      Directory('${idleRoot.path}/tools').createSync(recursive: true);
      Directory('${idleRoot.path}/scripts/win').createSync(recursive: true);
      File('${idleRoot.path}/scripts/win/win_device.py').writeAsStringSync('');
      File('${idleRoot.path}/tools/win_helper.py').writeAsStringSync(
        'import sys, time\nsys.stdin.readline()\ntime.sleep(30)\n',
      );
      final idleClient = WindowsHelperClient(
        workspace: WinWorkspace.at(idleRoot.path),
        pythonExecutable: _pythonExecutable,
        defaultTimeout: const Duration(seconds: 1),
      );
      addTearDown(() async => idleClient.stop());
      await expectLater(
        idleClient.send('ping'),
        throwsA(predicate((Object e) => e.toString().contains('超时'))),
      );
    });

    test('stop shuts the helper down', () async {
      await client.send('ping');
      expect(client.isRunning, isTrue);
      await client.stop();
      expect(client.isRunning, isFalse);
    });
  });
}
