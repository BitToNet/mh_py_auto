import 'package:ai/flow_device_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseConnectedAdbDeviceIds', () {
    test('returns only adb devices in connected state', () {
      final devices = parseConnectedAdbDeviceIds('''
List of devices attached
emulator-5554	device
emulator-5556	offline
127.0.0.1:7555	unauthorized
device-with-model	device product:sdk model:Pixel
''');

      expect(devices, ['emulator-5554', 'device-with-model']);
    });
  });

  group('resolveFlowDeviceSelection', () {
    test('rejects single-device flows when no emulator is connected', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const [],
        connectedDeviceIds: const [],
        requirement: FlowDeviceRequirement.single,
        operationLabel: '开始录制',
      );

      expect(result.isValid, isFalse);
      expect(result.message, contains('未找到已连接模拟器'));
    });

    test('rejects single-device flows when multiple devices are targeted', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const [],
        connectedDeviceIds: const ['emulator-5554', 'emulator-5556'],
        requirement: FlowDeviceRequirement.single,
        operationLabel: '开始录制',
      );

      expect(result.isValid, isFalse);
      expect(result.message, contains('请只保留一个目标设备'));
    });

    test('uses the selected connected device for single-device flows', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const ['emulator-5556'],
        connectedDeviceIds: const ['emulator-5554', 'emulator-5556'],
        requirement: FlowDeviceRequirement.single,
        operationLabel: '开始录制',
      );

      expect(result.isValid, isTrue);
      expect(result.deviceIds, ['emulator-5556']);
    });

    test('rejects selected devices that are no longer connected', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const ['emulator-5556'],
        connectedDeviceIds: const ['emulator-5554'],
        requirement: FlowDeviceRequirement.single,
        operationLabel: '开始录制',
      );

      expect(result.isValid, isFalse);
      expect(result.missingSelectedDeviceIds, ['emulator-5556']);
      expect(result.message, contains('已选择但未连接'));
    });

    test('allows custom flow execution on multiple connected devices', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const [],
        connectedDeviceIds: const ['emulator-5554', 'emulator-5556'],
        requirement: FlowDeviceRequirement.multiple,
        operationLabel: '执行自定义流程',
      );

      expect(result.isValid, isTrue);
      expect(result.deviceIds, ['emulator-5554', 'emulator-5556']);
    });

    test('allows recorded playback on selected connected devices', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const ['emulator-5556', 'emulator-5558'],
        connectedDeviceIds: const [
          'emulator-5554',
          'emulator-5556',
          'emulator-5558',
        ],
        requirement: FlowDeviceRequirement.multiple,
        operationLabel: '开始回放',
      );

      expect(result.isValid, isTrue);
      expect(result.deviceIds, ['emulator-5556', 'emulator-5558']);
    });

    test('allows recorded playback on all connected devices when none selected', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const [],
        connectedDeviceIds: const ['emulator-5554', 'emulator-5556'],
        requirement: FlowDeviceRequirement.multiple,
        operationLabel: '开始回放',
      );

      expect(result.isValid, isTrue);
      expect(result.deviceIds, ['emulator-5554', 'emulator-5556']);
    });

    test('rejects recorded playback when selected device is disconnected', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const ['emulator-5556'],
        connectedDeviceIds: const ['emulator-5554'],
        requirement: FlowDeviceRequirement.multiple,
        operationLabel: '开始回放',
      );

      expect(result.isValid, isFalse);
      expect(result.missingSelectedDeviceIds, ['emulator-5556']);
      expect(result.message, contains('已选择但未连接'));
    });

    test('rejects missing devices specified by custom flow steps', () {
      final result = resolveFlowDeviceSelection(
        selectedDeviceIds: const ['emulator-5554'],
        connectedDeviceIds: const ['emulator-5554'],
        requiredDeviceIds: const ['emulator-5556'],
        requirement: FlowDeviceRequirement.multiple,
        operationLabel: '执行自定义流程',
      );

      expect(result.isValid, isFalse);
      expect(result.missingRequiredDeviceIds, ['emulator-5556']);
      expect(result.message, contains('步骤中指定但未连接'));
    });
  });
}
