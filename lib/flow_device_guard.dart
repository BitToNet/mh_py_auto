enum FlowDeviceRequirement { single, multiple }

class FlowDeviceResolution {
  const FlowDeviceResolution._({
    required this.deviceIds,
    required this.connectedDeviceIds,
    required this.missingSelectedDeviceIds,
    required this.missingRequiredDeviceIds,
    required this.message,
  });

  factory FlowDeviceResolution.valid({
    required List<String> deviceIds,
    required List<String> connectedDeviceIds,
  }) {
    return FlowDeviceResolution._(
      deviceIds: List.unmodifiable(deviceIds),
      connectedDeviceIds: List.unmodifiable(connectedDeviceIds),
      missingSelectedDeviceIds: const <String>[],
      missingRequiredDeviceIds: const <String>[],
      message: '',
    );
  }

  factory FlowDeviceResolution.invalid({
    required List<String> connectedDeviceIds,
    required List<String> missingSelectedDeviceIds,
    required List<String> missingRequiredDeviceIds,
    required String message,
  }) {
    return FlowDeviceResolution._(
      deviceIds: const <String>[],
      connectedDeviceIds: List.unmodifiable(connectedDeviceIds),
      missingSelectedDeviceIds: List.unmodifiable(missingSelectedDeviceIds),
      missingRequiredDeviceIds: List.unmodifiable(missingRequiredDeviceIds),
      message: message,
    );
  }

  final List<String> deviceIds;
  final List<String> connectedDeviceIds;
  final List<String> missingSelectedDeviceIds;
  final List<String> missingRequiredDeviceIds;
  final String message;

  bool get isValid => message.isEmpty;
}

List<String> parseConnectedAdbDeviceIds(String rawOutput) {
  final devices = <String>[];
  for (final rawLine in rawOutput.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('List of devices')) {
      continue;
    }
    final columns = line.split(RegExp(r'\s+'));
    if (columns.length < 2 || columns[1] != 'device') {
      continue;
    }
    final deviceId = columns.first.trim();
    if (deviceId.isNotEmpty && !devices.contains(deviceId)) {
      devices.add(deviceId);
    }
  }
  return devices;
}

FlowDeviceResolution resolveFlowDeviceSelection({
  required Iterable<String> selectedDeviceIds,
  required Iterable<String> connectedDeviceIds,
  required FlowDeviceRequirement requirement,
  required String operationLabel,
  Iterable<String> requiredDeviceIds = const <String>[],
}) {
  final connected = _uniqueNonEmpty(connectedDeviceIds);
  final selected = _uniqueNonEmpty(selectedDeviceIds);
  final requiredDevices = _uniqueNonEmpty(requiredDeviceIds);
  final connectedSet = connected.toSet();
  final missingSelected = selected
      .where((deviceId) => !connectedSet.contains(deviceId))
      .toList(growable: false);
  final missingRequired = requiredDevices
      .where((deviceId) => !connectedSet.contains(deviceId))
      .toList(growable: false);

  if (missingSelected.isNotEmpty || missingRequired.isNotEmpty) {
    return FlowDeviceResolution.invalid(
      connectedDeviceIds: connected,
      missingSelectedDeviceIds: missingSelected,
      missingRequiredDeviceIds: missingRequired,
      message: _buildMissingDeviceMessage(
        operationLabel: operationLabel,
        connectedDeviceIds: connected,
        missingSelectedDeviceIds: missingSelected,
        missingRequiredDeviceIds: missingRequired,
      ),
    );
  }

  final targetDevices = selected.isNotEmpty ? selected : connected;
  switch (requirement) {
    case FlowDeviceRequirement.single:
      if (targetDevices.isEmpty) {
        return FlowDeviceResolution.invalid(
          connectedDeviceIds: connected,
          missingSelectedDeviceIds: const <String>[],
          missingRequiredDeviceIds: const <String>[],
          message: '$operationLabel前未找到已连接模拟器，请先启动模拟器并刷新设备列表。',
        );
      }
      if (targetDevices.length > 1) {
        return FlowDeviceResolution.invalid(
          connectedDeviceIds: connected,
          missingSelectedDeviceIds: const <String>[],
          missingRequiredDeviceIds: const <String>[],
          message:
              '$operationLabel前请只保留一个目标设备。\n当前目标设备：${_formatDeviceList(targetDevices)}',
        );
      }
      return FlowDeviceResolution.valid(
        deviceIds: targetDevices,
        connectedDeviceIds: connected,
      );
    case FlowDeviceRequirement.multiple:
      if (targetDevices.isEmpty) {
        return FlowDeviceResolution.invalid(
          connectedDeviceIds: connected,
          missingSelectedDeviceIds: const <String>[],
          missingRequiredDeviceIds: const <String>[],
          message: '$operationLabel前请先选择至少一个设备，或先刷新出连接设备。',
        );
      }
      return FlowDeviceResolution.valid(
        deviceIds: targetDevices,
        connectedDeviceIds: connected,
      );
  }
}

List<String> _uniqueNonEmpty(Iterable<String> values) {
  final result = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || result.contains(trimmed)) {
      continue;
    }
    result.add(trimmed);
  }
  return result;
}

String _buildMissingDeviceMessage({
  required String operationLabel,
  required List<String> connectedDeviceIds,
  required List<String> missingSelectedDeviceIds,
  required List<String> missingRequiredDeviceIds,
}) {
  final lines = <String>['$operationLabel前存在未连接的目标设备。'];
  if (missingSelectedDeviceIds.isNotEmpty) {
    lines.add('已选择但未连接：${_formatDeviceList(missingSelectedDeviceIds)}');
  }
  if (missingRequiredDeviceIds.isNotEmpty) {
    lines.add('步骤中指定但未连接：${_formatDeviceList(missingRequiredDeviceIds)}');
  }
  lines.add('当前已连接设备：${_formatDeviceList(connectedDeviceIds)}');
  return lines.join('\n');
}

String _formatDeviceList(List<String> deviceIds) {
  return deviceIds.isEmpty ? '无' : deviceIds.join(', ');
}
