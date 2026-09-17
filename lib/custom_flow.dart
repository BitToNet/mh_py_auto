import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'recording_flow.dart';

enum CustomFlowStepType {
  wait,
  imageTap,
  ocrTap,
  coordinateTap,
  pasteText,
  waitImageState,
  imageBranch,
  imagePositionBranch,
  loopBlock,
  flowGroup,
  gameMode,
  recordedFlow,
  restartActivity,
  shutdownComputer,
}

enum CustomFlowImageSource { asset, localFile }

enum CustomFlowRecognitionMode { image, text }

enum CustomFlowWaitTargetState { appear, disappear }

enum CustomFlowLoopMode { fixedCount, imageCondition, textLines }

enum CustomFlowLoopImageAction { continueOnMatch, stopOnMatch }

enum CustomFlowOcrMatchMode { contains, exact, regex }

enum CustomFlowDeviceScope { all, first, others }

List<String> splitCustomFlowTextLines(String text) {
  return const LineSplitter()
      .convert(text)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
}

String resolveCustomFlowPasteText(
  CustomFlowStep step, {
  String? parentLoopText,
}) {
  if (!step.useParentLoopText) {
    return step.textContent;
  }
  if (parentLoopText == null) {
    throw StateError('粘贴文字步骤设置为使用上层文本，但当前没有可用的文本循环内容');
  }
  return parentLoopText;
}

bool customFlowContainsPasteText(List<CustomFlowStep> steps) {
  for (final step in steps) {
    if (step.type == CustomFlowStepType.pasteText ||
        customFlowContainsPasteText(step.children) ||
        customFlowContainsPasteText(step.fallbackChildren)) {
      return true;
    }
    for (final branchCase in step.branchCases) {
      if (customFlowContainsPasteText(branchCase.steps)) {
        return true;
      }
    }
  }
  return false;
}

class CustomFlowBranchImage {
  const CustomFlowBranchImage({
    required this.id,
    this.templateName = '',
    this.imageSource = CustomFlowImageSource.localFile,
    this.templatePath = '',
  });

  final String id;
  final String templateName;
  final CustomFlowImageSource imageSource;
  final String templatePath;

  CustomFlowBranchImage copyWith({
    String? id,
    String? templateName,
    CustomFlowImageSource? imageSource,
    String? templatePath,
  }) {
    return CustomFlowBranchImage(
      id: id ?? this.id,
      templateName: templateName ?? this.templateName,
      imageSource: imageSource ?? this.imageSource,
      templatePath: templatePath ?? this.templatePath,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'templateName': templateName,
    'imageSource': imageSource.name,
    'templatePath': templatePath,
  };

  factory CustomFlowBranchImage.fromJson(
    Map<String, dynamic> json, {
    String? fallbackId,
  }) {
    return CustomFlowBranchImage(
      id: json['id']?.toString().trim().isNotEmpty == true
          ? json['id']!.toString().trim()
          : (fallbackId ?? DateTime.now().microsecondsSinceEpoch.toString()),
      templateName: json['templateName']?.toString() ?? '',
      imageSource: CustomFlowImageSource.values.firstWhere(
        (item) => item.name == json['imageSource'],
        orElse: () => CustomFlowImageSource.asset,
      ),
      templatePath: json['templatePath']?.toString() ?? '',
    );
  }
}

class CustomFlowBranchCase {
  const CustomFlowBranchCase({
    required this.id,
    this.label = '',
    this.recognitionMode = CustomFlowRecognitionMode.image,
    this.templateName = '',
    this.imageSource = CustomFlowImageSource.localFile,
    this.templatePath = '',
    this.templateImages = const [],
    this.confidence = 0.68,
    this.ocrTargetText = '',
    this.ocrMatchMode = CustomFlowOcrMatchMode.contains,
    this.ocrRegionLeft = -1,
    this.ocrRegionTop = -1,
    this.ocrRegionRight = -1,
    this.ocrRegionBottom = -1,
    this.centerXMin,
    this.centerXMax,
    this.centerYMin,
    this.centerYMax,
    this.steps = const [],
  });

  final String id;
  final String label;
  final CustomFlowRecognitionMode recognitionMode;
  final String templateName;
  final CustomFlowImageSource imageSource;
  final String templatePath;
  final List<CustomFlowBranchImage> templateImages;
  final double confidence;
  final String ocrTargetText;
  final CustomFlowOcrMatchMode ocrMatchMode;
  final int ocrRegionLeft;
  final int ocrRegionTop;
  final int ocrRegionRight;
  final int ocrRegionBottom;
  final double? centerXMin;
  final double? centerXMax;
  final double? centerYMin;
  final double? centerYMax;
  final List<CustomFlowStep> steps;

  CustomFlowBranchCase copyWith({
    String? id,
    String? label,
    CustomFlowRecognitionMode? recognitionMode,
    String? templateName,
    CustomFlowImageSource? imageSource,
    String? templatePath,
    List<CustomFlowBranchImage>? templateImages,
    double? confidence,
    String? ocrTargetText,
    CustomFlowOcrMatchMode? ocrMatchMode,
    int? ocrRegionLeft,
    int? ocrRegionTop,
    int? ocrRegionRight,
    int? ocrRegionBottom,
    double? centerXMin,
    double? centerXMax,
    double? centerYMin,
    double? centerYMax,
    List<CustomFlowStep>? steps,
  }) {
    final imageListOverridden = templateImages != null;
    final legacyImageOverridden =
        templateName != null || imageSource != null || templatePath != null;
    var nextTemplateImages = templateImages ?? this.templateImages;
    if (legacyImageOverridden) {
      final primary = CustomFlowBranchImage(
        id: nextTemplateImages.isNotEmpty
            ? nextTemplateImages.first.id
            : (id ?? this.id),
        templateName:
            templateName ??
            (nextTemplateImages.isNotEmpty
                ? nextTemplateImages.first.templateName
                : this.templateName),
        imageSource:
            imageSource ??
            (nextTemplateImages.isNotEmpty
                ? nextTemplateImages.first.imageSource
                : this.imageSource),
        templatePath:
            templatePath ??
            (nextTemplateImages.isNotEmpty
                ? nextTemplateImages.first.templatePath
                : this.templatePath),
      );
      nextTemplateImages = nextTemplateImages.isEmpty
          ? [primary]
          : [primary, ...nextTemplateImages.skip(1)];
    }
    final primaryImage = nextTemplateImages.isNotEmpty
        ? nextTemplateImages.first
        : null;
    return CustomFlowBranchCase(
      id: id ?? this.id,
      label: label ?? this.label,
      recognitionMode: recognitionMode ?? this.recognitionMode,
      templateName:
          primaryImage?.templateName ??
          (imageListOverridden ? '' : (templateName ?? this.templateName)),
      imageSource:
          primaryImage?.imageSource ??
          (imageListOverridden
              ? CustomFlowImageSource.localFile
              : (imageSource ?? this.imageSource)),
      templatePath:
          primaryImage?.templatePath ??
          (imageListOverridden ? '' : (templatePath ?? this.templatePath)),
      templateImages: nextTemplateImages,
      confidence: confidence ?? this.confidence,
      ocrTargetText: ocrTargetText ?? this.ocrTargetText,
      ocrMatchMode: ocrMatchMode ?? this.ocrMatchMode,
      ocrRegionLeft: ocrRegionLeft ?? this.ocrRegionLeft,
      ocrRegionTop: ocrRegionTop ?? this.ocrRegionTop,
      ocrRegionRight: ocrRegionRight ?? this.ocrRegionRight,
      ocrRegionBottom: ocrRegionBottom ?? this.ocrRegionBottom,
      centerXMin: centerXMin ?? this.centerXMin,
      centerXMax: centerXMax ?? this.centerXMax,
      centerYMin: centerYMin ?? this.centerYMin,
      centerYMax: centerYMax ?? this.centerYMax,
      steps: steps ?? this.steps,
    );
  }

  List<CustomFlowBranchImage> get effectiveTemplateImages {
    if (templateImages.isNotEmpty) {
      return templateImages;
    }
    if (templateName.trim().isEmpty && templatePath.trim().isEmpty) {
      return const [];
    }
    return [
      CustomFlowBranchImage(
        id: id,
        templateName: templateName,
        imageSource: imageSource,
        templatePath: templatePath,
      ),
    ];
  }

