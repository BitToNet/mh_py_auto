import 'dart:convert';
import 'dart:io';

import 'package:ai/custom_flow.dart';
import 'package:ai/recording_flow.dart';
import 'package:flutter_test/flutter_test.dart';

class FailingSecondSaveRecorder extends TouchRecorderService {
  FailingSecondSaveRecorder({required super.flowDirectory});

  int saveCount = 0;

  @override
  Future<RecordedFlow> saveFlowAsNew(
    RecordedFlow flow, {
    String duplicateTag = 'import',
  }) async {
    saveCount += 1;
    if (saveCount == 2) {
      throw StateError('simulated recording save failure');
    }
    return super.saveFlowAsNew(flow, duplicateTag: duplicateTag);
  }
}

RecordedFlow recordedFlow(String name) {
  return RecordedFlow(
    name: name,
    deviceId: 'emulator-5554',
    touchDevicePath: '/dev/input/event1',
    screenWidth: 1600,
    screenHeight: 900,
    createdAt: DateTime(2026, 6, 14),
    actions: const [
      RecordedAction(
        type: RecordedActionType.swipe,
        delayMs: 100,
        startX: 100,
        startY: 200,
        endX: 300,
        endY: 400,
        durationMs: 500,
        holdBeforeMoveMs: 0,
        dragPath: [],
        rawEvents: [],
      ),
    ],
  );
}

CustomFlowStep recordedStep(String id, String name) {
  return CustomFlowStep(
    id: id,
    type: CustomFlowStepType.recordedFlow,
    label: '录制手势',
    recordedFlowName: name,
  );
}

CustomFlowDefinition nestedFlow({
  required String recordedName,
  String? imagePath,
  List<String>? branchImagePaths,
}) {
  final imageStep = imagePath == null
      ? const <CustomFlowStep>[]
      : [
          CustomFlowStep(
            id: 'image',
            type: CustomFlowStepType.imageTap,
            label: '本地识图',
            imageSource: CustomFlowImageSource.localFile,
            templateName: 'template.png',
            templatePath: imagePath,
          ),
        ];
  final branchImages = branchImagePaths == null
      ? const <CustomFlowBranchImage>[]
      : [
          for (var index = 0; index < branchImagePaths.length; index++)
            CustomFlowBranchImage(
              id: index == 0 ? 'case' : 'case_image_${index + 1}',
              imageSource: CustomFlowImageSource.localFile,
              templateName: 'branch_${index + 1}.png',
              templatePath: branchImagePaths[index],
            ),
        ];
  return CustomFlowDefinition(
    name: 'package_flow',
    createdAt: DateTime(2026, 6, 14),
    updatedAt: DateTime(2026, 6, 14),
    steps: [
      CustomFlowStep(
        id: 'group',
        type: CustomFlowStepType.flowGroup,
        label: '流程组',
        children: [
          CustomFlowStep(
            id: 'loop',
            type: CustomFlowStepType.loopBlock,
            label: '循环',
            children: [recordedStep('recorded_1', recordedName), ...imageStep],
          ),
        ],
      ),
      CustomFlowStep(
        id: 'branch',
        type: CustomFlowStepType.imageBranch,
        label: '分支',
        branchCases: [
          CustomFlowBranchCase(
            id: 'case',
            label: '条件',
            imageSource: branchImages.isEmpty
                ? CustomFlowImageSource.asset
                : branchImages.first.imageSource,
            templateName: branchImages.isEmpty
                ? 'sure.png'
                : branchImages.first.templateName,
            templatePath: branchImages.isEmpty
                ? ''
                : branchImages.first.templatePath,
            templateImages: branchImages,
            steps: [recordedStep('recorded_2', recordedName)],
          ),
        ],
        fallbackChildren: [recordedStep('recorded_3', recordedName)],
      ),
    ],
  );
}

