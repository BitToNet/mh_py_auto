import 'package:ai/custom_flow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('custom flow text lines', () {
    test('trims LF and CRLF lines and ignores blank lines', () {
      final lines = splitCustomFlowTextLines(
        '  第一条  \r\n\r\n 第二条\n   \nEmoji 😀  ',
      );

      expect(lines, ['第一条', '第二条', 'Emoji 😀']);
    });

    test('returns no entries for whitespace-only input', () {
      expect(splitCustomFlowTextLines(' \r\n\t\n  '), isEmpty);
    });
  });

  group('paste text resolution', () {
    test('uses fixed text when parent-loop input is disabled', () {
      const step = CustomFlowStep(
        id: 'paste',
        type: CustomFlowStepType.pasteText,
        label: '固定文字',
        textContent: '中文 😀 & symbols',
      );

      expect(
        resolveCustomFlowPasteText(step, parentLoopText: '上层文字'),
        '中文 😀 & symbols',
      );
    });

    test('uses the nearest supplied parent-loop text', () {
      const step = CustomFlowStep(
        id: 'paste',
        type: CustomFlowStepType.pasteText,
        label: '循环文字',
        useParentLoopText: true,
      );

      final outerText = resolveCustomFlowPasteText(step, parentLoopText: '外层');
      final innerText = resolveCustomFlowPasteText(step, parentLoopText: '内层');

      expect(outerText, '外层');
      expect(innerText, '内层');
    });

    test('throws when parent-loop text is unavailable', () {
      const step = CustomFlowStep(
        id: 'paste',
        type: CustomFlowStepType.pasteText,
        label: '循环文字',
        useParentLoopText: true,
      );

      expect(
        () => resolveCustomFlowPasteText(step),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('custom flow text JSON', () {
    test('round-trips simulator device scope and defaults old JSON to all', () {
      const step = CustomFlowStep(
        id: 'scope',
        type: CustomFlowStepType.coordinateTap,
        label: '队员操作',
        deviceScope: CustomFlowDeviceScope.others,
      );

      final encoded = step.toJson();
      expect(encoded['deviceScope'], 'others');
      expect(
        CustomFlowStep.fromJson(encoded).deviceScope,
        CustomFlowDeviceScope.others,
      );
      for (final scope in [
        CustomFlowDeviceScope.all,
        CustomFlowDeviceScope.first,
        CustomFlowDeviceScope.others,
      ]) {
        expect(
          CustomFlowStep.fromJson(
            CustomFlowStep(
              id: 'scope_${scope.name}',
              type: CustomFlowStepType.wait,
              label: '范围',
              deviceScope: scope,
            ).toJson(),
          ).deviceScope,
          scope,
        );
      }
      expect(
        CustomFlowStep.fromJson({
          'id': 'legacy',
          'type': 'wait',
          'label': '旧步骤',
        }).deviceScope,
        CustomFlowDeviceScope.all,
      );
    });

    test('round-trips paste and text-loop fields', () {
      const step = CustomFlowStep(
        id: 'loop',
        type: CustomFlowStepType.loopBlock,
        label: '逐行循环',
        loopMode: CustomFlowLoopMode.textLines,
        loopTextContent: '甲\n乙',
        children: [
          CustomFlowStep(
            id: 'paste',
            type: CustomFlowStepType.pasteText,
            label: '输入当前行',
            textContent: '固定备用',
            useParentLoopText: true,
          ),
        ],
      );

      final decoded = CustomFlowStep.fromJson(step.toJson());

      expect(decoded.loopMode, CustomFlowLoopMode.textLines);
      expect(decoded.loopTextContent, '甲\n乙');
      expect(decoded.children.single.type, CustomFlowStepType.pasteText);
      expect(decoded.children.single.textContent, '固定备用');
      expect(decoded.children.single.useParentLoopText, isTrue);
    });

    test('old JSON receives backward-compatible defaults', () {
      final decoded = CustomFlowStep.fromJson({
        'id': 'old',
        'type': 'loopBlock',
        'label': '旧循环',
      });

      expect(decoded.loopMode, CustomFlowLoopMode.fixedCount);
      expect(decoded.loopTextContent, isEmpty);
      expect(decoded.textContent, isEmpty);
      expect(decoded.useParentLoopText, isFalse);
    });
  });

  group('custom flow recognition JSON', () {
    test('round-trips image tap text-recognition fields', () {
      const step = CustomFlowStep(
        id: 'ocr',
        type: CustomFlowStepType.imageTap,
        label: '点确认',
        recognitionMode: CustomFlowRecognitionMode.text,
        ocrTargetText: '确定',
        ocrMatchMode: CustomFlowOcrMatchMode.exact,
        ocrRegionLeft: 10,
        ocrRegionTop: 20,
        ocrRegionRight: 300,
        ocrRegionBottom: 420,
        ocrMatchIndex: 2,
        ocrClickOffsetX: 5,
        ocrClickOffsetY: -6,
        confidence: 0.57,
        maxAttempts: 4,
        retryIntervalSeconds: 0.9,
        randomOffsetPx: 3,
        postWaitMinSeconds: 1.1,
        postWaitMaxSeconds: 1.8,
        continueOnFailure: true,
      );

      final decoded = CustomFlowStep.fromJson(step.toJson());

      expect(decoded.type, CustomFlowStepType.imageTap);
      expect(decoded.recognitionMode, CustomFlowRecognitionMode.text);
      expect(decoded.ocrTargetText, '确定');
      expect(decoded.ocrMatchMode, CustomFlowOcrMatchMode.exact);
      expect(decoded.ocrRegionLeft, 10);
      expect(decoded.ocrRegionTop, 20);
      expect(decoded.ocrRegionRight, 300);
      expect(decoded.ocrRegionBottom, 420);
      expect(decoded.ocrMatchIndex, 2);
      expect(decoded.ocrClickOffsetX, 5);
      expect(decoded.ocrClickOffsetY, -6);
      expect(decoded.confidence, 0.57);
      expect(decoded.maxAttempts, 4);
      expect(decoded.retryIntervalSeconds, 0.9);
      expect(decoded.randomOffsetPx, 3);
      expect(decoded.postWaitMinSeconds, 1.1);
      expect(decoded.postWaitMaxSeconds, 1.8);
      expect(decoded.continueOnFailure, isTrue);
    });

    test('old ocrTap JSON migrates to image tap text mode', () {
      final decoded = CustomFlowStep.fromJson({
        'id': 'ocr',
        'type': 'ocrTap',
        'label': '旧 OCR',
        'ocrMatchMode': 'unknown',
      });

      expect(decoded.type, CustomFlowStepType.imageTap);
      expect(decoded.recognitionMode, CustomFlowRecognitionMode.text);
      expect(decoded.ocrTargetText, isEmpty);
      expect(decoded.ocrMatchMode, CustomFlowOcrMatchMode.contains);
      expect(decoded.ocrRegionLeft, -1);
      expect(decoded.ocrRegionTop, -1);
      expect(decoded.ocrRegionRight, -1);
      expect(decoded.ocrRegionBottom, -1);
      expect(decoded.ocrMatchIndex, 1);
      expect(decoded.ocrClickOffsetX, 0);
      expect(decoded.ocrClickOffsetY, 0);
    });

    test('missing recognition mode defaults to image', () {
      final decoded = CustomFlowStep.fromJson({
        'id': 'image',
        'type': 'imageTap',
        'label': 'old image',
      });

      expect(decoded.recognitionMode, CustomFlowRecognitionMode.image);
    });

    test('round-trips loop image-condition text-recognition fields', () {
      const step = CustomFlowStep(
        id: 'loop_ocr',
        type: CustomFlowStepType.loopBlock,
        label: '倒计时循环',
        loopMode: CustomFlowLoopMode.imageCondition,
        loopImageAction: CustomFlowLoopImageAction.continueOnMatch,
        recognitionMode: CustomFlowRecognitionMode.text,
        ocrTargetText: r'(?<!\d)10(?!\d)',
        ocrMatchMode: CustomFlowOcrMatchMode.regex,
        ocrRegionLeft: 12,
        ocrRegionTop: 34,
        ocrRegionRight: 256,
        ocrRegionBottom: 320,
        confidence: 0.66,
      );

      final decoded = CustomFlowStep.fromJson(step.toJson());

      expect(decoded.type, CustomFlowStepType.loopBlock);
      expect(decoded.loopMode, CustomFlowLoopMode.imageCondition);
      expect(
        decoded.loopImageAction,
        CustomFlowLoopImageAction.continueOnMatch,
      );
      expect(decoded.recognitionMode, CustomFlowRecognitionMode.text);
      expect(decoded.ocrTargetText, r'(?<!\d)10(?!\d)');
      expect(decoded.ocrMatchMode, CustomFlowOcrMatchMode.regex);
      expect(decoded.ocrRegionLeft, 12);
      expect(decoded.ocrRegionTop, 34);
      expect(decoded.ocrRegionRight, 256);
      expect(decoded.ocrRegionBottom, 320);
      expect(decoded.confidence, 0.66);
    });
  });

  group('custom flow branch image JSON', () {
    test('round-trips multiple condition images', () {
      const branchCase = CustomFlowBranchCase(
        id: 'case',
        label: 'multi image',
        confidence: 0.72,
        templateImages: [
          CustomFlowBranchImage(
            id: 'case',
            imageSource: CustomFlowImageSource.asset,
            templateName: 'first.png',
          ),
          CustomFlowBranchImage(
            id: 'case_second',
            imageSource: CustomFlowImageSource.localFile,
            templateName: 'second.png',
            templatePath: '/tmp/second.png',
          ),
        ],
      );

      final decoded = CustomFlowBranchCase.fromJson(branchCase.toJson());

      expect(decoded.templateImages, hasLength(2));
      expect(decoded.templateName, 'first.png');
      expect(decoded.imageSource, CustomFlowImageSource.asset);
      expect(decoded.templateImages.last.id, 'case_second');
      expect(decoded.templateImages.last.templatePath, '/tmp/second.png');
    });

    test('round-trips branch screenshot reuse flag', () {
      const step = CustomFlowStep(
        id: 'branch_step',
        type: CustomFlowStepType.imageBranch,
        label: '分支',
        reuseParentBranchScreenshot: true,
      );

      final decoded = CustomFlowStep.fromJson(step.toJson());

      expect(decoded.reuseParentBranchScreenshot, isTrue);
    });

    test('defaults branch screenshot reuse flag to false when missing', () {
      final decoded = CustomFlowStep.fromJson({
        'id': 'branch_step_default',
        'type': 'imageBranch',
        'label': '分支',
        'branchCases': const <dynamic>[],
        'fallbackChildren': const <dynamic>[],
      });

      expect(decoded.reuseParentBranchScreenshot, isFalse);
    });

    test('upgrades legacy single-image JSON to one condition image', () {
      final decoded = CustomFlowBranchCase.fromJson({
        'id': 'legacy_case',
        'label': 'legacy',
        'templateName': 'legacy.png',
        'imageSource': 'asset',
        'templatePath': '',
        'confidence': 0.68,
        'steps': const <dynamic>[],
      });

      expect(decoded.templateImages, hasLength(1));
      expect(decoded.templateImages.single.id, 'legacy_case');
      expect(decoded.templateImages.single.templateName, 'legacy.png');
      expect(decoded.templateName, 'legacy.png');
    });

    test('round-trips branch text-recognition fields', () {
      const branchCase = CustomFlowBranchCase(
        id: 'text_case',
        label: 'text',
        recognitionMode: CustomFlowRecognitionMode.text,
        confidence: 0.61,
        ocrTargetText: '确定',
        ocrMatchMode: CustomFlowOcrMatchMode.regex,
        ocrRegionLeft: 11,
        ocrRegionTop: 22,
        ocrRegionRight: 333,
        ocrRegionBottom: 444,
      );

      final decoded = CustomFlowBranchCase.fromJson(branchCase.toJson());

      expect(decoded.recognitionMode, CustomFlowRecognitionMode.text);
      expect(decoded.ocrTargetText, '确定');
      expect(decoded.ocrMatchMode, CustomFlowOcrMatchMode.regex);
      expect(decoded.confidence, 0.61);
      expect(decoded.ocrRegionLeft, 11);
      expect(decoded.ocrRegionTop, 22);
      expect(decoded.ocrRegionRight, 333);
      expect(decoded.ocrRegionBottom, 444);
    });
  });

  test('detects paste text inside nested branch and loop steps', () {
    const steps = [
      CustomFlowStep(
        id: 'loop',
        type: CustomFlowStepType.loopBlock,
        label: '循环',
        children: [
          CustomFlowStep(
            id: 'branch',
            type: CustomFlowStepType.imageBranch,
            label: '分支',
            fallbackChildren: [
              CustomFlowStep(
                id: 'paste',
                type: CustomFlowStepType.pasteText,
                label: '输入',
              ),
            ],
          ),
        ],
      ),
    ];

    expect(customFlowContainsPasteText(steps), isTrue);
    expect(
      customFlowContainsPasteText([
        const CustomFlowStep(
          id: 'wait',
          type: CustomFlowStepType.wait,
          label: '等待',
        ),
      ]),
      isFalse,
    );
  });
}