  Map<String, dynamic> toJson() {
    final images = effectiveTemplateImages;
    final primaryImage = images.isNotEmpty ? images.first : null;
    return {
      'id': id,
      'label': label,
      'recognitionMode': recognitionMode.name,
      'templateName': primaryImage?.templateName ?? templateName,
      'imageSource': (primaryImage?.imageSource ?? imageSource).name,
      'templatePath': primaryImage?.templatePath ?? templatePath,
      'templateImages': images.map((item) => item.toJson()).toList(),
      'confidence': confidence,
      'ocrTargetText': ocrTargetText,
      'ocrMatchMode': ocrMatchMode.name,
      'ocrRegionLeft': ocrRegionLeft,
      'ocrRegionTop': ocrRegionTop,
      'ocrRegionRight': ocrRegionRight,
      'ocrRegionBottom': ocrRegionBottom,
      'centerXMin': centerXMin,
      'centerXMax': centerXMax,
      'centerYMin': centerYMin,
      'centerYMax': centerYMax,
      'steps': steps.map((item) => item.toJson()).toList(),
    };
  }

  factory CustomFlowBranchCase.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'] as List<dynamic>? ?? const [];
    final branchId =
        json['id']?.toString() ??
        DateTime.now().microsecondsSinceEpoch.toString();
    final rawImages = json['templateImages'] as List<dynamic>? ?? const [];
    final templateImages = <CustomFlowBranchImage>[];
    if (rawImages.isNotEmpty) {
      for (var index = 0; index < rawImages.length; index++) {
        templateImages.add(
          CustomFlowBranchImage.fromJson(
            Map<String, dynamic>.from(rawImages[index] as Map),
            fallbackId: index == 0 ? branchId : '${branchId}_image_$index',
          ),
        );
      }
    } else {
      final legacyTemplateName = json['templateName']?.toString() ?? '';
      final legacyTemplatePath = json['templatePath']?.toString() ?? '';
      if (legacyTemplateName.trim().isNotEmpty ||
          legacyTemplatePath.trim().isNotEmpty) {
        templateImages.add(
          CustomFlowBranchImage(
            id: branchId,
            templateName: legacyTemplateName,
            imageSource: CustomFlowImageSource.values.firstWhere(
              (item) => item.name == json['imageSource'],
              orElse: () => CustomFlowImageSource.asset,
            ),
            templatePath: legacyTemplatePath,
          ),
        );
      }
    }
    final primaryImage = templateImages.isNotEmpty
        ? templateImages.first
        : null;
    return CustomFlowBranchCase(
      id: branchId,
      label: json['label']?.toString() ?? '',
      recognitionMode: CustomFlowRecognitionMode.values.firstWhere(
        (item) => item.name == json['recognitionMode'],
        orElse: () => CustomFlowRecognitionMode.image,
      ),
      templateName:
          primaryImage?.templateName ?? json['templateName']?.toString() ?? '',
      imageSource:
          primaryImage?.imageSource ??
          CustomFlowImageSource.values.firstWhere(
            (item) => item.name == json['imageSource'],
            orElse: () => CustomFlowImageSource.asset,
          ),
      templatePath:
          primaryImage?.templatePath ?? json['templatePath']?.toString() ?? '',
      templateImages: templateImages,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.68,
      ocrTargetText: json['ocrTargetText']?.toString() ?? '',
      ocrMatchMode: CustomFlowOcrMatchMode.values.firstWhere(
        (item) => item.name == json['ocrMatchMode'],
        orElse: () => CustomFlowOcrMatchMode.contains,
      ),
      ocrRegionLeft: (json['ocrRegionLeft'] as num?)?.toInt() ?? -1,
      ocrRegionTop: (json['ocrRegionTop'] as num?)?.toInt() ?? -1,
      ocrRegionRight: (json['ocrRegionRight'] as num?)?.toInt() ?? -1,
      ocrRegionBottom: (json['ocrRegionBottom'] as num?)?.toInt() ?? -1,
      centerXMin: (json['centerXMin'] as num?)?.toDouble(),
      centerXMax: (json['centerXMax'] as num?)?.toDouble(),
      centerYMin: (json['centerYMin'] as num?)?.toDouble(),
      centerYMax: (json['centerYMax'] as num?)?.toDouble(),
      steps: rawSteps
          .map(
            (item) => CustomFlowStep.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
    );
  }
}

class CustomFlowStep {
  const CustomFlowStep({
    required this.id,
    required this.type,
    required this.label,
    this.deviceScope = CustomFlowDeviceScope.all,
    this.waitMinSeconds = 0.8,
    this.waitMaxSeconds = 1.2,
    this.recognitionMode = CustomFlowRecognitionMode.image,
    this.templateName = '',
    this.imageSource = CustomFlowImageSource.localFile,
    this.templatePath = '',
    this.confidence = 0.68,
    this.maxAttempts = 3,
    this.retryIntervalSeconds = 1.2,
    this.randomOffsetPx = 12,
    this.postWaitMinSeconds = 0.8,
    this.postWaitMaxSeconds = 1.5,
    this.continueOnFailure = false,
    this.ocrTargetText = '',
    this.ocrMatchMode = CustomFlowOcrMatchMode.contains,
    this.ocrRegionLeft = -1,
    this.ocrRegionTop = -1,
    this.ocrRegionRight = -1,
    this.ocrRegionBottom = -1,
    this.ocrMatchIndex = 1,
    this.ocrClickOffsetX = 0,
    this.ocrClickOffsetY = 0,
    this.x = 0,
    this.y = 0,
    this.useBranchDetectedPosition = false,
    this.branchPositionOffsetX = 0,
    this.branchPositionOffsetY = 0,
    this.textContent = '',
    this.useParentLoopText = false,
    this.waitTargetState = CustomFlowWaitTargetState.appear,
    this.timeoutSeconds = 15,
    this.pollIntervalSeconds = 1.2,
    this.children = const [],
    this.branchCases = const [],
    this.fallbackChildren = const [],
    this.reuseParentBranchScreenshot = false,
    this.loopCount = 1,
    this.loopMode = CustomFlowLoopMode.fixedCount,
    this.loopImageAction = CustomFlowLoopImageAction.stopOnMatch,
    this.loopTextContent = '',
    this.gameModeName = '寮突破',
    this.gameModeConfigJson = '',
    this.gameModeDeviceIds = const [],
    this.recordedFlowName = '',
    this.recordedFlowLoopCount = 1,
    this.activityComponent = '',
    this.shutdownDelaySeconds = 60,
  });

  final String id;
  final CustomFlowStepType type;
  final String label;
  final CustomFlowDeviceScope deviceScope;
  final double waitMinSeconds;
  final double waitMaxSeconds;
  final CustomFlowRecognitionMode recognitionMode;
  final String templateName;
  final CustomFlowImageSource imageSource;
  final String templatePath;
  final double confidence;
  final int maxAttempts;
  final double retryIntervalSeconds;
  final int randomOffsetPx;
  final double postWaitMinSeconds;
  final double postWaitMaxSeconds;
  final bool continueOnFailure;
  final String ocrTargetText;
  final CustomFlowOcrMatchMode ocrMatchMode;
  final int ocrRegionLeft;
  final int ocrRegionTop;
  final int ocrRegionRight;
  final int ocrRegionBottom;
  final int ocrMatchIndex;
  final int ocrClickOffsetX;
  final int ocrClickOffsetY;
  final int x;
  final int y;
  final bool useBranchDetectedPosition;
  final int branchPositionOffsetX;
  final int branchPositionOffsetY;
  final String textContent;
  final bool useParentLoopText;
  final CustomFlowWaitTargetState waitTargetState;
  final double timeoutSeconds;
  final double pollIntervalSeconds;
  final List<CustomFlowStep> children;
  final List<CustomFlowBranchCase> branchCases;
  final List<CustomFlowStep> fallbackChildren;
  final bool reuseParentBranchScreenshot;
  final int loopCount;
  final CustomFlowLoopMode loopMode;
  final CustomFlowLoopImageAction loopImageAction;
  final String loopTextContent;
  final String gameModeName;
  final String gameModeConfigJson;
  final List<String> gameModeDeviceIds;
  final String recordedFlowName;
  final int recordedFlowLoopCount;
  final String activityComponent;
  final double shutdownDelaySeconds;