List<String> collectRecordedNames(List<CustomFlowStep> steps) {
  final result = <String>[];
  for (final step in steps) {
    if (step.type == CustomFlowStepType.recordedFlow) {
      result.add(step.recordedFlowName);
    }
    result.addAll(collectRecordedNames(step.children));
    result.addAll(collectRecordedNames(step.fallbackChildren));
    for (final branchCase in step.branchCases) {
      result.addAll(collectRecordedNames(branchCase.steps));
    }
  }
  return result;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'custom_flow_package_test_',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('v2 export recursively embeds each recorded flow once', () async {
    final recorder = TouchRecorderService(
      flowDirectory: Directory('${tempDir.path}/recordings'),
    );
    await recorder.saveFlow(recordedFlow('gesture'));
    final service = CustomFlowStorageService(
      touchRecorderService: recorder,
      baseDirectory: Directory('${tempDir.path}/custom'),
    );

    final payload = await service.buildExportPayload(
      nestedFlow(recordedName: 'gesture'),
    );

    expect(payload['version'], CustomFlowStorageService.currentPackageVersion);
    final recordedFlows = Map<String, dynamic>.from(
      payload['recordedFlows'] as Map,
    );
    expect(recordedFlows.keys, ['gesture']);
    expect(
      Map<String, dynamic>.from(recordedFlows['gesture'] as Map)['actions'],
      isNotEmpty,
    );
  });

  test(
    'round trip restores images and rewrites recorded-flow collisions',
    () async {
      final sourceRecorder = TouchRecorderService(
        flowDirectory: Directory('${tempDir.path}/source_recordings'),
      );
      await sourceRecorder.saveFlow(recordedFlow('gesture'));
      final image = File('${tempDir.path}/template.png');
      await image.writeAsBytes([1, 2, 3, 4]);
      final sourceService = CustomFlowStorageService(
        touchRecorderService: sourceRecorder,
        baseDirectory: Directory('${tempDir.path}/source_custom'),
      );
      final packageFile = File('${tempDir.path}/flow.cflowpkg');
      await sourceService.exportFlowPackage(
        flow: nestedFlow(recordedName: 'gesture', imagePath: image.path),
        exportPath: packageFile.path,
      );

      final targetRecorder = TouchRecorderService(
        flowDirectory: Directory('${tempDir.path}/target_recordings'),
      );
      await targetRecorder.saveFlow(recordedFlow('gesture'));
      final targetService = CustomFlowStorageService(
        touchRecorderService: targetRecorder,
        baseDirectory: Directory('${tempDir.path}/target_custom'),
      );

      final result = await targetService.importFlowPackage(packageFile.path);

      expect(result.recordedFlowNameMap['gesture'], 'gesture_import_2');
      expect(result.importedRecordedFlowNames, ['gesture_import_2']);
      expect(
        collectRecordedNames(result.flow.steps),
        everyElement('gesture_import_2'),
      );
      final importedRecordedFlow = await targetRecorder.loadFlow(
        'gesture_import_2',
      );
      expect(importedRecordedFlow, isNotNull);
      expect(importedRecordedFlow!.screenWidth, 1600);
      expect(importedRecordedFlow.screenHeight, 900);
      expect(importedRecordedFlow.actions, hasLength(1));
      expect(
        importedRecordedFlow.actions.single.type,
        RecordedActionType.swipe,
      );
      expect(importedRecordedFlow.actions.single.startX, 100);
      expect(importedRecordedFlow.actions.single.startY, 200);
      expect(importedRecordedFlow.actions.single.endX, 300);
      expect(importedRecordedFlow.actions.single.endY, 400);
      final importedImageStep =
          result.flow.steps.first.children.first.children.last;
      expect(await File(importedImageStep.templatePath).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
    },
  );

  test('round trip restores multiple branch condition images', () async {
    final sourceRecorder = TouchRecorderService(
      flowDirectory: Directory('${tempDir.path}/source_recordings_multi'),
    );
    await sourceRecorder.saveFlow(recordedFlow('gesture'));
    final firstImage = File('${tempDir.path}/branch_first.png');
    final secondImage = File('${tempDir.path}/branch_second.png');
    await firstImage.writeAsBytes([10, 20, 30]);
    await secondImage.writeAsBytes([40, 50, 60, 70]);
    final sourceService = CustomFlowStorageService(
      touchRecorderService: sourceRecorder,
      baseDirectory: Directory('${tempDir.path}/source_custom_multi'),
    );
    final packageFile = File('${tempDir.path}/flow_multi.cflowpkg');

    await sourceService.exportFlowPackage(
      flow: nestedFlow(
        recordedName: 'gesture',
        branchImagePaths: [firstImage.path, secondImage.path],
      ),
      exportPath: packageFile.path,
    );

    final targetRecorder = TouchRecorderService(
      flowDirectory: Directory('${tempDir.path}/target_recordings_multi'),
    );
    final targetService = CustomFlowStorageService(
      touchRecorderService: targetRecorder,
      baseDirectory: Directory('${tempDir.path}/target_custom_multi'),
    );

    final result = await targetService.importFlowPackage(packageFile.path);
    final branchCase = result.flow.steps.last.branchCases.single;

    expect(branchCase.templateImages, hasLength(2));
    expect(branchCase.templateImages.first.id, 'case');
    expect(
      branchCase.templateName,
      branchCase.templateImages.first.templateName,
    );
    expect(
      await File(branchCase.templateImages.first.templatePath).readAsBytes(),
      [10, 20, 30],
    );
    expect(
      await File(branchCase.templateImages.last.templatePath).readAsBytes(),
      [40, 50, 60, 70],
    );
  });

  test(
    'round trip restores multi-image branch when case id differs from image ids',
    () async {
      final recorder = TouchRecorderService(
        flowDirectory: Directory('${tempDir.path}/recordings_distinct_ids'),
      );
      await recorder.saveFlow(recordedFlow('gesture'));
      final firstImage = File('${tempDir.path}/distinct_first.png')
        ..writeAsBytesSync([1, 2, 3]);
      final secondImage = File('${tempDir.path}/distinct_second.png')
        ..writeAsBytesSync([4, 5, 6]);
      final flow = nestedFlow(
        recordedName: 'gesture',
        branchImagePaths: [firstImage.path, secondImage.path],
      );
      final branch = flow.steps.last.branchCases.single;
      final distinctBranch = branch.copyWith(
        id: 'distinct_branch_case',
        templateImages: branch.templateImages
            .map(
              (image) => image.copyWith(
                id: 'distinct_image_${branch.templateImages.indexOf(image)}',
              ),
            )
            .toList(),
      );
      final distinctFlow = flow.copyWith(
        steps: [
          flow.steps.first,
          flow.steps.last.copyWith(branchCases: [distinctBranch]),
        ],
      );
      final sourceService = CustomFlowStorageService(
        touchRecorderService: recorder,
        baseDirectory: Directory('${tempDir.path}/custom_distinct_ids'),
      );
      final packageFile = File('${tempDir.path}/distinct_ids.cflowpkg');
      await sourceService.exportFlowPackage(
        flow: distinctFlow,
        exportPath: packageFile.path,
      );

      final targetService = CustomFlowStorageService(
        touchRecorderService: TouchRecorderService(
          flowDirectory: Directory(
            '${tempDir.path}/target_recordings_distinct_ids',
          ),
        ),
        baseDirectory: Directory('${tempDir.path}/target_custom_distinct_ids'),
      );
      final result = await targetService.importFlowPackage(packageFile.path);
      expect(
        result.flow.steps.last.branchCases.single.templateImages,
        hasLength(2),
      );
    },
  );

  test(
    'export rejects missing referenced recordings and local images',
    () async {
      final recorder = TouchRecorderService(
        flowDirectory: Directory('${tempDir.path}/recordings'),
      );
      final service = CustomFlowStorageService(
        touchRecorderService: recorder,
        baseDirectory: Directory('${tempDir.path}/custom'),
      );

      await expectLater(
        service.buildExportPayload(nestedFlow(recordedName: 'missing')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('未找到自定义流程引用的录制流程'),
          ),
        ),
      );

      await recorder.saveFlow(recordedFlow('gesture'));
      await expectLater(
        service.buildExportPayload(
          nestedFlow(
            recordedName: 'gesture',
            imagePath: '${tempDir.path}/missing.png',
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        service.buildExportPayload(
          nestedFlow(
            recordedName: 'gesture',
            branchImagePaths: ['${tempDir.path}/missing_branch.png'],
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('v2 import validates missing resources before creating files', () async {
    final recorder = TouchRecorderService(
      flowDirectory: Directory('${tempDir.path}/recordings'),
    );
    final service = CustomFlowStorageService(
      touchRecorderService: recorder,
      baseDirectory: Directory('${tempDir.path}/custom'),
    );
    final packageFile = File('${tempDir.path}/broken.cflowpkg');
    await packageFile.writeAsString(
      jsonEncode({
        'version': 2,
        'flow': nestedFlow(recordedName: 'missing').toJson(),
        'images': <String, dynamic>{},
        'recordedFlows': <String, dynamic>{},
      }),
    );

    await expectLater(
      service.importFlowPackage(packageFile.path),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('缺少录制流程资源'),
        ),
      ),
    );
    expect(await recorder.listFlowNames(), isEmpty);
    expect(await service.listFlowNames(), isEmpty);

    final missingImagePackage = File('${tempDir.path}/broken_image.cflowpkg');
    await missingImagePackage.writeAsString(
      jsonEncode({
        'version': 2,
        'flow': nestedFlow(
          recordedName: 'gesture',
          imagePath: 'template.png',
        ).toJson(),
        'images': <String, dynamic>{},
        'recordedFlows': {'gesture': recordedFlow('gesture').toJson()},
      }),
    );

    await expectLater(
      service.importFlowPackage(missingImagePackage.path),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('缺少图片资源'),
        ),
      ),
    );
    expect(await recorder.listFlowNames(), isEmpty);
    expect(await service.listFlowNames(), isEmpty);

    final missingBranchImagePackage = File(
      '${tempDir.path}/broken_branch_image.cflowpkg',
    );
    await missingBranchImagePackage.writeAsString(
      jsonEncode({
        'version': 2,
        'flow': nestedFlow(
          recordedName: 'gesture',
          branchImagePaths: ['branch.png'],
        ).toJson(),
        'images': <String, dynamic>{},
        'recordedFlows': {'gesture': recordedFlow('gesture').toJson()},
      }),
    );

    await expectLater(
      service.importFlowPackage(missingBranchImagePackage.path),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Branch'),
        ),
      ),
    );
    expect(await recorder.listFlowNames(), isEmpty);
    expect(await service.listFlowNames(), isEmpty);
  });

  test(
    'v1 packages reuse local recordings or fail with a clear error',
    () async {
      final packageFile = File('${tempDir.path}/legacy.cflowpkg');
      await packageFile.writeAsString(
        jsonEncode({
          'version': 1,
          'flow': nestedFlow(recordedName: 'legacy_gesture').toJson(),
          'images': <String, dynamic>{},
        }),
      );

      final existingRecorder = TouchRecorderService(
        flowDirectory: Directory('${tempDir.path}/existing_recordings'),
      );
      await existingRecorder.saveFlow(recordedFlow('legacy_gesture'));
      final existingService = CustomFlowStorageService(
        touchRecorderService: existingRecorder,
        baseDirectory: Directory('${tempDir.path}/existing_custom'),
      );
      final imported = await existingService.importFlowPackage(
        packageFile.path,
      );
      expect(imported.recordedFlowNameMap, {
        'legacy_gesture': 'legacy_gesture',
      });
      expect(imported.importedRecordedFlowNames, isEmpty);

      final missingRecorder = TouchRecorderService(
        flowDirectory: Directory('${tempDir.path}/missing_recordings'),
      );
      final missingService = CustomFlowStorageService(
        touchRecorderService: missingRecorder,
        baseDirectory: Directory('${tempDir.path}/missing_custom'),
      );
      await expectLater(
        missingService.importFlowPackage(packageFile.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('旧版流程包未包含录制流程'),
          ),
        ),
      );
      expect(await missingService.listFlowNames(), isEmpty);
    },
  );

  test('failed imports roll back recordings and staged flow assets', () async {
    final recorder = FailingSecondSaveRecorder(
      flowDirectory: Directory('${tempDir.path}/recordings'),
    );
    final customBase = Directory('${tempDir.path}/custom');
    final service = CustomFlowStorageService(
      touchRecorderService: recorder,
      baseDirectory: customBase,
    );
    final flow = CustomFlowDefinition(
      name: 'rollback_flow',
      createdAt: DateTime(2026, 6, 14),
      updatedAt: DateTime(2026, 6, 14),
      steps: [
        recordedStep('first', 'gesture_1'),
        recordedStep('second', 'gesture_2'),
      ],
    );
    final packageFile = File('${tempDir.path}/rollback.cflowpkg');
    await packageFile.writeAsString(
      jsonEncode({
        'version': 2,
        'flow': flow.toJson(),
        'images': <String, dynamic>{},
        'recordedFlows': {
          'gesture_1': recordedFlow('gesture_1').toJson(),
          'gesture_2': recordedFlow('gesture_2').toJson(),
        },
      }),
    );

    await expectLater(
      service.importFlowPackage(packageFile.path),
      throwsA(isA<StateError>()),
    );

    expect(await recorder.listFlowNames(), isEmpty);
    expect(await service.listFlowNames(), isEmpty);
    final assetRoot = Directory('${customBase.path}/custom_flows/_assets');
    final remainingAssets = await assetRoot.exists()
        ? await assetRoot.list().toList()
        : const <FileSystemEntity>[];
    expect(remainingAssets, isEmpty);
  });
}
