import 'package:ai/custom_flow.dart';
import 'package:ai/recording_flow.dart';
import 'package:flutter_test/flutter_test.dart';

RecordedAction action({
  required RecordedActionType type,
  required int delayMs,
  required int x,
  required int y,
  int durationMs = 0,
}) {
  return RecordedAction(
    type: type,
    delayMs: delayMs,
    startX: x,
    startY: y,
    endX: x,
    endY: y,
    durationMs: durationMs,
    holdBeforeMoveMs: 0,
    dragPath: const [],
    rawEvents: const [],
  );
}

void main() {
  test('converts taps and preserves elapsed time between them', () {
    final recordedFlow = RecordedFlow(
      name: 'daily',
      deviceId: 'device',
      touchDevicePath: '/dev/input/event1',
      screenWidth: 1080,
      screenHeight: 1920,
      createdAt: DateTime(2026, 1, 1),
      actions: [
        action(type: RecordedActionType.tap, delayMs: 300, x: 100, y: 200),
        action(
          type: RecordedActionType.swipe,
          delayMs: 400,
          x: 300,
          y: 400,
          durationMs: 600,
        ),
        action(type: RecordedActionType.tap, delayMs: 500, x: 500, y: 600),
      ],
    );

    final result = const RecordedFlowToCustomFlowConverter().convert(
      recordedFlow: recordedFlow,
      options: const RecordedFlowConversionOptions(
        randomOffsetPx: 8,
        waitVariationSeconds: 0.25,
      ),
      convertedAt: DateTime(2026, 2, 3),
    );

    expect(result.flow.name, 'daily_固定点击转换');
    expect(result.convertedTapCount, 2);
    expect(result.skippedActionCount, 1);
    expect(result.flow.steps, hasLength(2));
    expect(result.flow.steps.first.type, CustomFlowStepType.coordinateTap);
    expect(result.flow.steps.first.x, 100);
    expect(result.flow.steps.first.y, 200);
    expect(result.flow.steps.first.randomOffsetPx, 8);
    expect(result.flow.steps.first.postWaitMinSeconds, 1.75);
    expect(result.flow.steps.first.postWaitMaxSeconds, 2);
    expect(result.flow.steps.last.x, 500);
    expect(result.flow.steps.last.y, 600);
    expect(result.flow.steps.last.postWaitMinSeconds, 0);
    expect(result.flow.steps.last.postWaitMaxSeconds, 0);
  });

  test('ignores leading delays and non-tap-only recordings', () {
    final recordedFlow = RecordedFlow(
      name: 'swipes',
      deviceId: 'device',
      touchDevicePath: '/dev/input/event1',
      screenWidth: 1920,
      screenHeight: 1080,
      createdAt: DateTime(2026, 1, 1),
      actions: [
        action(
          type: RecordedActionType.longPress,
          delayMs: 1000,
          x: 100,
          y: 200,
          durationMs: 800,
        ),
      ],
    );

    final result = const RecordedFlowToCustomFlowConverter().convert(
      recordedFlow: recordedFlow,
      options: const RecordedFlowConversionOptions(
        randomOffsetPx: 0,
        waitVariationSeconds: 0,
      ),
    );

    expect(result.convertedTapCount, 0);
    expect(result.skippedActionCount, 1);
    expect(result.flow.steps, isEmpty);
  });

  test('keeps recorded coordinates unchanged', () {
    final recordedFlow = RecordedFlow(
      name: 'portrait_source',
      deviceId: 'device',
      touchDevicePath: '/dev/input/event1',
      screenWidth: 1080,
      screenHeight: 1920,
      createdAt: DateTime(2026, 1, 1),
      actions: [
        action(type: RecordedActionType.tap, delayMs: 0, x: 540, y: 960),
        action(type: RecordedActionType.tap, delayMs: 100, x: 1080, y: 1920),
      ],
    );

    final result = const RecordedFlowToCustomFlowConverter().convert(
      recordedFlow: recordedFlow,
      options: const RecordedFlowConversionOptions(
        randomOffsetPx: 0,
        waitVariationSeconds: 0,
      ),
    );

    expect(result.flow.steps.first.x, 540);
    expect(result.flow.steps.first.y, 960);
    expect(result.flow.steps.last.x, 1080);
    expect(result.flow.steps.last.y, 1920);
  });

  test('keeps rotated source coordinates and applies additive wait range', () {
    final recordedFlow = RecordedFlow(
      name: 'landscape_click',
      deviceId: 'device',
      touchDevicePath: '/dev/input/event1',
      screenWidth: 1600,
      screenHeight: 900,
      createdAt: DateTime(2026, 1, 1),
      actions: [
        action(type: RecordedActionType.tap, delayMs: 0, x: 852, y: 48),
        action(type: RecordedActionType.tap, delayMs: 3000, x: 800, y: 100),
      ],
    );

    final result = const RecordedFlowToCustomFlowConverter().convert(
      recordedFlow: recordedFlow,
      options: const RecordedFlowConversionOptions(
        randomOffsetPx: 0,
        waitVariationSeconds: 2,
      ),
    );

    expect(result.flow.steps.first.x, 852);
    expect(result.flow.steps.first.y, 48);
    expect(result.flow.steps.first.postWaitMinSeconds, 5);
    expect(result.flow.steps.first.postWaitMaxSeconds, 7);
  });
}