  CustomFlowStep copyWith({
    String? id,
    CustomFlowStepType? type,
    String? label,
    CustomFlowDeviceScope? deviceScope,
    double? waitMinSeconds,
    double? waitMaxSeconds,
    CustomFlowRecognitionMode? recognitionMode,
    String? templateName,
    CustomFlowImageSource? imageSource,
    String? templatePath,
    double? confidence,
    int? maxAttempts,
    double? retryIntervalSeconds,
    int? randomOffsetPx,
    double? postWaitMinSeconds,
    double? postWaitMaxSeconds,
    bool? continueOnFailure,
    String? ocrTargetText,
    CustomFlowOcrMatchMode? ocrMatchMode,
    int? ocrRegionLeft,
    int? ocrRegionTop,
    int? ocrRegionRight,
    int? ocrRegionBottom,
    int? ocrMatchIndex,
    int? ocrClickOffsetX,
    int? ocrClickOffsetY,
    int? x,
    int? y,
    bool? useBranchDetectedPosition,
    int? branchPositionOffsetX,
    int? branchPositionOffsetY,
    String? textContent,
    bool? useParentLoopText,
    CustomFlowWaitTargetState? waitTargetState,
    double? timeoutSeconds,
    double? pollIntervalSeconds,
    List<CustomFlowStep>? children,
    List<CustomFlowBranchCase>? branchCases,
    List<CustomFlowStep>? fallbackChildren,
    bool? reuseParentBranchScreenshot,
    int? loopCount,
    CustomFlowLoopMode? loopMode,
    CustomFlowLoopImageAction? loopImageAction,
    String? loopTextContent,
    String? gameModeName,
    String? gameModeConfigJson,
    List<String>? gameModeDeviceIds,
    String? recordedFlowName,
    int? recordedFlowLoopCount,
    String? activityComponent,
    double? shutdownDelaySeconds,
  }) {
    return CustomFlowStep(
      id: id ?? this.id,
      type: type ?? this.type,
      label: label ?? this.label,
      deviceScope: deviceScope ?? this.deviceScope,
      waitMinSeconds: waitMinSeconds ?? this.waitMinSeconds,
      waitMaxSeconds: waitMaxSeconds ?? this.waitMaxSeconds,
      recognitionMode: recognitionMode ?? this.recognitionMode,
      templateName: templateName ?? this.templateName,
      imageSource: imageSource ?? this.imageSource,
      templatePath: templatePath ?? this.templatePath,
      confidence: confidence ?? this.confidence,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      retryIntervalSeconds: retryIntervalSeconds ?? this.retryIntervalSeconds,
      randomOffsetPx: randomOffsetPx ?? this.randomOffsetPx,
      postWaitMinSeconds: postWaitMinSeconds ?? this.postWaitMinSeconds,
      postWaitMaxSeconds: postWaitMaxSeconds ?? this.postWaitMaxSeconds,
      continueOnFailure: continueOnFailure ?? this.continueOnFailure,
      ocrTargetText: ocrTargetText ?? this.ocrTargetText,
      ocrMatchMode: ocrMatchMode ?? this.ocrMatchMode,
      ocrRegionLeft: ocrRegionLeft ?? this.ocrRegionLeft,
      ocrRegionTop: ocrRegionTop ?? this.ocrRegionTop,
      ocrRegionRight: ocrRegionRight ?? this.ocrRegionRight,
      ocrRegionBottom: ocrRegionBottom ?? this.ocrRegionBottom,
      ocrMatchIndex: ocrMatchIndex ?? this.ocrMatchIndex,
      ocrClickOffsetX: ocrClickOffsetX ?? this.ocrClickOffsetX,
      ocrClickOffsetY: ocrClickOffsetY ?? this.ocrClickOffsetY,
      x: x ?? this.x,
      y: y ?? this.y,
      useBranchDetectedPosition:
          useBranchDetectedPosition ?? this.useBranchDetectedPosition,
      branchPositionOffsetX:
          branchPositionOffsetX ?? this.branchPositionOffsetX,
      branchPositionOffsetY:
          branchPositionOffsetY ?? this.branchPositionOffsetY,
      textContent: textContent ?? this.textContent,
      useParentLoopText: useParentLoopText ?? this.useParentLoopText,
      waitTargetState: waitTargetState ?? this.waitTargetState,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
      children: children ?? this.children,
      branchCases: branchCases ?? this.branchCases,
      fallbackChildren: fallbackChildren ?? this.fallbackChildren,
      reuseParentBranchScreenshot:
          reuseParentBranchScreenshot ?? this.reuseParentBranchScreenshot,
      loopCount: loopCount ?? this.loopCount,
      loopMode: loopMode ?? this.loopMode,
      loopImageAction: loopImageAction ?? this.loopImageAction,
      loopTextContent: loopTextContent ?? this.loopTextContent,
      gameModeName: gameModeName ?? this.gameModeName,
      gameModeConfigJson: gameModeConfigJson ?? this.gameModeConfigJson,
      gameModeDeviceIds: gameModeDeviceIds ?? this.gameModeDeviceIds,
      recordedFlowName: recordedFlowName ?? this.recordedFlowName,
      recordedFlowLoopCount:
          recordedFlowLoopCount ?? this.recordedFlowLoopCount,
      activityComponent: activityComponent ?? this.activityComponent,
      shutdownDelaySeconds: shutdownDelaySeconds ?? this.shutdownDelaySeconds,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'label': label,
    'deviceScope': deviceScope.name,
    'waitMinSeconds': waitMinSeconds,
    'waitMaxSeconds': waitMaxSeconds,
    'waitMinMs': (waitMinSeconds * 1000).round(),
    'waitMaxMs': (waitMaxSeconds * 1000).round(),
    'recognitionMode': recognitionMode.name,
    'templateName': templateName,
    'imageSource': imageSource.name,
    'templatePath': templatePath,
    'confidence': confidence,
    'maxAttempts': maxAttempts,
    'retryIntervalSeconds': retryIntervalSeconds,
    'retryIntervalMs': (retryIntervalSeconds * 1000).round(),
    'randomOffsetPx': randomOffsetPx,
    'postWaitMinSeconds': postWaitMinSeconds,
    'postWaitMaxSeconds': postWaitMaxSeconds,
    'postWaitMinMs': (postWaitMinSeconds * 1000).round(),
    'postWaitMaxMs': (postWaitMaxSeconds * 1000).round(),
    'continueOnFailure': continueOnFailure,
    'ocrTargetText': ocrTargetText,
    'ocrMatchMode': ocrMatchMode.name,
    'ocrRegionLeft': ocrRegionLeft,
    'ocrRegionTop': ocrRegionTop,
    'ocrRegionRight': ocrRegionRight,
    'ocrRegionBottom': ocrRegionBottom,
    'ocrMatchIndex': ocrMatchIndex,
    'ocrClickOffsetX': ocrClickOffsetX,
    'ocrClickOffsetY': ocrClickOffsetY,
    'x': x,
    'y': y,
    'useBranchDetectedPosition': useBranchDetectedPosition,
    'branchPositionOffsetX': branchPositionOffsetX,
    'branchPositionOffsetY': branchPositionOffsetY,
    'textContent': textContent,
    'useParentLoopText': useParentLoopText,
    'waitTargetState': waitTargetState.name,
    'timeoutSeconds': timeoutSeconds,
    'pollIntervalSeconds': pollIntervalSeconds,
    'timeoutMs': (timeoutSeconds * 1000).round(),
    'pollIntervalMs': (pollIntervalSeconds * 1000).round(),
    'children': children.map((item) => item.toJson()).toList(),
    'branchCases': branchCases.map((item) => item.toJson()).toList(),
    'fallbackChildren': fallbackChildren.map((item) => item.toJson()).toList(),
    'reuseParentBranchScreenshot': reuseParentBranchScreenshot,
    'loopCount': loopCount,
    'loopMode': loopMode.name,
    'loopImageAction': loopImageAction.name,
    'loopTextContent': loopTextContent,
    'gameModeName': gameModeName,
    'gameModeConfigJson': gameModeConfigJson,
    'gameModeDeviceIds': gameModeDeviceIds,
    'recordedFlowName': recordedFlowName,
    'recordedFlowLoopCount': recordedFlowLoopCount,
    'activityComponent': activityComponent,
    'shutdownDelaySeconds': shutdownDelaySeconds,
    'shutdownDelayMs': (shutdownDelaySeconds * 1000).round(),
  };

  factory CustomFlowStep.fromJson(Map<String, dynamic> json) {
    final rawChildren = json['children'] as List<dynamic>? ?? const [];
    final rawBranchCases = json['branchCases'] as List<dynamic>? ?? const [];
    final rawFallbackChildren =
        json['fallbackChildren'] as List<dynamic>? ?? const [];
    final rawGameModeDeviceIds =
        json['gameModeDeviceIds'] as List<dynamic>? ?? const [];
    final rawType = json['type']?.toString();
    final migratedType = rawType == 'ocrTap'
        ? CustomFlowStepType.imageTap
        : null;
    final migratedRecognitionMode = rawType == 'ocrTap'
        ? CustomFlowRecognitionMode.text
        : null;
    return CustomFlowStep(
      id:
          json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      type:
          migratedType ??
          CustomFlowStepType.values.firstWhere(
            (item) => item.name == rawType,
            orElse: () => CustomFlowStepType.wait,
          ),
      label: json['label']?.toString() ?? '',
      deviceScope: CustomFlowDeviceScope.values.firstWhere(
        (item) => item.name == json['deviceScope'],
        orElse: () => CustomFlowDeviceScope.all,
      ),
      waitMinSeconds:
          (json['waitMinSeconds'] as num?)?.toDouble() ??
          ((json['waitMinMs'] as num?)?.toDouble() ?? 800) / 1000.0,
      waitMaxSeconds:
          (json['waitMaxSeconds'] as num?)?.toDouble() ??
          ((json['waitMaxMs'] as num?)?.toDouble() ?? 1200) / 1000.0,
      recognitionMode:
          migratedRecognitionMode ??
          CustomFlowRecognitionMode.values.firstWhere(
            (item) => item.name == json['recognitionMode'],
            orElse: () => CustomFlowRecognitionMode.image,
          ),
      templateName: json['templateName']?.toString() ?? '',
      imageSource: CustomFlowImageSource.values.firstWhere(
        (item) => item.name == json['imageSource'],
        orElse: () => CustomFlowImageSource.asset,
      ),
      templatePath: json['templatePath']?.toString() ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.68,
      maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 3,
      retryIntervalSeconds:
          (json['retryIntervalSeconds'] as num?)?.toDouble() ??
          ((json['retryIntervalMs'] as num?)?.toDouble() ?? 1200) / 1000.0,
      randomOffsetPx: (json['randomOffsetPx'] as num?)?.toInt() ?? 12,
      postWaitMinSeconds:
          (json['postWaitMinSeconds'] as num?)?.toDouble() ??
          ((json['postWaitMinMs'] as num?)?.toDouble() ?? 800) / 1000.0,
      postWaitMaxSeconds:
          (json['postWaitMaxSeconds'] as num?)?.toDouble() ??
          ((json['postWaitMaxMs'] as num?)?.toDouble() ?? 1500) / 1000.0,
      continueOnFailure: json['continueOnFailure'] as bool? ?? false,
      ocrTargetText: json['ocrTargetText']?.toString() ?? '',
      ocrMatchMode: CustomFlowOcrMatchMode.values.firstWhere(
        (item) => item.name == json['ocrMatchMode'],
        orElse: () => CustomFlowOcrMatchMode.contains,
      ),
      ocrRegionLeft: (json['ocrRegionLeft'] as num?)?.toInt() ?? -1,
      ocrRegionTop: (json['ocrRegionTop'] as num?)?.toInt() ?? -1,
      ocrRegionRight: (json['ocrRegionRight'] as num?)?.toInt() ?? -1,
      ocrRegionBottom: (json['ocrRegionBottom'] as num?)?.toInt() ?? -1,
      ocrMatchIndex: (json['ocrMatchIndex'] as num?)?.toInt() ?? 1,
      ocrClickOffsetX: (json['ocrClickOffsetX'] as num?)?.toInt() ?? 0,
      ocrClickOffsetY: (json['ocrClickOffsetY'] as num?)?.toInt() ?? 0,
      x: (json['x'] as num?)?.toInt() ?? 0,
      y: (json['y'] as num?)?.toInt() ?? 0,
      useBranchDetectedPosition:
          json['useBranchDetectedPosition'] as bool? ?? false,
      branchPositionOffsetX:
          (json['branchPositionOffsetX'] as num?)?.toInt() ?? 0,
      branchPositionOffsetY:
          (json['branchPositionOffsetY'] as num?)?.toInt() ?? 0,
      textContent: json['textContent']?.toString() ?? '',
      useParentLoopText: json['useParentLoopText'] as bool? ?? false,
      waitTargetState: CustomFlowWaitTargetState.values.firstWhere(
        (item) => item.name == json['waitTargetState'],
        orElse: () => CustomFlowWaitTargetState.appear,
      ),
      timeoutSeconds:
          (json['timeoutSeconds'] as num?)?.toDouble() ??
          ((json['timeoutMs'] as num?)?.toDouble() ?? 15000) / 1000.0,
      pollIntervalSeconds:
          (json['pollIntervalSeconds'] as num?)?.toDouble() ??
          ((json['pollIntervalMs'] as num?)?.toDouble() ?? 1200) / 1000.0,
      children: rawChildren
          .map(
            (item) => CustomFlowStep.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      branchCases: rawBranchCases
          .map(
            (item) =>
                CustomFlowBranchCase.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      fallbackChildren: rawFallbackChildren
          .map(
            (item) => CustomFlowStep.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      reuseParentBranchScreenshot:
          json['reuseParentBranchScreenshot'] as bool? ?? false,
      loopCount: (json['loopCount'] as num?)?.toInt() ?? 1,
      loopMode: CustomFlowLoopMode.values.firstWhere(
        (item) => item.name == json['loopMode'],
        orElse: () => CustomFlowLoopMode.fixedCount,
      ),
      loopImageAction: CustomFlowLoopImageAction.values.firstWhere(
        (item) => item.name == json['loopImageAction'],
        orElse: () => CustomFlowLoopImageAction.stopOnMatch,
      ),
      loopTextContent: json['loopTextContent']?.toString() ?? '',
      gameModeName: json['gameModeName']?.toString() ?? '寮突破',
      gameModeConfigJson: json['gameModeConfigJson']?.toString() ?? '',
      gameModeDeviceIds: rawGameModeDeviceIds
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(),
      recordedFlowName: json['recordedFlowName']?.toString() ?? '',
      recordedFlowLoopCount:
          (json['recordedFlowLoopCount'] as num?)?.toInt() ?? 1,
      activityComponent: json['activityComponent']?.toString() ?? '',
      shutdownDelaySeconds:
          (json['shutdownDelaySeconds'] as num?)?.toDouble() ??
          ((json['shutdownDelayMs'] as num?)?.toDouble() ?? 60000) / 1000.0,
    );
  }
}

class CustomFlowDefinition {
  const CustomFlowDefinition({
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.steps,
  });

  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<CustomFlowStep> steps;

  CustomFlowDefinition copyWith({
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<CustomFlowStep>? steps,
  }) {
    return CustomFlowDefinition(
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      steps: steps ?? this.steps,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'steps': steps.map((item) => item.toJson()).toList(),
  };

  factory CustomFlowDefinition.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'] as List<dynamic>? ?? const [];
    return CustomFlowDefinition(
      name: json['name']?.toString() ?? 'custom_flow',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      steps: rawSteps
          .map(
            (item) => CustomFlowStep.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
    );
  }
}

class RecordedFlowConversionOptions {
  const RecordedFlowConversionOptions({
    required this.randomOffsetPx,
    required this.waitVariationSeconds,
    this.nameSuffix = '_固定点击转换',
  });

  final int randomOffsetPx;
  final double waitVariationSeconds;
  final String nameSuffix;
}

class RecordedFlowConversionResult {
  const RecordedFlowConversionResult({
    required this.flow,
    required this.convertedTapCount,
    required this.skippedActionCount,
  });

  final CustomFlowDefinition flow;
  final int convertedTapCount;
  final int skippedActionCount;
}

class RecordedFlowToCustomFlowConverter {
  const RecordedFlowToCustomFlowConverter();

  RecordedFlowConversionResult convert({
    required RecordedFlow recordedFlow,
    required RecordedFlowConversionOptions options,
    DateTime? convertedAt,
  }) {
    final now = convertedAt ?? DateTime.now();
    final steps = <CustomFlowStep>[];
    var skippedActionCount = 0;
    var pendingWaitMs = 0;

    for (final action in recordedFlow.actions) {
      if (action.type == RecordedActionType.tap) {
        if (steps.isNotEmpty) {
          pendingWaitMs += max(action.delayMs, 0);
          final waitSeconds = pendingWaitMs / 1000.0;
          final waitVariation = max(options.waitVariationSeconds, 0);
          steps[steps.length - 1] = steps.last.copyWith(
            postWaitMinSeconds: waitSeconds + waitVariation,
            postWaitMaxSeconds: waitSeconds + waitVariation * 2,
          );
        }

        steps.add(
          CustomFlowStep(
            id: 'recorded_tap_${now.microsecondsSinceEpoch}_${steps.length + 1}',
            type: CustomFlowStepType.coordinateTap,
            label: '录制点击 ${steps.length + 1}',
            // 录制坐标原样保留：时空客户端 Windows 版录到的就是 1600×900 设计坐标，
            // 旧 Android 录制也是按录制时的 screenWidth/screenHeight 保存的原始坐标。
            // 缩放交给流程运行器（回放时按目标设备换算），此处不再做旋转/缩放，
            // 否则 Windows 录制转固定点击会点偏（历史遗留的竖屏旋转映射已移除）。
            x: action.startX,
            y: action.startY,
            randomOffsetPx: max(options.randomOffsetPx, 0),
            postWaitMinSeconds: 0,
            postWaitMaxSeconds: 0,
          ),
        );
        pendingWaitMs = 0;
        continue;
      }

      skippedActionCount += 1;
      if (steps.isNotEmpty) {
        pendingWaitMs += max(action.delayMs, 0);
        pendingWaitMs += max(action.durationMs, 0);
      }
    }

    return RecordedFlowConversionResult(
      flow: CustomFlowDefinition(
        name: '${recordedFlow.name}${options.nameSuffix}',
        createdAt: now,
        updatedAt: now,
        steps: steps,
      ),
      convertedTapCount: steps.length,
      skippedActionCount: skippedActionCount,
    );
  }
}

class SavedCustomFlowResult {
  const SavedCustomFlowResult({required this.flow, required this.filePath});

  final CustomFlowDefinition flow;
  final String filePath;
}

class CustomFlowImportResult {
  const CustomFlowImportResult({
    required this.flow,
    required this.recordedFlowNameMap,
    required this.importedRecordedFlowNames,
  });

  final CustomFlowDefinition flow;
  final Map<String, String> recordedFlowNameMap;
  final List<String> importedRecordedFlowNames;
}

class CustomFlowStorageService {
  static const String exportFileExtension = 'cflowpkg';
  static const int currentPackageVersion = 2;

  CustomFlowStorageService({
    TouchRecorderService? touchRecorderService,
    Directory? baseDirectory,
  }) : _touchRecorderService = touchRecorderService ?? TouchRecorderService(),
       _configuredBaseDirectory = baseDirectory;

  final TouchRecorderService _touchRecorderService;
  final Directory? _configuredBaseDirectory;

  Future<Directory> _ensureCustomFlowBaseDirectory() async {
    final configuredDirectory = _configuredBaseDirectory;
    if (configuredDirectory != null) {
      if (!await configuredDirectory.exists()) {
        await configuredDirectory.create(recursive: true);
      }
      return configuredDirectory;
    }

    if (Platform.isWindows) {
      final appDataPath = Platform.environment['APPDATA']?.trim();
      if (appDataPath != null && appDataPath.isNotEmpty) {
        final baseDir = Directory(p.join(appDataPath, 'FeloneConfs'));
        if (!await baseDir.exists()) {
          await baseDir.create(recursive: true);
        }
        return baseDir;
      }
    }
    return getApplicationSupportDirectory();
  }

  Future<Directory> _ensureFlowDirectory() async {
    final baseDir = await _ensureCustomFlowBaseDirectory();
    final flowDir = Directory('${baseDir.path}/custom_flows');
    if (!await flowDir.exists()) {
      await flowDir.create(recursive: true);
    }
    return flowDir;
  }

  Future<Directory> _ensureStandaloneFlowAssetBaseDirectory() async {
    final baseDir = await _ensureCustomFlowBaseDirectory();
    final flowDir = Directory(p.join(baseDir.path, 'custom_flows'));
    if (!await flowDir.exists()) {
      await flowDir.create(recursive: true);
    }
    return flowDir;
  }

  Future<Directory> _ensureFlowAssetRootDirectory() async {
    final flowDir = await _ensureStandaloneFlowAssetBaseDirectory();
    final assetDir = Directory(p.join(flowDir.path, '_assets'));
    if (!await assetDir.exists()) {
      await assetDir.create(recursive: true);
    }
    return assetDir;
  }

  Future<Directory> _createStagingFlowAssetDirectory(String flowName) async {
    final rootDir = await _ensureFlowAssetRootDirectory();
    final stagingDir = Directory(
      p.join(
        rootDir.path,
        '${sanitizeFlowName(flowName)}__staging_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await stagingDir.create(recursive: true);
    return stagingDir;
  }

  Future<void> _replaceFlowAssetDirectory({
    required String flowName,
    required Directory stagingDir,
  }) async {
    final rootDir = await _ensureFlowAssetRootDirectory();
    final targetDir = Directory(
      p.join(rootDir.path, sanitizeFlowName(flowName)),
    );
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await stagingDir.rename(targetDir.path);
  }

  Future<String> _writeFlowJson(CustomFlowDefinition flow) async {
    final dir = await _ensureFlowDirectory();
    final file = File('${dir.path}/${sanitizeFlowName(flow.name)}.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(flow.toJson()),
    );
    return file.path;
  }

  String _buildManagedImageName({
    required String id,
    required String templatePath,
    required String templateName,
  }) {
    final originalName = p.basename(
      templatePath.trim().isNotEmpty
          ? templatePath.trim()
          : templateName.trim(),
    );
    final strippedName = _stripManagedImageTimestampPrefix(
      fileName: originalName,
      id: id,
    );
    final safeName = strippedName.isEmpty ? 'image.png' : strippedName;
    return [id, safeName].join('_');
  }

  String _stripManagedImageTimestampPrefix({
    required String fileName,
    required String id,
  }) {
    var result = fileName;
    final trimmedId = id.trim();
    final currentIdPrefix = '${trimmedId}_';
    while (trimmedId.isNotEmpty && result.startsWith(currentIdPrefix)) {
      result = result.substring(currentIdPrefix.length);
    }

    final timestampPrefix = RegExp(r'^(?:\d{13}|\d{16})_');
    while (timestampPrefix.hasMatch(result)) {
      result = result.replaceFirst(timestampPrefix, '');
    }
    return result;
  }

  Future<String> _copyImageToManagedDirectory({
    required Directory assetDir,
    required String id,
    required String templatePath,
    required String templateName,
  }) async {
    final sourcePath = templatePath.trim();
    if (sourcePath.isEmpty) {
      return '';
    }
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('图片文件不存在，无法保存流程', sourcePath);
    }
    final targetPath = p.join(
      assetDir.path,
      _buildManagedImageName(
        id: id,
        templatePath: templatePath,
        templateName: templateName,
      ),
    );
    if (p.normalize(sourceFile.path) != p.normalize(targetPath)) {
      await sourceFile.copy(targetPath);
    }
    return targetPath;
  }

  Future<CustomFlowBranchCase> _normalizeBranchCaseForStorage(
    CustomFlowBranchCase branchCase,
    Directory assetDir,
  ) async {
    var normalized = branchCase;
    if (_branchCaseUsesImages(branchCase)) {
      final normalizedImages = <CustomFlowBranchImage>[];
      for (final image in branchCase.effectiveTemplateImages) {
        var normalizedImage = image;
        if (image.imageSource == CustomFlowImageSource.localFile &&
            image.templatePath.trim().isNotEmpty) {
          final managedPath = await _copyImageToManagedDirectory(
            assetDir: assetDir,
            id: image.id,
            templatePath: image.templatePath,
            templateName: image.templateName,
          );
          normalizedImage = normalizedImage.copyWith(
            templatePath: managedPath,
            templateName: image.templateName.trim().isNotEmpty
                ? image.templateName.trim()
                : p.basename(managedPath),
          );
        }
        normalizedImages.add(normalizedImage);
      }
      normalized = normalized.copyWith(templateImages: normalizedImages);
    }
    final normalizedSteps = <CustomFlowStep>[];
    for (final step in normalized.steps) {
      normalizedSteps.add(await _normalizeStepForStorage(step, assetDir));
    }
    return normalized.copyWith(steps: normalizedSteps);
  }

  Future<CustomFlowStep> _normalizeStepForStorage(
    CustomFlowStep step,
    Directory assetDir,
  ) async {
    var normalized = step;
    if (_stepUsesOwnImage(step) &&
        step.imageSource == CustomFlowImageSource.localFile &&
        step.templatePath.trim().isNotEmpty) {
      final managedPath = await _copyImageToManagedDirectory(
        assetDir: assetDir,
        id: step.id,
        templatePath: step.templatePath,
        templateName: step.templateName,
      );
      normalized = normalized.copyWith(
        templatePath: managedPath,
        templateName: step.templateName.trim().isNotEmpty
            ? step.templateName.trim()
            : p.basename(managedPath),
      );
    }
    final normalizedChildren = <CustomFlowStep>[];
    for (final child in normalized.children) {
      normalizedChildren.add(await _normalizeStepForStorage(child, assetDir));
    }
    final normalizedBranchCases = <CustomFlowBranchCase>[];
    for (final branchCase in normalized.branchCases) {
      normalizedBranchCases.add(
        await _normalizeBranchCaseForStorage(branchCase, assetDir),
      );
    }
    final normalizedFallbackChildren = <CustomFlowStep>[];
    for (final child in normalized.fallbackChildren) {
      normalizedFallbackChildren.add(
        await _normalizeStepForStorage(child, assetDir),
      );
    }
    return normalized.copyWith(
      children: normalizedChildren,
      branchCases: normalizedBranchCases,
      fallbackChildren: normalizedFallbackChildren,
    );
  }

  Future<CustomFlowDefinition> _normalizeFlowForStorage(
    CustomFlowDefinition flow,
  ) async {
    final sanitizedName = sanitizeFlowName(flow.name);
    final assetDir = await _createStagingFlowAssetDirectory(sanitizedName);
    final normalizedSteps = <CustomFlowStep>[];
    for (final step in flow.steps) {
      normalizedSteps.add(await _normalizeStepForStorage(step, assetDir));
    }
    await _replaceFlowAssetDirectory(
      flowName: sanitizedName,
      stagingDir: assetDir,
    );
    final finalAssetDir = Directory(
      p.join((await _ensureFlowAssetRootDirectory()).path, sanitizedName),
    );
    return flow.copyWith(
      name: sanitizedName,
      steps: normalizedSteps
          .map(
            (step) => _rebaseStepTemplatePath(
              step,
              fromDir: assetDir.path,
              toDir: finalAssetDir.path,
            ),
          )
          .toList(),
    );
  }

  CustomFlowBranchCase _rebaseBranchCaseTemplatePath(
    CustomFlowBranchCase branchCase, {
    required String fromDir,
    required String toDir,
  }) {
    final rebasedSteps = branchCase.steps
        .map(
          (step) =>
              _rebaseStepTemplatePath(step, fromDir: fromDir, toDir: toDir),
        )
        .toList();
    if (!_branchCaseUsesImages(branchCase)) {
      return branchCase.copyWith(steps: rebasedSteps);
    }
    final normalizedImages = branchCase.effectiveTemplateImages.map((image) {
      final normalizedPath = image.templatePath.startsWith(fromDir)
          ? p.join(toDir, p.relative(image.templatePath, from: fromDir))
          : image.templatePath;
      return image.copyWith(templatePath: normalizedPath);
    }).toList();
    return branchCase.copyWith(
      templateImages: normalizedImages,
      steps: rebasedSteps,
    );
  }

  CustomFlowStep _rebaseStepTemplatePath(
    CustomFlowStep step, {
    required String fromDir,
    required String toDir,
  }) {
    final normalizedPath = step.templatePath.startsWith(fromDir)
        ? p.join(toDir, p.relative(step.templatePath, from: fromDir))
        : step.templatePath;
    return step.copyWith(
      templatePath: normalizedPath,
      children: step.children
          .map(
            (child) =>
                _rebaseStepTemplatePath(child, fromDir: fromDir, toDir: toDir),
          )
          .toList(),
      branchCases: step.branchCases
          .map(
            (branchCase) => _rebaseBranchCaseTemplatePath(
              branchCase,
              fromDir: fromDir,
              toDir: toDir,
            ),
          )
          .toList(),
      fallbackChildren: step.fallbackChildren
          .map(
            (child) =>
                _rebaseStepTemplatePath(child, fromDir: fromDir, toDir: toDir),
          )
          .toList(),
    );
  }

  Map<String, dynamic> _buildExportImageEntry(String path, Uint8List bytes) => {
    'fileName': p.basename(path),
    'bytesBase64': base64Encode(bytes),
  };

  Future<CustomFlowBranchCase> _normalizeBranchCaseForExport(
    CustomFlowBranchCase branchCase,
    Map<String, dynamic> images,
  ) async {
    var normalized = branchCase;
    if (_branchCaseUsesImages(branchCase) &&
        branchCase.effectiveTemplateImages.isEmpty &&
        branchCase.imageSource == CustomFlowImageSource.localFile &&
        branchCase.templatePath.trim().isNotEmpty) {
      final file = File(branchCase.templatePath.trim());
      if (!await file.exists()) {
        throw FileSystemException('图片文件不存在，无法导出流程', file.path);
      }
      images[branchCase.id] = _buildExportImageEntry(
        file.path,
        await file.readAsBytes(),
      );
      normalized = normalized.copyWith(templatePath: p.basename(file.path));
    }
    if (_branchCaseUsesImages(branchCase)) {
      final normalizedImages = <CustomFlowBranchImage>[];
      for (final image in branchCase.effectiveTemplateImages) {
        var normalizedImage = image;
        if (image.imageSource == CustomFlowImageSource.localFile &&
            image.templatePath.trim().isNotEmpty) {
          final file = File(image.templatePath.trim());
          if (!await file.exists()) {
            throw FileSystemException('鍥剧墖鏂囦欢涓嶅瓨鍦紝鏃犳硶瀵煎嚭娴佺▼', file.path);
          }
          images[image.id] = _buildExportImageEntry(
            file.path,
            await file.readAsBytes(),
          );
          normalizedImage = normalizedImage.copyWith(
            templatePath: p.basename(file.path),
          );
        }
        normalizedImages.add(normalizedImage);
      }
      normalized = normalized.copyWith(templateImages: normalizedImages);
    }
    final normalizedSteps = <CustomFlowStep>[];
    for (final step in normalized.steps) {
      normalizedSteps.add(await _normalizeStepForExport(step, images));
    }
    return normalized.copyWith(steps: normalizedSteps);
  }

  Future<CustomFlowStep> _normalizeStepForExport(
    CustomFlowStep step,
    Map<String, dynamic> images,
  ) async {
    var normalized = step;
    if (_stepUsesOwnImage(step) &&
        step.imageSource == CustomFlowImageSource.localFile &&
        step.templatePath.trim().isNotEmpty) {
      final file = File(step.templatePath.trim());
      if (!await file.exists()) {
        throw FileSystemException('图片文件不存在，无法导出流程', file.path);
      }
      images[step.id] = _buildExportImageEntry(
        file.path,
        await file.readAsBytes(),
      );
      normalized = normalized.copyWith(templatePath: p.basename(file.path));
    }
    final normalizedChildren = <CustomFlowStep>[];
    for (final child in normalized.children) {
      normalizedChildren.add(await _normalizeStepForExport(child, images));
    }
    final normalizedBranchCases = <CustomFlowBranchCase>[];
    for (final branchCase in normalized.branchCases) {
      normalizedBranchCases.add(
        await _normalizeBranchCaseForExport(branchCase, images),
      );
    }
    final normalizedFallbackChildren = <CustomFlowStep>[];
    for (final child in normalized.fallbackChildren) {
      normalizedFallbackChildren.add(
        await _normalizeStepForExport(child, images),
      );
    }
    return normalized.copyWith(
      children: normalizedChildren,
      branchCases: normalizedBranchCases,
      fallbackChildren: normalizedFallbackChildren,
    );
  }

  bool _stepUsesOwnImage(CustomFlowStep step) {
    if (step.recognitionMode != CustomFlowRecognitionMode.image) {
      return false;
    }
    return step.type == CustomFlowStepType.imageTap ||
        step.type == CustomFlowStepType.waitImageState ||
        step.type == CustomFlowStepType.imagePositionBranch ||
        (step.type == CustomFlowStepType.loopBlock &&
            step.loopMode == CustomFlowLoopMode.imageCondition);
  }

  bool _branchCaseUsesImages(CustomFlowBranchCase branchCase) {
    return branchCase.recognitionMode == CustomFlowRecognitionMode.image;
  }

  Future<void> _validateLocalImageForExport({
    required String description,
    required CustomFlowImageSource imageSource,
    required String templatePath,
  }) async {
    if (imageSource != CustomFlowImageSource.localFile) {
      return;
    }
    final path = templatePath.trim();
    if (path.isEmpty) {
      throw StateError('$description 未选择本地图片，无法导出完整流程包');
    }
    if (!await File(path).exists()) {
      throw FileSystemException('$description 的图片文件不存在，无法导出完整流程包', path);
    }
  }

  Future<void> _validateBranchCaseImagesForExport(
    CustomFlowBranchCase branchCase,
  ) async {
    if (!_branchCaseUsesImages(branchCase)) {
      return;
    }
    final templateImages = branchCase.effectiveTemplateImages;
    if (templateImages.isEmpty) {
      throw StateError(
        'Branch ${branchCase.label.isEmpty ? branchCase.id : branchCase.label} has no condition images.',
      );
    }
    for (var index = 0; index < templateImages.length; index++) {
      final image = templateImages[index];
      await _validateLocalImageForExport(
        description:
            'Branch ${branchCase.label.isEmpty ? branchCase.id : branchCase.label} image ${index + 1}',
        imageSource: image.imageSource,
        templatePath: image.templatePath,
      );
    }
  }

  Future<void> _validateStepImagesForExport(List<CustomFlowStep> steps) async {
    for (final step in steps) {
      if (_stepUsesOwnImage(step)) {
        await _validateLocalImageForExport(
          description: '步骤“${step.label.isEmpty ? step.id : step.label}”',
          imageSource: step.imageSource,
          templatePath: step.templatePath,
        );
      }
      if (step.type == CustomFlowStepType.imageBranch) {
        for (final branchCase in step.branchCases) {
          await _validateBranchCaseImagesForExport(branchCase);
          if (_branchCaseUsesImages(branchCase)) {
            await _validateLocalImageForExport(
              description:
                  '分支“${branchCase.label.isEmpty ? branchCase.id : branchCase.label}”',
              imageSource: branchCase.imageSource,
              templatePath: branchCase.templatePath,
            );
          }
        }
      }
      for (final branchCase in step.branchCases) {
        await _validateStepImagesForExport(branchCase.steps);
      }
      await _validateStepImagesForExport(step.children);
      await _validateStepImagesForExport(step.fallbackChildren);
    }
  }

  Set<String> _collectRecordedFlowNames(List<CustomFlowStep> steps) {
    final names = <String>{};

    void collect(List<CustomFlowStep> currentSteps) {
      for (final step in currentSteps) {
        if (step.type == CustomFlowStepType.recordedFlow) {
          final flowName = step.recordedFlowName.trim();
          if (flowName.isEmpty) {
            throw StateError(
              '步骤“${step.label.isEmpty ? step.id : step.label}”未选择录制流程，无法导出完整流程包',
            );
          }
          names.add(flowName);
        }
        for (final branchCase in step.branchCases) {
          collect(branchCase.steps);
        }
        collect(step.children);
        collect(step.fallbackChildren);
      }
    }

    collect(steps);
    return names;
  }

  Future<Map<String, dynamic>> _buildRecordedFlowExportPayload(
    List<CustomFlowStep> steps,
  ) async {
    final result = <String, dynamic>{};
    for (final flowName in _collectRecordedFlowNames(steps)) {
      final recordedFlow = await _touchRecorderService.loadFlow(flowName);
      if (recordedFlow == null) {
        throw StateError('未找到自定义流程引用的录制流程：$flowName');
      }
      result[flowName] = recordedFlow.toJson();
    }
    return result;
  }

  Future<Map<String, dynamic>> buildExportPayload(
    CustomFlowDefinition flow,
  ) async {
    await _validateStepImagesForExport(flow.steps);
    final recordedFlows = await _buildRecordedFlowExportPayload(flow.steps);
    final images = <String, dynamic>{};
    final normalizedSteps = <CustomFlowStep>[];
    for (final step in flow.steps) {
      normalizedSteps.add(await _normalizeStepForExport(step, images));
    }
    final normalizedFlow = flow.copyWith(
      name: sanitizeFlowName(flow.name),
      steps: normalizedSteps,
    );
    return {
      'version': currentPackageVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'flow': normalizedFlow.toJson(),
      'images': images,
      'recordedFlows': recordedFlows,
    };
  }

  Future<void> exportFlowPackage({
    required CustomFlowDefinition flow,
    required String exportPath,
  }) async {
    final payload = await buildExportPayload(flow);
    final file = File(exportPath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  Future<CustomFlowBranchCase> _restoreBranchCaseFromImport(
    CustomFlowBranchCase branchCase,
    Directory assetDir,
    Map<String, dynamic> images,
  ) async {
    var restored = branchCase;
    if (_branchCaseUsesImages(branchCase)) {
      final restoredImages = <CustomFlowBranchImage>[];
      for (final image in branchCase.effectiveTemplateImages) {
        var restoredImage = image;
        if (image.imageSource == CustomFlowImageSource.localFile) {
          final imageRaw = images[image.id];
          if (imageRaw is Map<String, dynamic>) {
            final fileName =
                imageRaw['fileName']?.toString().trim().isNotEmpty == true
                ? imageRaw['fileName']!.toString().trim()
                : '${image.id}.png';
            final bytesBase64 = imageRaw['bytesBase64']?.toString() ?? '';
            if (bytesBase64.isNotEmpty) {
              final targetPath = p.join(
                assetDir.path,
                _buildManagedImageName(
                  id: image.id,
                  templatePath: fileName,
                  templateName: image.templateName,
                ),
              );
              await File(targetPath).writeAsBytes(base64Decode(bytesBase64));
              restoredImage = restoredImage.copyWith(
                templatePath: targetPath,
                templateName: image.templateName.trim().isNotEmpty
                    ? image.templateName.trim()
                    : p.basename(fileName),
              );
            }
          }
        }
        restoredImages.add(restoredImage);
      }
      restored = restored.copyWith(templateImages: restoredImages);
    }
    final restoredSteps = <CustomFlowStep>[];
    for (final step in restored.steps) {
      restoredSteps.add(await _restoreStepFromImport(step, assetDir, images));
    }
    return restored.copyWith(steps: restoredSteps);
  }

  Future<CustomFlowStep> _restoreStepFromImport(
    CustomFlowStep step,
    Directory assetDir,
    Map<String, dynamic> images,
  ) async {
    var restored = step;
    if (_stepUsesOwnImage(step) &&
        step.imageSource == CustomFlowImageSource.localFile) {
      final imageRaw = images[step.id];
      if (imageRaw is Map<String, dynamic>) {
        final fileName =
            imageRaw['fileName']?.toString().trim().isNotEmpty == true
            ? imageRaw['fileName']!.toString().trim()
            : '${step.id}.png';
        final bytesBase64 = imageRaw['bytesBase64']?.toString() ?? '';
        if (bytesBase64.isNotEmpty) {
          final targetPath = p.join(
            assetDir.path,
            _buildManagedImageName(
              id: step.id,
              templatePath: fileName,
              templateName: step.templateName,
            ),
          );
          await File(targetPath).writeAsBytes(base64Decode(bytesBase64));
          restored = restored.copyWith(
            templatePath: targetPath,
            templateName: step.templateName.trim().isNotEmpty
                ? step.templateName.trim()
                : p.basename(fileName),
          );
        }
      }
    }
    final restoredChildren = <CustomFlowStep>[];
    for (final child in restored.children) {
      restoredChildren.add(
        await _restoreStepFromImport(child, assetDir, images),
      );
    }
    final restoredBranchCases = <CustomFlowBranchCase>[];
    for (final branchCase in restored.branchCases) {
      restoredBranchCases.add(
        await _restoreBranchCaseFromImport(branchCase, assetDir, images),
      );
    }
    final restoredFallbackChildren = <CustomFlowStep>[];
    for (final child in restored.fallbackChildren) {
      restoredFallbackChildren.add(
        await _restoreStepFromImport(child, assetDir, images),
      );
    }
    return restored.copyWith(
      children: restoredChildren,
      branchCases: restoredBranchCases,
      fallbackChildren: restoredFallbackChildren,
    );
  }

  void _validateImportedImageEntry({
    required String description,
    required String id,
    required Map<String, dynamic> images,
  }) {
    final imageRaw = images[id];
    if (imageRaw is! Map) {
      throw FormatException('$description 缺少图片资源，导入包不完整');
    }
    final image = Map<String, dynamic>.from(imageRaw);
    final bytesBase64 = image['bytesBase64']?.toString() ?? '';
    if (bytesBase64.isEmpty) {
      throw FormatException('$description 的图片数据为空，导入包不完整');
    }
    try {
      base64Decode(bytesBase64);
    } on FormatException {
      throw FormatException('$description 的图片数据损坏，无法导入');
    }
  }

  void _validateBranchCaseImagesForImport(
    CustomFlowBranchCase branchCase,
    Map<String, dynamic> images,
  ) {
    if (!_branchCaseUsesImages(branchCase)) {
      return;
    }
    final templateImages = branchCase.effectiveTemplateImages;
    if (templateImages.isEmpty) {
      throw FormatException(
        'Branch ${branchCase.label.isEmpty ? branchCase.id : branchCase.label} has no condition images.',
      );
    }
    for (var index = 0; index < templateImages.length; index++) {
      final image = templateImages[index];
      if (image.imageSource == CustomFlowImageSource.localFile) {
        _validateImportedImageEntry(
          description:
              'Branch ${branchCase.label.isEmpty ? branchCase.id : branchCase.label} image ${index + 1}',
          id: image.id,
          images: images,
        );
      }
    }
  }

  void _validateStepImagesForImport(
    List<CustomFlowStep> steps,
    Map<String, dynamic> images,
  ) {
    for (final step in steps) {
      if (_stepUsesOwnImage(step) &&
          step.imageSource == CustomFlowImageSource.localFile) {
        _validateImportedImageEntry(
          description: '步骤“${step.label.isEmpty ? step.id : step.label}”',
          id: step.id,
          images: images,
        );
      }
      if (step.type == CustomFlowStepType.imageBranch) {
        for (final branchCase in step.branchCases) {
          _validateBranchCaseImagesForImport(branchCase, images);
        }
      }
      for (final branchCase in step.branchCases) {
        _validateStepImagesForImport(branchCase.steps, images);
      }
      _validateStepImagesForImport(step.children, images);
      _validateStepImagesForImport(step.fallbackChildren, images);
    }
  }

  CustomFlowBranchCase _rewriteBranchRecordedFlowNames(
    CustomFlowBranchCase branchCase,
    Map<String, String> nameMap,
  ) {
    return branchCase.copyWith(
      steps: branchCase.steps
          .map((step) => _rewriteStepRecordedFlowNames(step, nameMap))
          .toList(),
    );
  }

  CustomFlowStep _rewriteStepRecordedFlowNames(
    CustomFlowStep step,
    Map<String, String> nameMap,
  ) {
    final originalName = step.recordedFlowName.trim();
    return step.copyWith(
      recordedFlowName:
          step.type == CustomFlowStepType.recordedFlow &&
              nameMap.containsKey(originalName)
          ? nameMap[originalName]
          : step.recordedFlowName,
      children: step.children
          .map((child) => _rewriteStepRecordedFlowNames(child, nameMap))
          .toList(),
      branchCases: step.branchCases
          .map(
            (branchCase) =>
                _rewriteBranchRecordedFlowNames(branchCase, nameMap),
          )
          .toList(),
      fallbackChildren: step.fallbackChildren
          .map((child) => _rewriteStepRecordedFlowNames(child, nameMap))
          .toList(),
    );
  }

  Future<void> _cleanupFailedImport({
    required String flowName,
    required Directory stagingDir,
    required List<String> createdRecordedFlowNames,
  }) async {
    for (final recordedFlowName in createdRecordedFlowNames.reversed) {
      try {
        await _touchRecorderService.deleteFlow(recordedFlowName);
      } catch (_) {}
    }
    try {
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
    } catch (_) {}
    try {
      final flowDir = await _ensureFlowDirectory();
      final flowFile = File(
        p.join(flowDir.path, '${sanitizeFlowName(flowName)}.json'),
      );
      if (await flowFile.exists()) {
        await flowFile.delete();
      }
    } catch (_) {}
    try {
      final assetRoot = await _ensureFlowAssetRootDirectory();
      final assetDir = Directory(
        p.join(assetRoot.path, sanitizeFlowName(flowName)),
      );
      if (await assetDir.exists()) {
        await assetDir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<CustomFlowImportResult> importFlowPackage(String packagePath) async {
    final file = File(packagePath);
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final version = (raw['version'] as num?)?.toInt() ?? 1;
    if (version < 1 || version > currentPackageVersion) {
      throw FormatException(
        '不支持的自定义流程包版本：$version，当前最高支持 $currentPackageVersion',
      );
    }
    final flowJson = Map<String, dynamic>.from(
      raw['flow'] as Map? ?? const <String, dynamic>{},
    );
    final images = Map<String, dynamic>.from(
      raw['images'] as Map? ?? const <String, dynamic>{},
    );
    final importedFlow = CustomFlowDefinition.fromJson(flowJson);
    _validateStepImagesForImport(importedFlow.steps, images);

    final referencedRecordedFlowNames = _collectRecordedFlowNames(
      importedFlow.steps,
    );
    final embeddedRecordedFlows = <String, RecordedFlow>{};
    final recordedFlowNameMap = <String, String>{};
    if (version >= 2) {
      final recordedFlows = Map<String, dynamic>.from(
        raw['recordedFlows'] as Map? ?? const <String, dynamic>{},
      );
      for (final flowName in referencedRecordedFlowNames) {
        final recordedRaw = recordedFlows[flowName];
        if (recordedRaw is! Map) {
          throw FormatException('缺少录制流程资源“$flowName”，导入包不完整');
        }
        final recordedFlow = RecordedFlow.fromJson(
          Map<String, dynamic>.from(recordedRaw),
        ).copyWith(name: flowName);
        if (recordedFlow.touchDevicePath.trim().isEmpty) {
          throw FormatException('录制流程资源“$flowName”缺少触摸设备信息，无法导入');
        }
        embeddedRecordedFlows[flowName] = recordedFlow;
      }
    } else {
      for (final flowName in referencedRecordedFlowNames) {
        final localFlow = await _touchRecorderService.loadFlow(flowName);
        if (localFlow == null) {
          throw FormatException(
            '旧版流程包未包含录制流程“$flowName”，且本机没有同名录制流程，请在原电脑重新导出',
          );
        }
        recordedFlowNameMap[flowName] = flowName;
      }
    }

    final sanitizedName = await _resolveAvailableFlowName(importedFlow.name);
    final stagingDir = await _createStagingFlowAssetDirectory(sanitizedName);
    final createdRecordedFlowNames = <String>[];
    try {
      for (final entry in embeddedRecordedFlows.entries) {
        final savedFlow = await _touchRecorderService.saveFlowAsNew(
          entry.value,
        );
        recordedFlowNameMap[entry.key] = savedFlow.name;
        createdRecordedFlowNames.add(savedFlow.name);
      }

      final restoredSteps = <CustomFlowStep>[];
      for (final step in importedFlow.steps) {
        final restored = await _restoreStepFromImport(step, stagingDir, images);
        restoredSteps.add(
          _rewriteStepRecordedFlowNames(restored, recordedFlowNameMap),
        );
      }

      await _replaceFlowAssetDirectory(
        flowName: sanitizedName,
        stagingDir: stagingDir,
      );
      final finalAssetDir = Directory(
        p.join((await _ensureFlowAssetRootDirectory()).path, sanitizedName),
      );
      final normalizedFlow = importedFlow.copyWith(
        name: sanitizedName,
        updatedAt: DateTime.now(),
        steps: restoredSteps
            .map(
              (step) => _rebaseStepTemplatePath(
                step,
                fromDir: stagingDir.path,
                toDir: finalAssetDir.path,
              ),
            )
            .toList(),
      );
      await _writeFlowJson(normalizedFlow);
      return CustomFlowImportResult(
        flow: normalizedFlow,
        recordedFlowNameMap: Map.unmodifiable(recordedFlowNameMap),
        importedRecordedFlowNames: List.unmodifiable(createdRecordedFlowNames),
      );
    } catch (_) {
      await _cleanupFailedImport(
        flowName: sanitizedName,
        stagingDir: stagingDir,
        createdRecordedFlowNames: createdRecordedFlowNames,
      );
      rethrow;
    }
  }

  Future<String> _resolveAvailableFlowName(
    String desiredName, {
    String duplicateTag = 'import',
  }) async {
    final baseName = sanitizeFlowName(desiredName);
    final dir = await _ensureFlowDirectory();
    final directFile = File('${dir.path}/$baseName.json');
    if (!await directFile.exists()) {
      return baseName;
    }
    var index = 2;
    while (true) {
      final candidate = '${baseName}_${duplicateTag}_$index';
      final candidateFile = File('${dir.path}/$candidate.json');
      if (!await candidateFile.exists()) {
        return candidate;
      }
      index += 1;
    }
  }

  String sanitizeFlowName(String value) {
    final sanitized = value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    if (sanitized.isEmpty) {
      return 'custom_flow';
    }
    return sanitized;
  }

  Future<List<String>> listFlowNames() async {
    final dir = await _ensureFlowDirectory();
    final result = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        result.add(entity.uri.pathSegments.last.replaceAll('.json', ''));
      }
    }
    result.sort();
    return result;
  }

  Future<CustomFlowDefinition?> loadFlow(String name) async {
    final dir = await _ensureFlowDirectory();
    final file = File('${dir.path}/${sanitizeFlowName(name)}.json');
    if (!await file.exists()) {
      return null;
    }
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return CustomFlowDefinition.fromJson(raw);
  }

  Future<String> saveFlow(CustomFlowDefinition flow) async {
    final normalizedFlow = await _normalizeFlowForStorage(flow);
    return _writeFlowJson(normalizedFlow);
  }

  Future<SavedCustomFlowResult> saveFlowAsNew(
    CustomFlowDefinition flow, {
    String duplicateTag = 'copy',
  }) async {
    final finalName = await _resolveAvailableFlowName(
      flow.name,
      duplicateTag: duplicateTag,
    );
    final normalizedFlow = await _normalizeFlowForStorage(
      flow.copyWith(name: finalName),
    );
    final filePath = await _writeFlowJson(normalizedFlow);
    return SavedCustomFlowResult(flow: normalizedFlow, filePath: filePath);
  }

  Future<bool> deleteFlow(String name) async {
    final dir = await _ensureFlowDirectory();
    final file = File('${dir.path}/${sanitizeFlowName(name)}.json');
    if (!await file.exists()) {
      return false;
    }
    await file.delete();
    final rootDir = await _ensureFlowAssetRootDirectory();
    final assetDir = Directory(p.join(rootDir.path, sanitizeFlowName(name)));
    if (await assetDir.exists()) {
      await assetDir.delete(recursive: true);
    }
    return true;
  }
}
