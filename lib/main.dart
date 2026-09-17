import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:ai/NetUtil.dart';
import 'package:ai/Utils.dart';
import 'package:ai/custom_flow.dart';
import 'package:ai/flow_device_guard.dart';
import 'package:ai/recording_flow.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:desktop_window/desktop_window.dart';
import 'package:url_launcher/url_launcher.dart';

import 'encrypt_util.dart';
import 'file_utils.dart';
import 'custom_flow_lint.dart';
import 'recorded_flow_lint.dart';
import 'win_flow_self_check.dart';
import 'win_workspace.dart';
import 'windows_helper_client.dart';

// opencv https://www.doubao.com/thread/w156d1f39e583bfa7
void main() {
  // 连接网络、获取网络时间
  // 默认给七天的使用
  // 后续收费分年月周卡，根据周卡
  WidgetsFlutterBinding.ensureInitialized(); // 初始化 Flutter 绑定
  _configureWindow(); // 自定义窗口配置方法
  runApp(const MyApp());
}

void _configureWindow() async {
  try {
    // 获取屏幕尺寸
    final screenSize =
        WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;

    // 根据屏幕分辨率设置窗口大小
    Size windowSize;
    Size minWindowSize;

    if (screenWidth >= 3000 && screenHeight >= 1800) {
      // 4K 屏幕
      windowSize = const Size(2300, 1780);
      minWindowSize = const Size(2300, 1780);
    } else if (screenWidth >= 2000 && screenHeight >= 1220) {
      // 2K 屏幕
      windowSize = const Size(1280, 1200);
      minWindowSize = const Size(1280, 1200);
    } else {
      // 1K 屏幕（默认）
      windowSize = const Size(980, 920);
      minWindowSize = const Size(980, 920);
    }

    // 设置窗口尺寸
    await DesktopWindow.setWindowSize(windowSize);
    // 设置最小窗口尺寸
    await DesktopWindow.setMinWindowSize(minWindowSize);
  } catch (e) {
    // 捕获异常，避免其他平台（Mac/Linux）运行报错
    debugPrint("设置窗口尺寸失败：$e");
  }
}

ValueNotifier<String> userResult = ValueNotifier('');
ValueNotifier<String> userCheck = ValueNotifier('');
ValueNotifier<String> uuidCount = ValueNotifier('');
ValueNotifier<String> leftEntry = ValueNotifier('');
ValueNotifier<int> randomEntry = ValueNotifier(0);
ValueNotifier<String> rightEntry = ValueNotifier('');
ValueNotifier<String> dateTime = ValueNotifier('');
ValueNotifier<String> showEncrypt = ValueNotifier('');
ValueNotifier<bool> showDialog = ValueNotifier(true);

/// 仅测试用：强制界面进入《梦幻西游：时空》Windows 客户端模式。
///
/// 真机上由 `Platform.isWindows` 决定；留这个开关是为了让 macOS 上也能用
/// widget 测试覆盖时空模式的界面分支（否则这条分支在开发机上永远测不到）。
@visibleForTesting
bool debugForceWindowsClientMode = false;

/// 测试用：替换自定义流程的存储服务（默认走真实的 APPDATA/应用支持目录）。
@visibleForTesting
CustomFlowStorageService? debugCustomFlowStorageService;
// todo
ValueNotifier<String> hint = ValueNotifier(
  // 'ZUk40o1AESE0HrnH2im9cFM7gG1jpgcKwMAkv10VwwY='
  // 'wPqMdJH66/ehp157DAH86KeBDIDvrZlH0h93P/bYTbg='
  // 'nzk3EiRB+8rbqu75Ya3nvq8Km94jXimWe6u4Dabxh5o='
  'icHSQJft4OvsdWmckAm9gTXDshD2lNIwHuY/k+bh6X4=',
);

class LinglongTheme {
  static const Color gold = Color(0xFFF5E8CD);
  static const Color goldDeep = Color(0xFFD6C1A0);
  static const Color goldSoft = Color(0xFFFFF7E9);
  static const Color vermilion = Color(0xFFC84A21);
  static const Color vermilionDeep = Color(0xFF8E2D18);
  static const Color parchment = Color(0xFFF7ECD4);
  static const Color parchmentSoft = Color(0xFFFFF8EE);
  static const Color cloudPink = Color(0xFFE6C0B6);
  static const Color mist = Color(0xFFD2D9C8);
  static const Color mistBlue = Color(0xFF77AEB5);
  static const Color mountainBlue = Color(0xFF2F6D7A);
  static const Color mountainDeep = Color(0xFF204A55);
  static const Color ink = Color(0xFF1A110D);
  static const Color inkSoft = Color(0xFF473328);
  static const Color border = Color(0x996A5225);
  static const Color dropdownSurface = Color(0xEFFFFAF2);
  static const Color switchActiveThumb = Color(0xFF4CAF50);
  static const Color switchActiveTrack = Color(0xFFA5D6A7);
  static const Color switchInactiveThumb = Color(0xFF9E9E9E);
  static const Color switchInactiveTrack = Color(0xFFEEEEEE);
  static const Color success = Color(0xFF9FD7B7);
  static const Color danger = Color(0xFFA63B2A);
  static const Color terminal = Color(0xD9172224);

  static const BorderRadius panelRadius = BorderRadius.all(Radius.circular(8));
  static const BorderRadius pillRadius = BorderRadius.all(Radius.circular(999));

  static const List<BoxShadow> panelShadow = [
    BoxShadow(color: Color(0x24523B1A), blurRadius: 20, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x22FFFFFF), blurRadius: 10, offset: Offset(0, 1)),
  ];

  static const List<BoxShadow> glowShadow = [
    BoxShadow(
      color: Color(0x40FFFFFF),
      blurRadius: 22,
      offset: Offset(0, 8),
      spreadRadius: -3,
    ),
  ];

  static const LinearGradient appBackground = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFBDE1E6),
      Color(0xFFD8EBEF),
      Color(0xFFBDE1E6),

      // Color(0xFFFFF5E4),
    ],
    stops: [0.0, 0.5, 1.0],
  );

  static const LinearGradient primaryButtonGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFDE6A28), Color(0xFFC54921), Color(0xFF8E2D18)],
  );

  static const LinearGradient softPanelGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xCFFFFFFF), Color(0xBFFEF8EE), Color(0xB7F5EBD9)],
  );

  static BoxDecoration panelDecoration({
    bool dark = false,
    bool emphasized = false,
  }) {
    return BoxDecoration(
      gradient: dark ? null : softPanelGradient,
      color: dark ? terminal : null,
      borderRadius: panelRadius,
      border: Border.all(
        color: dark ? const Color(0x66D5AB63) : border,
        width: dark ? 1.1 : 1.2,
      ),
      boxShadow: emphasized ? [...panelShadow, ...glowShadow] : panelShadow,
    );
  }

  static OutlineInputBorder inputBorder([Color? color, double width = 1.2]) {
    return OutlineInputBorder(
      borderRadius: panelRadius,
      borderSide: BorderSide(
        color: color ?? const Color(0xB07A6234),
        width: width,
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '玲珑助手',
      theme: ThemeData(
        colorScheme: const ColorScheme.light(
          primary: LinglongTheme.gold,
          secondary: LinglongTheme.vermilion,
          surface: LinglongTheme.parchmentSoft,
          error: LinglongTheme.danger,
          onPrimary: Colors.white,
          onSecondary: LinglongTheme.ink,
          onSurface: LinglongTheme.ink,
          onError: Colors.white,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
        dividerColor: const Color(0xA87A6234),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: LinglongTheme.vermilionDeep,
          selectionColor: Color(0x4D2F6D7A),
          selectionHandleColor: LinglongTheme.vermilionDeep,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: LinglongTheme.ink, height: 1.45),
          bodyMedium: TextStyle(color: LinglongTheme.ink, height: 1.4),
          titleLarge: TextStyle(
            color: LinglongTheme.ink,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: TextStyle(
            color: LinglongTheme.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: false,
          backgroundColor: Color(0xBFFFFFF4),
          foregroundColor: LinglongTheme.ink,
          surfaceTintColor: Colors.transparent,
          shadowColor: Color(0x30523B1A),
          titleTextStyle: TextStyle(
            color: LinglongTheme.ink,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xCCFFFFFF),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: LinglongTheme.panelRadius,
            side: const BorderSide(color: Color(0xA07A6234)),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xEEFFF9F0),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: const Color(0xD9FFF8EA),
          selectedColor: LinglongTheme.goldSoft,
          disabledColor: const Color(0x99D4C7A8),
          deleteIconColor: LinglongTheme.goldDeep,
          labelStyle: const TextStyle(
            color: LinglongTheme.ink,
            fontWeight: FontWeight.w600,
          ),
          secondaryLabelStyle: const TextStyle(color: LinglongTheme.ink),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: const BorderSide(color: Color(0xB0775E2C)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0x66FFFFFF),
          labelStyle: const TextStyle(
            color: LinglongTheme.ink,
            fontWeight: FontWeight.w600,
          ),
          hintStyle: const TextStyle(color: Color(0xCC6B5A49)),
          helperStyle: const TextStyle(color: LinglongTheme.inkSoft),
          floatingLabelStyle: const TextStyle(
            color: LinglongTheme.mountainDeep,
            fontWeight: FontWeight.w700,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          border: LinglongTheme.inputBorder(),
          enabledBorder: LinglongTheme.inputBorder(),
          focusedBorder: LinglongTheme.inputBorder(
            LinglongTheme.mountainBlue,
            1.8,
          ),
          errorBorder: LinglongTheme.inputBorder(LinglongTheme.danger),
          focusedErrorBorder: LinglongTheme.inputBorder(
            LinglongTheme.danger,
            1.8,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            shadowColor: Colors.transparent,
            foregroundColor: LinglongTheme.ink,
            backgroundColor: const Color(0xD8FFF9EE),
            disabledForegroundColor: const Color(0x997D715F),
            disabledBackgroundColor: const Color(0xCCDACBAE),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xB0785F2C)),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            elevation: 0,
            foregroundColor: Colors.white,
            backgroundColor: LinglongTheme.vermilion,
            disabledBackgroundColor: const Color(0x99A67B5B),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: LinglongTheme.ink,
            side: const BorderSide(color: Color(0xB06C7F6B)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xEE213C45),
          contentTextStyle: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
          actionTextColor: Color(0xFFF6D68F),
          behavior: SnackBarBehavior.floating,
        ),
        tabBarTheme: const TabBarThemeData(
          labelColor: LinglongTheme.ink,
          unselectedLabelColor: LinglongTheme.mountainDeep,
          indicatorColor: LinglongTheme.vermilion,
          dividerColor: Colors.transparent,
          labelStyle: TextStyle(fontWeight: FontWeight.w700),
          unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.disabled)) {
              return const Color(0xFFBDBDBD);
            }
            if (states.contains(WidgetState.selected)) {
              return LinglongTheme.switchActiveThumb;
            }
            return LinglongTheme.switchInactiveThumb;
          }),
          trackColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.disabled)) {
              return const Color(0xFFE0E0E0);
            }
            if (states.contains(WidgetState.selected)) {
              return LinglongTheme.switchActiveTrack;
            }
            return LinglongTheme.switchInactiveTrack;
          }),
          trackOutlineColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return LinglongTheme.switchActiveThumb;
            }
            return const Color(0xFFBDBDBD);
          }),
        ),
      ),
      home: const ScriptLauncher(),
    );
  }
}

class _RecordedFlowConversionDialogResult {
  const _RecordedFlowConversionDialogResult({
    required this.savedResult,
    required this.conversionResult,
  });

  final SavedCustomFlowResult savedResult;
  final RecordedFlowConversionResult conversionResult;
}

class ScriptLauncher extends StatefulWidget {
  const ScriptLauncher({super.key});

  @override
  State<ScriptLauncher> createState() => _ScriptLauncherState();
}

class _ScriptLauncherState extends State<ScriptLauncher>
    with SingleTickerProviderStateMixin {
  static const int _maxOutputChars = 40000;
  static const Duration _outputFlushInterval = Duration(milliseconds: 120);
  static const Duration _savePreferencesDebounce = Duration(milliseconds: 250);

  String _output = '';
  final StringBuffer _pendingOutputBuffer = StringBuffer();
  Timer? _outputFlushTimer;
  Timer? _savePreferencesTimer;
  DateTime? _lastAdbRestartAt;
  bool _isRecordingFlow = false;
  bool _isConvertingRecordedFlow = false;
  String? _activeRecordingDeviceId;
  bool _isTestUser = false;
  bool _needCheck = false;
  bool _isFirstDoneTupo = false;
  bool _isKuaQuSwitchOn = false;
  bool _isKun1SwitchOn = false;
  bool _isLoopToTupoSwitchOn = false;
  bool _isLoopToTupoSwitchOn1 = true;
  bool _isLoopToTupoSwitchOn2 = true;

  // 3是是否开启循环
  bool _isLoopToTupoSwitchOn3 = true;

  // 4其实是组队3
  bool _isLoopToTupoSwitchOn4 = true;
  bool _customFlowParallelExecution = false;

  final bool _isDebug = kDebugMode;
  final List<Process> _runningProcesses = [];
  final TextEditingController _commandController = TextEditingController();
  final TextEditingController _flowNameController = TextEditingController(
    text: 'new_flow',
  );
  final TextEditingController _customFlowNameController = TextEditingController(
    text: 'custom_flow',
  );
  final TextEditingController _customFlowLoopController = TextEditingController(
    text: '1',
  );
  final TextEditingController _flowLoopController = TextEditingController(
    text: '1',
  );
  final TextEditingController _flowSampleIntervalController =
      TextEditingController(text: '100');
  final TextEditingController _battleTimeAddController = TextEditingController(
    text: '0',
  ); // 设备卡顿时间偏移
  final TextEditingController _battleTimeController = TextEditingController(
    text: '17',
  ); // 单次战斗时间
  final TextEditingController _tupoOutTimeController = TextEditingController(
    text: '4',
  ); // 突破自动退4
  final TextEditingController _bottomController = TextEditingController(
    text: '-1',
  ); // 执行次数
  final TextEditingController _runTimesController = TextEditingController(
    text: '0',
  ); // 寮突破识图阈值
  final TextEditingController _picCtrlController = TextEditingController(
    text: '0.68',
  ); // 自定义点击中心bottom，默认-1
  final TextEditingController _rightController = TextEditingController(
    text: '-1',
  ); // 自定义点击中心right，默认-1
  String _selectedArg = 'yu_lin'; // 默认模式
  final ScrollController _scrollController = ScrollController();
  final TouchRecorderService _touchRecorderService = TouchRecorderService();
  final RecordedFlowToCustomFlowConverter _recordedFlowConverter =
      const RecordedFlowToCustomFlowConverter();
  late SharedPreferences _prefs;
  bool init = false;
  List<String> _connectedDevices = []; // 已连接的设备列表
  List<String> _selectedDevices = []; // 已选择的设备列表
  String _selectedDeviceId = ''; // 当前选择的设备ID
  List<String> _savedFlows = []; // 已保存的录制流程

  /// 已保存录制流程的编辑期提示（刷新列表时算一次，见 lintRecordedFlow）。
  Map<String, List<RecordedFlowIssue>> _recordedFlowIssues =
      <String, List<RecordedFlowIssue>>{};
  String _selectedFlowName = '';
  List<String> _selectedPlaybackFlows = [];
  late final CustomFlowStorageService _customFlowStorageService =
      debugCustomFlowStorageService ??
      CustomFlowStorageService(touchRecorderService: _touchRecorderService);
  List<String> _savedCustomFlows = [];
  String _selectedCustomFlowName = '';
  List<CustomFlowStep> _customFlowSteps = [];
  Set<String> _selectedCustomFlowStepIds = <String>{};
  List<String> _availableTemplateNames = [];
  late final TabController _featureTabController;
  int _featureTabIndex = 0;
  WindowsHelperClient? _windowsHelperClient;
  WindowsDeviceService? _windowsDeviceService;
  // 预留：后续可在设置里指定工程根目录
  final String _windowsWorkspaceRoot = '';
  int _customFlowIdSequence = 0;

  static const Map<String, String> _gameModeLabels = <String, String>{
    'liao_tupo': '寮突破',
    'daoguan': '僵尸寮道馆',
    'kun28_double': '困28组队',
    'kun28_single': '困28单人',
    'tu_po': '结界突破',
    'pa_ta': '爬塔',
    'double_mode': '御魂组队',
    'ye_huo_yuan': '业火原',
    'yu_lin': '御灵',
    'PK_mode': '自动斗技',
    'qi_lin_single': '契灵单人',
    'qi_lin_double': '契灵组队',
    'dao_zhang': '英杰经验本',
    'bai_gui': '百鬼夜行',
    'single_mode': '单设备测试用',
  };

  static const Map<String, String> _legacyGameModeKeys = <String, String>{
    '寮突破': 'liao_tupo',
    '僵尸寮道馆': 'daoguan',
    '困28组队': 'kun28_double',
    '困28单人': 'kun28_single',
    '结界突破': 'tu_po',
    '爬塔': 'pa_ta',
    '御魂组队': 'double_mode',
    '多设备组队': 'double_mode',
    '业火原': 'ye_huo_yuan',
    '御灵': 'yu_lin',
    '寮招新': 'yu_lin',
    '自动斗技': 'PK_mode',
    'PK': 'PK_mode',
    '契灵单人': 'qi_lin_single',
    '契灵组队': 'qi_lin_double',
    '英杰经验本': 'dao_zhang',
    '藤原道长': 'dao_zhang',
    '百鬼夜行': 'bai_gui',
    '单设备测试用': 'single_mode',
    '单设备': 'single_mode',
  };

  static const String _defaultGameModeName = 'yu_lin';
  static const Set<String> _deprecatedGameModeNames = <String>{'bai_gui'};

  static const List<String> _availableGameModeNames = <String>[
    'liao_tupo',
    'daoguan',
    'kun28_double',
    'kun28_single',
    'tu_po',
    'pa_ta',
    'double_mode',
    'ye_huo_yuan',
    'yu_lin',
    'PK_mode',
    'qi_lin_single',
    'qi_lin_double',
    'dao_zhang',
    'single_mode',
  ];

  String _normalizeGameModeName(String mode) {
    final trimmed = mode.trim();
    return _gameModeLabels.containsKey(trimmed)
        ? trimmed
        : (_legacyGameModeKeys[trimmed] ?? trimmed);
  }

  String _gameModeLabel(String mode) {
    final key = _normalizeGameModeName(mode);
    return _gameModeLabels[key] ?? mode;
  }

  String _selectableGameModeNameOrDefault(String mode) {
    final normalized = _normalizeGameModeName(mode);
    if (!_deprecatedGameModeNames.contains(normalized) &&
        _availableGameModeNames.contains(normalized)) {
      return normalized;
    }
    return _defaultGameModeName;
  }

  Map<String, dynamic> _buildCurrentGameModeConfigSnapshot([String? mode]) {
    final modeKey = _normalizeGameModeName(mode ?? _selectedArg);
    return {
      'mode': modeKey,
      'battleTime': setDefault(_battleTimeController.text.trim(), '0'),
      'bottom': setDefault(_bottomController.text.trim(), '-1'),
      'right': setDefault(_rightController.text.trim(), '-1'),
      'runTimes': setDefault(_runTimesController.text.trim(), '0'),
      'battleTimeAdd': setDefault(_battleTimeAddController.text.trim(), '0'),
      'picCtrl': setDefault(_picCtrlController.text.trim(), '0.68'),
      'tupoOutTime': setDefault(_tupoOutTimeController.text.trim(), '4'),
      'isDebug': _isDebug,
      'isKuaQuSwitchOn': _isKuaQuSwitchOn,
      'isKun1SwitchOn': _isKun1SwitchOn,
      'isLoopToTupoSwitchOn': _isLoopToTupoSwitchOn,
      'isLoopToTupoSwitchOn1': _isLoopToTupoSwitchOn1,
      'isLoopToTupoSwitchOn2': _isLoopToTupoSwitchOn2,
      'isLoopToTupoSwitchOn3': _isLoopToTupoSwitchOn3,
      'isLoopToTupoSwitchOn4': _isLoopToTupoSwitchOn4,
      'isTestUser': _isTestUser,
      'needCheck': _needCheck,
      'isFirstDoneTupo': _isFirstDoneTupo,
    };
  }

  Map<String, dynamic> _parseGameModeConfigSnapshot(
    String rawJson,
    String mode,
  ) {
    final modeKey = _normalizeGameModeName(mode);
    final fallback = _buildCurrentGameModeConfigSnapshot(mode);
    if (rawJson.trim().isEmpty) {
      return fallback;
    }
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) {
        return fallback;
      }
      final map = Map<String, dynamic>.from(decoded);
      return {...fallback, ...map, 'mode': modeKey};
    } catch (_) {
      return fallback;
    }
  }

  String _battleTimePreferenceKey([String? mode]) {
    final targetMode = _normalizeGameModeName(mode ?? _selectedArg);
    final normalized = targetMode.replaceAll(
      RegExp(r'[^A-Za-z0-9\u4e00-\u9fa5]+'),
      '_',
    );
    return 'battleTime_$normalized';
  }

  String _battleTimeForMode(String mode) {
    return _prefs.getString(_battleTimePreferenceKey(mode)) ??
        _prefs.getString('battleTime') ??
        '17';
  }

  void _loadBattleTimeForMode(String mode) {
    _battleTimeController.text = _battleTimeForMode(mode);
  }

  void _changeSelectedArg(String newValue) {
    final normalizedNewValue = _normalizeGameModeName(newValue);
    final previousMode = _selectedArg;
    final currentBattleTime = _battleTimeController.text.trim();
    if (previousMode == normalizedNewValue) {
      return;
    }
    _prefs.setString(_battleTimePreferenceKey(previousMode), currentBattleTime);
    setState(() {
      _selectedArg = normalizedNewValue;
      _loadBattleTimeForMode(normalizedNewValue);
      _savePreferences();
    });
  }

  @override
  void initState() {
    super.initState();
    _featureTabController = TabController(length: 3, vsync: this);
    _featureTabController.addListener(() {
      if (_featureTabController.indexIsChanging) {
        return;
      }
      if (_featureTabIndex != _featureTabController.index) {
        setState(() {
          _featureTabIndex = _featureTabController.index;
        });
      }
    });
    _loadAvailableTemplateNames();
    _loadPreferences();
    _setupListeners();
    _touchRecorderService.logs.listen((line) {
      if (!mounted) {
        return;
      }
      _appendOutputThrottled('[录制] $line\n');
    });
  }

  @override
  void dispose() {
    _outputFlushTimer?.cancel();
    _savePreferencesTimer?.cancel();
    _killAllProcesses();
    _commandController.dispose();
    _flowNameController.dispose();
    _customFlowNameController.dispose();
    _customFlowLoopController.dispose();
    _flowLoopController.dispose();
    _flowSampleIntervalController.dispose();
    _battleTimeController.dispose();
    _tupoOutTimeController.dispose();
    _battleTimeAddController.dispose();
    _bottomController.dispose();
    _runTimesController.dispose();
    _picCtrlController.dispose();
    _rightController.dispose();
    _scrollController.dispose();
    _featureTabController.dispose();
    _touchRecorderService.dispose();
    unawaited(_shutdownWindowsDeviceService());
    super.dispose();
  }

  void _checkLocalUser() async {
    try {
      // todo生成
      int newTime = 1819515041;
      // String warmTime = "一个月${DateTime.fromMillisecondsSinceEpoch(
      // String warmTime = "半年${DateTime.fromMillisecondsSinceEpoch(
      String warmTime = "一年${DateTime.fromMillisecondsSinceEpoch(
          newTime * 1000).toString().substring(0, 19)}";
      print(warmTime);
      for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 5; j++) {
          // 远端的
          var encrypt = EncryptUtil().encrypt('当前时间$i$newTime$j');
          // 本地的
          // var encrypt = EncryptUtil().encrypt('当前时间$newTime');
          print('$i$j:\n$encrypt');
        }
      }
      print(warmTime);

      var decrypt = EncryptUtil().decrypt(userCheck.value);
      // 拿到解密码
      var split = decrypt.split("当前时间");
      decrypt = split.last;
      var decryptUuid = split.first;

      // 验证uuid
      var uuid = await Utils().getDeviceUUID();
      print('========uuid$uuid');
      var tempUUid = _prefs.getString('userCount');
      if (tempUUid == null) {
        // 本地没有uuid
        uuidCount.value = uuid;
        // 更新uuid和用户信息
        _prefs.setString('userCount', EncryptUtil().encrypt(uuid));
        _prefs.setString(
          'userCheck',
          EncryptUtil().encrypt('$uuid当前时间$decrypt'),
        );
      } else {
        var tempUUidDecrypt = EncryptUtil().decrypt(tempUUid);
        if (uuid != tempUUidDecrypt || uuid != decryptUuid) {
          showDialog.value = true;
          userResult.value = "用户信息前后不一致";
          return;
        }
      }

      // 获取当前
      int time = await NetworkTimeUtil.getAliyunNetworkTimestamp();
      // 示例码中间部分
      showEncrypt.value = EncryptUtil().encrypt('示例$time');

      // 显示剩余时间
      dateTime.value = DateTime.fromMillisecondsSinceEpoch(
        int.parse(decrypt) * 1000,
      ).toString().substring(0, 19);
      if (int.parse(decrypt) > time) {
        showDialog.value = false;
      } else {
        showDialog.value = true;
      }
    } catch (e) {
      print('==================checkUser error:$e');
      showDialog.value = true;
    }
  }

  Future<void> _loadPreferences() async {
    _prefs = await SharedPreferences.getInstance();

    // 打印SharedPreferences存储路径
    if (Platform.isWindows) {
      final appDataPath = Platform.environment['APPDATA'];
      print(
        'SharedPreferences存储路径: $appDataPath\\com.example\\ai\\shared_preferences.json',
      );
    }

    // 加载保存的参数
    setState(() {
      // 兼容旧版本数据
      final s = _selectableGameModeNameOrDefault(
        _prefs.getString('selectedArg') ?? _defaultGameModeName,
      );
      _selectedArg = s;
      _loadBattleTimeForMode(_selectedArg);
      _tupoOutTimeController.text = _prefs.getString('tupoOutTime') ?? '4';
      _battleTimeAddController.text = _prefs.getString('battleTimeAdd') ?? '0';
      _bottomController.text = _prefs.getString('bottom') ?? '-1';
      _rightController.text = _prefs.getString('right') ?? '-1';
      _isKuaQuSwitchOn = _prefs.getBool('_isKuaQuSwitchOn') ?? false;
      _isKun1SwitchOn = _prefs.getBool('_isKun1SwitchOn') ?? false;
      _isTestUser = _prefs.getBool('_isTestUser') ?? false;
      _needCheck = _prefs.getBool('_needCheck') ?? true;
      _isFirstDoneTupo = _prefs.getBool('_isFirstDoneTupo') ?? false;
      _isLoopToTupoSwitchOn = _prefs.getBool('_isLoopToTupoSwitchOn') ?? false;
      _isLoopToTupoSwitchOn1 = _prefs.getBool('_isLoopToTupoSwitchOn1') ?? true;
      _isLoopToTupoSwitchOn2 = _prefs.getBool('_isLoopToTupoSwitchOn2') ?? true;
      _isLoopToTupoSwitchOn3 = _prefs.getBool('_isLoopToTupoSwitchOn3') ?? true;
      _isLoopToTupoSwitchOn4 = _prefs.getBool('_isLoopToTupoSwitchOn4') ?? true;
      _flowNameController.text = _prefs.getString('flowName') ?? 'new_flow';
      _flowLoopController.text = _prefs.getString('flowLoopCount') ?? '1';
      _flowSampleIntervalController.text =
          _prefs.getString('flowSampleIntervalMs') ?? '100';
      _customFlowNameController.text =
          _prefs.getString('customFlowName') ?? 'custom_flow';
      _customFlowLoopController.text =
          _prefs.getString('customFlowLoopCount') ?? '1';
      _customFlowParallelExecution =
          _prefs.getBool('customFlowParallelExecution') ?? false;
      _selectedFlowName = _prefs.getString('selectedFlowName') ?? '';
      _selectedCustomFlowName =
          _prefs.getString('selectedCustomFlowName') ?? '';
      _selectedPlaybackFlows =
          _prefs.getStringList('selectedPlaybackFlows') ?? <String>[];
      init = true;
    });
    // _prefs.setString('userCheck','ZUk40o1AESE0HrnH2im9cFM7gG1jpgcKwMAkv10VwwY=');
    var tempUserCheck = _prefs.getString('userCheck');
    if (tempUserCheck == null) {
      tempUserCheck = hint.value;
      _prefs.setString('userCheck', tempUserCheck);
    }
    userCheck.value = tempUserCheck;
    randomEntry.value = Random().nextInt(6);
    leftEntry.value =
        _prefs.getString('leftEntry') ?? Random().nextInt(5).toString();
    rightEntry.value =
        _prefs.getString('rightEntry') ?? Random().nextInt(5).toString();
    _prefs.setString('leftEntry', leftEntry.value);
    _prefs.setString('rightEntry', rightEntry.value);
    if (Platform.isMacOS) {
      showDialog.value = false;
    } else {
      _checkLocalUser();
    }
    await _reloadSavedFlows();
    await _reloadSavedCustomFlows();
  }

  void _setupListeners() {
    // 监听参数变化，保存到本地存储
    _battleTimeAddController.addListener(() {
      _scheduleSavePreferences();
    });
    _battleTimeController.addListener(() {
      _scheduleSavePreferences();
    });
    _tupoOutTimeController.addListener(() {
      _scheduleSavePreferences();
    });
    _bottomController.addListener(() {
      _scheduleSavePreferences();
    });
    _rightController.addListener(() {
      _scheduleSavePreferences();
    });
  }

  void _appendOutputThrottled(String text) {
    _pendingOutputBuffer.write(text);
    _outputFlushTimer ??= Timer(_outputFlushInterval, _flushPendingOutput);
  }

  void _flushPendingOutput() {
    _outputFlushTimer = null;
    if (!mounted || _pendingOutputBuffer.isEmpty) {
      _pendingOutputBuffer.clear();
      return;
    }
    final pendingText = _pendingOutputBuffer.toString();
    _pendingOutputBuffer.clear();
    setState(() {
      _output += pendingText;
      _trimOutput();
      _scrollToBottom();
    });
  }

  void _trimOutput() {
    if (_output.length <= _maxOutputChars) {
      return;
    }
    _output = _output.substring(_output.length - _maxOutputChars);
  }

  void _scheduleSavePreferences() {
    _savePreferencesTimer?.cancel();
    _savePreferencesTimer = Timer(_savePreferencesDebounce, _savePreferences);
  }

  String _readableError(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  bool get _isWindowsClientMode =>
      !kIsWeb && (Platform.isWindows || debugForceWindowsClientMode);

  /// 时空 Windows 版：定位 Python 侧脚本（工程目录优先，发布版回退到 assets 解包）。
  Future<WinWorkspace> _resolveWindowsWorkspace() async {
    Directory? runtimeDirectory;
    try {
      final support = await getApplicationSupportDirectory();
      runtimeDirectory = Directory('${support.path}/win_runtime');
    } catch (_) {
      runtimeDirectory = null;
    }
    final workspace = await WinWorkspace.resolve(
      overrideRoot: _windowsWorkspaceRoot,
      runtimeDirectory: runtimeDirectory,
    );
    if (workspace == null || !workspace.isAvailable) {
      throw Exception(
        '未找到时空客户端控制脚本（需要 scripts/win/win_device.py 与 tools/win_helper.py）。'
        '请把本项目放在完整工程目录中运行，或使用包含脚本资源的完整安装包。'
        '当前工作目录：${Directory.current.path}',
      );
    }
    return workspace;
  }

  /// 常驻控制服务（懒启动）：界面上的点击/截图/输入都走它。
  Future<WindowsDeviceService> _ensureWindowsDeviceService() async {
    final existing = _windowsDeviceService;
    if (existing != null) {
      return existing;
    }
    final workspace = await _resolveWindowsWorkspace();
    final pythonExecutable = await _resolvePythonExecutable();
    final client = WindowsHelperClient(
      workspace: workspace,
      pythonExecutable: pythonExecutable,
      logSink: (line) {
        if (!mounted) {
          return;
        }
        setState(() {
          _output += '[控制服务] $line\n';
          _scrollToBottom();
        });
      },
    );
    _windowsHelperClient = client;
    final service = WindowsDeviceService(client);
    _windowsDeviceService = service;
    return service;
  }

  Future<void> _shutdownWindowsDeviceService() async {
    final client = _windowsHelperClient;
    _windowsHelperClient = null;
    _windowsDeviceService = null;
    if (client != null) {
      await client.stop();
    }
  }

  /// Windows 版：窗口客户区不必是 1600×900（截图与坐标会自动归一化），
  /// 这里只做"尽力对齐"并把结果写进日志，不阻塞流程。
  Future<bool> _ensureWindowsClientWindows({
    required List<String> deviceIds,
    required String featureName,
  }) async {
    try {
      final service = await _ensureWindowsDeviceService();
      for (final deviceId in deviceIds) {
        try {
          final result = await service.resize(deviceId);
          if (!mounted) {
            return false;
          }
          setState(() {
            _output +=
                '[$deviceId] 客户端窗口已就绪：${result['size'] ?? result['device']}\n';
            _scrollToBottom();
          });
        } catch (e) {
          if (!mounted) {
            return false;
          }
          setState(() {
            _output +=
                '[$deviceId] 窗口尺寸对齐失败（不影响执行，坐标会按比例换算）：${_readableError(e)}\n';
            _scrollToBottom();
          });
        }
      }
      return true;
    } catch (e) {
      await _showFlowInterruptionDialog(
        title: '无法$featureName',
        message: _readableError(e),
      );
      return false;
    }
  }

  Future<void> _refreshWindowsDevices() async {
    try {
      final devices = await _readConnectedDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _connectedDevices = devices;
        _selectedDevices = _selectedDevices
            .where((item) => devices.contains(item))
            .toList(growable: false);
        _output += '已刷新客户端窗口：${devices.join(', ')}\n';
        _scrollToBottom();
      });
    } catch (e) {
      await _showFlowInterruptionDialog(
        title: '刷新客户端窗口失败',
        message: _readableError(e),
      );
    }
  }

  Future<void> _windowsClientAction(String action) async {
    final deviceId = _getSingleTargetDevice() ??
        (_connectedDevices.isNotEmpty ? _connectedDevices.first : '');
    if (deviceId.isEmpty) {
      await _showFlowInterruptionDialog(
        title: '没有可用设备',
        message: '请先启动《梦幻西游：时空》客户端，再点击「刷新客户端窗口」。',
      );
      return;
    }
    try {
      final service = await _ensureWindowsDeviceService();
      late final Map<String, dynamic> result;
      switch (action) {
        case 'ensureRunning':
          result = await service.ensureRunning(deviceId);
        case 'restart':
          result = await service.restartClient(deviceId);
        case 'resize':
          result = await service.resize(deviceId);
        case 'probe':
          result = await service.probeCapture(deviceId);
        default:
          throw Exception('未知客户端操作：$action');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '[$deviceId] $action 完成：$result\n';
        _scrollToBottom();
      });
    } catch (e) {
      await _showFlowInterruptionDialog(
        title: '客户端操作失败',
        message: _readableError(e),
      );
    }
  }

  bool _looksLikeDeviceFailure(Object error) {
    final text = _readableError(error).toLowerCase();
    return text.contains('adb') ||
        text.contains('device') ||
        text.contains('设备') ||
        text.contains('模拟器') ||
        text.contains('getevent') ||
        text.contains('sendevent') ||
        text.contains('触摸') ||
        text.contains('分辨率');
  }

  Future<void> _showFlowInterruptionDialog({
    required String title,
    required String message,
  }) async {
    final trimmedMessage = message.trim();
    if (trimmedMessage.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _output += '$trimmedMessage\n';
      _scrollToBottom();
    });
    if (!mounted) {
      return;
    }
    await showAdaptiveDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SelectionArea(child: Text(trimmedMessage)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<List<String>> _readConnectedDevices() async {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      throw Exception('此功能仅支持 Windows、macOS 和 Linux 桌面平台');
    }

    if (_isWindowsClientMode) {
      final service = await _ensureWindowsDeviceService();
      final ids = await service.listDeviceIds();
      if (ids.isEmpty) {
        throw Exception('未发现《梦幻西游：时空》客户端窗口，请先启动客户端。');
      }
      return ids;
    }

    final result = await Process.run('adb', ['devices']);
    if (result.exitCode != 0) {
      final errorText = result.stderr.toString().trim().isNotEmpty
          ? result.stderr.toString().trim()
          : result.stdout.toString().trim();
      throw Exception('获取设备列表失败: $errorText');
    }
    return parseConnectedAdbDeviceIds(result.stdout.toString());
  }

  Future<List<String>?> _refreshConnectedDevicesForFlow({
    required String failureTitle,
  }) async {
    try {
      final devices = await _readConnectedDevices();
      if (!mounted) {
        return null;
      }
      setState(() {
        _connectedDevices = devices;
      });
      return devices;
    } catch (e) {
      await _showFlowInterruptionDialog(
        title: failureTitle,
        message: _readableError(e),
      );
      return null;
    }
  }

  Future<FlowDeviceResolution?> _prepareFlowDevices({
    required String dialogTitle,
    required String operationLabel,
    required FlowDeviceRequirement requirement,
    Iterable<String> requiredDeviceIds = const <String>[],
    Iterable<String>? selectedDeviceIdsOverride,
  }) async {
    final connectedDevices = await _refreshConnectedDevicesForFlow(
      failureTitle: dialogTitle,
    );
    if (connectedDevices == null || !mounted) {
      return null;
    }
    final result = resolveFlowDeviceSelection(
      selectedDeviceIds: selectedDeviceIdsOverride ?? _selectedDevices,
      connectedDeviceIds: connectedDevices,
      requiredDeviceIds: requiredDeviceIds,
      requirement: requirement,
      operationLabel: operationLabel,
    );
    if (!result.isValid) {
      await _showFlowInterruptionDialog(
        title: dialogTitle,
        message: result.message,
      );
      return null;
    }
    return result;
  }

  Future<void> _getConnectedDevices() async {
    try {
      final devices = await _readConnectedDevices();
      setState(() {
        _connectedDevices = devices;
        _output += '已获取连接的设备: $devices\n';
        _scrollToBottom();
      });
    } catch (e) {
      setState(() {
        _output += '获取设备列表时出错: ${_readableError(e)}\n';
        _scrollToBottom();
      });
    }
  }

  void _addDeviceToList() {
    if (_selectedDeviceId.isNotEmpty &&
        !_selectedDevices.contains(_selectedDeviceId)) {
      setState(() {
        _selectedDevices.add(_selectedDeviceId);
        _output += '已添加设备: $_selectedDeviceId\n';
        _scrollToBottom();
      });
    }
  }

  void _removeDeviceFromList(String deviceId) {
    setState(() {
      _selectedDevices.remove(deviceId);
      _output += '已移除设备: $deviceId\n';
      _scrollToBottom();
    });
  }

  String? _getSingleTargetDevice() {
    if (_selectedDevices.length == 1) {
      return _selectedDevices.first;
    }
    if (_selectedDevices.isEmpty && _connectedDevices.length == 1) {
      return _connectedDevices.first;
    }
    return null;
  }

  List<String> _getAdbTargetDevices() {
    if (_selectedDevices.isNotEmpty) {
      return List<String>.from(_selectedDevices);
    }
    return List<String>.from(_connectedDevices);
  }

  Future<bool> _ensureSupportedEmulatorResolution({
    required List<String> deviceIds,
    required String featureName,
  }) async {
    if (_isWindowsClientMode) {
      return _ensureWindowsClientWindows(
        deviceIds: deviceIds,
        featureName: featureName,
      );
    }

    final unsupportedDevices = <String>[];
    final unreadableDevices = <String>[];

    for (final deviceId in deviceIds) {
      try {
        final screenSize = await _touchRecorderService.getScreenSize(deviceId);
        if (!screenSize.isSupportedAutomationResolution) {
          unsupportedDevices.add(
            '$deviceId：${screenSize.width}×${screenSize.height}',
          );
        }
      } catch (e) {
        unreadableDevices.add('$deviceId：$e');
      }
    }

    if (unsupportedDevices.isEmpty && unreadableDevices.isEmpty) {
      return true;
    }
    if (!mounted) {
      return false;
    }

    final details = <String>[
      if (unsupportedDevices.isNotEmpty) ...[
        '分辨率不符合要求：',
        ...unsupportedDevices,
      ],
      if (unreadableDevices.isNotEmpty) ...[
        if (unsupportedDevices.isNotEmpty) '',
        '无法读取分辨率：',
        ...unreadableDevices,
      ],
    ].join('\n');
    setState(() {
      _output +=
          '已取消$featureName：模拟器分辨率必须为 1600×900 或 900×1600。\n'
          '$details\n';
      _scrollToBottom();
    });

    await showAdaptiveDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('请先修改模拟器分辨率'),
        content: SelectionArea(
          child: Text(
            '$featureName仅支持以下分辨率：\n'
            '1600×900（横屏）\n'
            '900×1600（竖屏）\n\n'
            '$details\n\n'
            '请修改模拟器分辨率后重新操作。',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return false;
  }

  Future<bool> _isDeveloperOptionsEnabled(String deviceId) async {
    final result = await Process.run('adb', [
      '-s',
      deviceId,
      'shell',
      'settings',
      'get',
      'global',
      'development_settings_enabled',
    ]);
    if (result.exitCode != 0) {
      throw Exception(
        '检查开发者选项失败: ${result.stderr.toString().trim().isEmpty ? result.stdout : result.stderr}',
      );
    }
    return result.stdout.toString().trim() == '1';
  }

  Future<void> _openDeveloperOptionsPage({
    required List<String> deviceIds,
  }) async {
    if (deviceIds.isEmpty) {
      setState(() {
        _output += '未找到可操作的设备，请先刷新并选择设备。\n';
        _scrollToBottom();
      });
      return;
    }
    setState(() {
      _output += '准备打开开发者选项页面，目标设备: ${deviceIds.join(', ')}\n';
      _scrollToBottom();
    });
    for (final deviceId in deviceIds) {
      final result = await Process.run('adb', [
        '-s',
        deviceId,
        'shell',
        'am',
        'start',
        '-a',
        'android.settings.APPLICATION_DEVELOPMENT_SETTINGS',
      ]);
      setState(() {
        if (result.exitCode == 0) {
          _output += '[$deviceId] 已尝试打开开发者选项页面，请在设备上开启“开发者选项”后再重试。\n';
        } else {
          _output +=
              '[$deviceId] 打开开发者选项页面失败: '
              '${result.stderr.toString().trim().isEmpty ? result.stdout : result.stderr}\n';
        }
        _scrollToBottom();
      });
    }
  }

  Future<void> _showDeveloperOptionsGuide({
    required List<String> deviceIds,
  }) async {
    if (!mounted) {
      return;
    }
    await showAdaptiveDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('请先开启开发者选项'),
          content: deviceIds.isEmpty
              ? Text('当前没有可操作的设备。请先刷新设备列表并选择设备。')
              : Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 14, fontFamily: 'Courier'),
                    children: const [
                      TextSpan(
                        text:
                            '检测到目标设备的开发者选项可能未开启。\n\n'
                            '请先在模拟器里开启开发者选项，再回来点击“开启坐标显示”。\n\n'
                            '操作路径：',
                      ),
                      TextSpan(
                        text: '打开设置 > 滑到底部关于手机 > 滑到底部版本号 > 连点 7 次\n\n',
                        style: TextStyle(
                          color: LinglongTheme.goldDeep,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      TextSpan(text: '你也可以直接点下方按钮，让设备尝试跳转到开发者选项页面。'),
                    ],
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: deviceIds.isEmpty
                  ? null
                  : () async {
                      Navigator.of(dialogContext).pop();
                      await _openDeveloperOptionsPage(deviceIds: deviceIds);
                    },
              child: const Text('打开开发者选项'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _togglePointerLocation({required bool enabled}) async {
    final deviceIds = _getAdbTargetDevices();
    if (deviceIds.isEmpty) {
      setState(() {
        _output += '未找到可操作的设备，请先刷新并选择设备。\n';
        _scrollToBottom();
      });
      return;
    }

    final actionText = enabled ? '开启' : '关闭';
    setState(() {
      _output += '准备$actionText模拟器坐标显示，目标设备: ${deviceIds.join(', ')}\n';
      _scrollToBottom();
    });

    final developerDisabledDevices = <String>[];
    for (final deviceId in deviceIds) {
      try {
        final developerEnabled = await _isDeveloperOptionsEnabled(deviceId);
        if (!developerEnabled) {
          developerDisabledDevices.add(deviceId);
          continue;
        }
        final pointerResult = await Process.run('adb', [
          '-s',
          deviceId,
          'shell',
          'settings',
          'put',
          'system',
          'pointer_location',
          enabled ? '1' : '0',
        ]);
        final tapsResult = await Process.run('adb', [
          '-s',
          deviceId,
          'shell',
          'settings',
          'put',
          'system',
          'show_touches',
          enabled ? '1' : '0',
        ]);
        setState(() {
          if (pointerResult.exitCode == 0 && tapsResult.exitCode == 0) {
            _output +=
                '[$deviceId] 已$actionText坐标显示'
                '${enabled ? '（同时开启点按轨迹）' : '（同时关闭点按轨迹）'}。\n';
          } else {
            final errorText = [
              pointerResult.stderr.toString().trim(),
              tapsResult.stderr.toString().trim(),
              pointerResult.stdout.toString().trim(),
              tapsResult.stdout.toString().trim(),
            ].where((item) => item.isNotEmpty).join('\n');
            _output += '[$deviceId] $actionText坐标显示失败: $errorText\n';
          }
          _scrollToBottom();
        });
      } catch (e) {
        setState(() {
          _output += '[$deviceId] $actionText坐标显示异常: $e\n';
          _scrollToBottom();
        });
      }
    }

    if (developerDisabledDevices.isNotEmpty) {
      setState(() {
        _output +=
            '以下设备尚未开启开发者选项，暂时无法$actionText坐标显示: '
            '${developerDisabledDevices.join(', ')}\n';
        _scrollToBottom();
      });
      await _showDeveloperOptionsGuide(deviceIds: developerDisabledDevices);
    }
  }

  /// Windows 版：时空客户端工具面板（替代模拟器坐标显示）。
  Widget _buildWindowsClientTools() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.blueGrey.shade100),
        borderRadius: BorderRadius.circular(10),
        color: Colors.grey.shade50,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '时空客户端工具',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            '窗口消息级控制：枚举多开窗口、后台截图、后台点击与文字输入，'
            '不注入进程、不读写游戏内存。多开时每个窗口是一个设备（win:<进程号>），'
            '所有坐标统一按 1600×900 换算，窗口多大都不用改流程。',
            style: TextStyle(fontSize: 12.5, color: Colors.blueGrey),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _refreshWindowsDevices,
                child: const Text('刷新客户端窗口'),
              ),
              OutlinedButton(
                onPressed: () => _windowsClientAction('ensureRunning'),
                child: const Text('确保客户端运行'),
              ),
              OutlinedButton(
                onPressed: () => _windowsClientAction('restart'),
                child: const Text('重启客户端'),
              ),
              OutlinedButton(
                onPressed: () => _windowsClientAction('resize'),
                child: const Text('窗口对齐 1600×900'),
              ),
              TextButton(
                onPressed: () => _windowsClientAction('probe'),
                child: const Text('截图后端自检'),
              ),
            ],
          ),
        ],
      ),
    );
  }


  Widget _buildEmulatorPointerTools() {
    if (_isWindowsClientMode) {
      return _buildWindowsClientTools();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.blueGrey.shade100),
        borderRadius: BorderRadius.circular(10),
        color: Colors.grey.shade50,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '模拟器坐标显示',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            '用于调试点击坐标。开启后会尝试打开 Android 的“指针位置”和“显示点按操作”；如果设备未开启开发者选项，会先提示并可一键跳转到开发者页面。',
            style: TextStyle(fontSize: 12.5, color: Colors.blueGrey),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => _togglePointerLocation(enabled: true),
                child: const Text('开启坐标显示'),
              ),
              OutlinedButton(
                onPressed: () => _togglePointerLocation(enabled: false),
                child: const Text('关闭坐标显示'),
              ),
              TextButton(
                onPressed: () => _openDeveloperOptionsPage(
                  deviceIds: _getAdbTargetDevices(),
                ),
                child: const Text(
                  '打开开发者选项',
                  style: TextStyle(color: Colors.blue),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String? _extractActivityComponentFromOutput(String rawText) {
    const keywords = [
      'mFocusedApp',
      'topResumedActivity',
      'mResumedActivity',
      'ResumedActivity',
    ];
    String source = rawText;
    for (final line in rawText.split('\n')) {
      if (keywords.any(line.contains)) {
        source = line.trim();
        break;
      }
    }
    const separators = '()[]{}<>,;';
    for (final token in source.replaceAll('=', ' ').split(RegExp(r'\s+'))) {
      final cleaned = token.trim().trimLeft().trimRight().replaceAll(
        RegExp(
          '^[${RegExp.escape(separators)}]+|[${RegExp.escape(separators)}]+\$',
        ),
        '',
      );
      if (!cleaned.contains('/')) {
        continue;
      }
      final parts = cleaned.split('/');
      if (parts.length != 2) {
        continue;
      }
      final packageName = parts[0].trim();
      final activityName = parts[1].trim();
      if (packageName.isEmpty || activityName.isEmpty) {
        continue;
      }
      if (!packageName.contains('.')) {
        continue;
      }
      return '$packageName/$activityName';
    }
    return null;
  }

  Future<String> _fetchCurrentActivityComponent(String deviceId) async {
    final result = await Process.run('adb', [
      '-s',
      deviceId,
      'shell',
      'dumpsys',
      'activity',
    ]);
    if (result.exitCode != 0) {
      throw Exception(
        '读取当前 Activity 失败: ${result.stderr.toString().trim().isEmpty ? result.stdout : result.stderr}',
      );
    }
    final component = _extractActivityComponentFromOutput(
      result.stdout.toString(),
    );
    if (component == null || component.isEmpty) {
      throw Exception('未能从 dumpsys activity 输出中解析出 Activity 组件名');
    }
    return component;
  }

  Future<void> _reloadSavedFlows() async {
    final savedFlows = await _touchRecorderService.listFlowNames();
    final issues = await _collectRecordedFlowIssues(savedFlows);
    if (!mounted) {
      return;
    }
    setState(() {
      _savedFlows = savedFlows;
      _recordedFlowIssues = issues;
      _selectedPlaybackFlows = _selectedPlaybackFlows
          .where(_savedFlows.contains)
          .toList();
      if (_savedFlows.isEmpty) {
        _selectedFlowName = '';
      } else if (!_savedFlows.contains(_selectedFlowName)) {
        _selectedFlowName = _savedFlows.first;
      }
      _savePreferences();
    });
  }

  /// 读一遍已保存的录制流程，记下每条的问题（读不出来的流程不在这里报，
  /// 那是刷新列表本身的事）。
  Future<Map<String, List<RecordedFlowIssue>>> _collectRecordedFlowIssues(
    List<String> flowNames,
  ) async {
    final Map<String, List<RecordedFlowIssue>> result =
        <String, List<RecordedFlowIssue>>{};
    for (final String name in flowNames) {
      try {
        final RecordedFlow? flow = await _touchRecorderService.loadFlow(name);
        if (flow == null) {
          continue;
        }
        final List<RecordedFlowIssue> issues = lintRecordedFlow(flow);
        if (issues.isNotEmpty) {
          result[name] = issues;
        }
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  /// 回放列表里所有流程的问题。
  List<RecordedFlowIssue> get _playbackQueueIssues => <RecordedFlowIssue>[
    for (final String name in _selectedPlaybackFlows)
      ...?_recordedFlowIssues[name],
  ];

  Future<void> _loadAvailableTemplateNames() async {
    try {
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final manifest = jsonDecode(manifestContent) as Map<String, dynamic>;
      final templates =
          manifest.keys
              .where((key) => key.startsWith('assets/images/'))
              .map((key) => key.replaceFirst('assets/images/', ''))
              .toList()
            ..sort();
      if (!mounted) {
        return;
      }
      setState(() {
        _availableTemplateNames = templates;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '加载模板图片列表失败: $e\n';
        _scrollToBottom();
      });
    }
  }

  Future<void> _reloadSavedCustomFlows() async {
    final savedFlows = await _customFlowStorageService.listFlowNames();
    if (!mounted) {
      return;
    }
    setState(() {
      _savedCustomFlows = savedFlows;
      if (_savedCustomFlows.isEmpty) {
        _selectedCustomFlowName = '';
      } else if (!_savedCustomFlows.contains(_selectedCustomFlowName)) {
        _selectedCustomFlowName = _savedCustomFlows.first;
      }
      _savePreferences();
    });
  }

  String _defaultSavedCustomFlowName([String? preferredName]) {
    final preferred = preferredName?.trim();
    if (preferred != null && _savedCustomFlows.contains(preferred)) {
      return preferred;
    }
    if (_savedCustomFlows.contains(_selectedCustomFlowName)) {
      return _selectedCustomFlowName;
    }
    return _savedCustomFlows.isNotEmpty ? _savedCustomFlows.first : '';
  }

  Future<({CustomFlowDefinition flow, CustomFlowStep group})?>
  _buildSavedCustomFlowGroupForAppend(
    String flowName, {
    required void Function(String message) onError,
    String emptySelectionMessage = '请先选择一个已保存的自定义流程。',
  }) async {
    final selectedFlowName = flowName.trim();
    if (selectedFlowName.isEmpty) {
      onError(emptySelectionMessage);
      return null;
    }

    final flow = await _customFlowStorageService.loadFlow(selectedFlowName);
    if (flow == null) {
      onError('未找到自定义流程：$selectedFlowName');
      return null;
    }

    final appendedChildren = flow.steps
        .map(_cloneCustomFlowStepWithNewIds)
        .toList(growable: false);
    if (appendedChildren.isEmpty) {
      onError('选中的自定义流程“${flow.name}”没有可追加的步骤。');
      return null;
    }

    final appendedGroup = CustomFlowStep(
      id: _newCustomFlowId(),
      type: CustomFlowStepType.flowGroup,
      label: '拼接流程：${flow.name}',
      children: appendedChildren,
    );

    return (flow: flow, group: appendedGroup);
  }

  Widget _buildSavedCustomFlowInsertControls({
    required String selectedFlowName,
    required ValueChanged<String> onSelectedFlowChanged,
    required VoidCallback? onInsertPressed,
    String? message,
  }) {
    final normalizedSelection = _savedCustomFlows.contains(selectedFlowName)
        ? selectedFlowName
        : null;
    final hasSavedFlows = _savedCustomFlows.isNotEmpty;

    Widget buildDropdown() {
      return DropdownButtonFormField<String>(
        key: ValueKey(
          'insert-saved-custom-flow-$normalizedSelection-${_savedCustomFlows.length}',
        ),
        initialValue: normalizedSelection,
        isExpanded: true,
        decoration: _solidDropdownDecoration(
          '插入已保存自定义流程',
        ).copyWith(helperText: hasSavedFlows ? null : '当前没有已保存的自定义流程'),
        dropdownColor: LinglongTheme.dropdownSurface,
        items: _savedCustomFlows
            .map(
              (value) => DropdownMenuItem<String>(
                value: value,
                child: Text(value, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: hasSavedFlows
            ? (value) {
                if (value == null) {
                  return;
                }
                onSelectedFlowChanged(value);
              }
            : null,
      );
    }

    Widget buildInsertButton({bool expand = false}) {
      final button = ElevatedButton.icon(
        onPressed: hasSavedFlows ? onInsertPressed : null,
        icon: const Icon(Icons.playlist_add),
        label: const Text('插入到末尾', overflow: TextOverflow.ellipsis),
      );
      return expand ? SizedBox(width: double.infinity, child: button) : button;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final useCompactLayout = constraints.maxWidth < 420;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (useCompactLayout) ...[
              SizedBox(width: double.infinity, child: buildDropdown()),
              const SizedBox(height: 8),
              buildInsertButton(expand: true),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: buildDropdown()),
                  const SizedBox(width: 8),
                  buildInsertButton(),
                ],
              ),
            if (message != null && message.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                message,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.blueGrey.shade700,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  String _newCustomFlowId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _customFlowIdSequence = max(_customFlowIdSequence + 1, now);
    return _customFlowIdSequence.toString();
  }

  CustomFlowBranchCase _cloneCustomFlowBranchCaseWithNewIds(
    CustomFlowBranchCase branchCase,
  ) {
    final clonedCaseId = _newCustomFlowId();
    final clonedImages = <CustomFlowBranchImage>[];
    for (
      var index = 0;
      index < branchCase.effectiveTemplateImages.length;
      index++
    ) {
      final image = branchCase.effectiveTemplateImages[index];
      clonedImages.add(
        image.copyWith(id: index == 0 ? clonedCaseId : _newCustomFlowId()),
      );
    }
    return branchCase.copyWith(
      id: clonedCaseId,
      templateImages: clonedImages,
      steps: branchCase.steps
          .map(_cloneCustomFlowStepWithNewIds)
          .toList(growable: false),
    );
  }

  CustomFlowStep _cloneCustomFlowStepWithNewIds(CustomFlowStep step) {
    return step.copyWith(
      id: _newCustomFlowId(),
      children: step.children
          .map(_cloneCustomFlowStepWithNewIds)
          .toList(growable: false),
      branchCases: step.branchCases
          .map(_cloneCustomFlowBranchCaseWithNewIds)
          .toList(growable: false),
      fallbackChildren: step.fallbackChildren
          .map(_cloneCustomFlowStepWithNewIds)
          .toList(growable: false),
    );
  }

  ({List<CustomFlowStep> steps, Set<String> copiedStepIds})?
  _copySelectedStepsInList(
    List<CustomFlowStep> steps,
    Set<String> selectedStepIds,
  ) {
    if (selectedStepIds.isEmpty || steps.isEmpty) {
      return null;
    }
    final selectedIndexes = <int>[];
    for (var index = 0; index < steps.length; index++) {
      if (selectedStepIds.contains(steps[index].id)) {
        selectedIndexes.add(index);
      }
    }
    if (selectedIndexes.isEmpty) {
      return null;
    }

    final copiedSteps = selectedIndexes
        .map((index) => _cloneCustomFlowStepWithNewIds(steps[index]))
        .toList(growable: false);
    final nextSteps = List<CustomFlowStep>.from(steps)
      ..insertAll(selectedIndexes.last + 1, copiedSteps);

    return (
      steps: nextSteps,
      copiedStepIds: copiedSteps.map((step) => step.id).toSet(),
    );
  }

  ({List<CustomFlowStep> steps, int deletedCount})? _deleteSelectedStepsInList(
    List<CustomFlowStep> steps,
    Set<String> selectedStepIds,
  ) {
    if (selectedStepIds.isEmpty || steps.isEmpty) {
      return null;
    }
    var deletedCount = 0;
    final nextSteps = <CustomFlowStep>[];
    for (final step in steps) {
      if (selectedStepIds.contains(step.id)) {
        deletedCount += 1;
      } else {
        nextSteps.add(step);
      }
    }
    if (deletedCount == 0) {
      return null;
    }
    return (steps: nextSteps, deletedCount: deletedCount);
  }

  List<CustomFlowStep> _cloneSelectedStepsForNewFlow(
    List<CustomFlowStep> steps,
    Set<String> selectedStepIds,
  ) {
    if (selectedStepIds.isEmpty || steps.isEmpty) {
      return const [];
    }
    return steps
        .where((step) => selectedStepIds.contains(step.id))
        .map(_cloneCustomFlowStepWithNewIds)
        .toList(growable: false);
  }

  Set<String> _removeStepIdFromSelection(
    Set<String> selectedStepIds,
    String stepId,
  ) {
    if (!selectedStepIds.contains(stepId)) {
      return selectedStepIds;
    }
    return Set<String>.from(selectedStepIds)..remove(stepId);
  }

  void _toggleCustomFlowStepSelection(String stepId, {bool? selected}) {
    setState(() {
      final nextSelection = Set<String>.from(_selectedCustomFlowStepIds);
      final shouldSelect = selected ?? !nextSelection.contains(stepId);
      if (shouldSelect) {
        nextSelection.add(stepId);
      } else {
        nextSelection.remove(stepId);
      }
      _selectedCustomFlowStepIds = nextSelection;
    });
  }

  void _clearCustomFlowStepSelection() {
    if (_selectedCustomFlowStepIds.isEmpty) {
      return;
    }
    setState(() {
      _selectedCustomFlowStepIds = <String>{};
    });
  }

  void _copySelectedCustomFlowSteps() {
    final copyResult = _copySelectedStepsInList(
      _customFlowSteps,
      _selectedCustomFlowStepIds,
    );
    if (copyResult == null) {
      return;
    }

    setState(() {
      _customFlowSteps = copyResult.steps;
      _selectedCustomFlowStepIds = copyResult.copiedStepIds;
    });
  }

  Future<void> _deleteSelectedCustomFlowSteps() async {
    final selectedCount = _selectedCustomFlowStepIds.length;
    if (selectedCount == 0) {
      return;
    }
    final confirmed = await _confirmClearStepList(
      title: '删除选中节点',
      content: '确认删除已选中的 $selectedCount 个节点吗？删除后不可恢复。',
    );
    if (!confirmed) {
      return;
    }
    final deleteResult = _deleteSelectedStepsInList(
      _customFlowSteps,
      _selectedCustomFlowStepIds,
    );
    if (deleteResult == null) {
      return;
    }
    setState(() {
      _customFlowSteps = deleteResult.steps;
      _selectedCustomFlowStepIds = <String>{};
    });
  }

  List<String> _collectCustomFlowStepDeviceIds(List<CustomFlowStep> steps) {
    // 设备范围现在统一由每个步骤的 deviceScope 决定；旧版痒痒鼠步骤的
    // 设备覆盖列表仅为数据兼容保留，不再作为流程启动前的强制设备依赖。
    return const <String>[];
  }

  List<String> _getCustomFlowResolutionCheckDevices(
    List<String> defaultDeviceIds,
  ) {
    final result = <String>{
      ...defaultDeviceIds,
      ..._collectCustomFlowStepDeviceIds(_customFlowSteps),
    };
    return result.toList(growable: false);
  }

  String _stepTypeLabel(CustomFlowStepType type) {
    switch (type) {
      case CustomFlowStepType.wait:
        return '等待';
      case CustomFlowStepType.imageTap:
        return '识图点击';
      case CustomFlowStepType.ocrTap:
        return '识图点击（文字识别）';
      case CustomFlowStepType.coordinateTap:
        return '固定坐标点击';
      case CustomFlowStepType.pasteText:
        return '粘贴文字';
      case CustomFlowStepType.waitImageState:
        return '识图等待';
      case CustomFlowStepType.imageBranch:
        return '多图条件分支';
      case CustomFlowStepType.imagePositionBranch:
        return '识图坐标分支';
      case CustomFlowStepType.loopBlock:
        return '循环块';
      case CustomFlowStepType.flowGroup:
        return '流程组';
      case CustomFlowStepType.gameMode:
        return '执行痒痒鼠模式';
      case CustomFlowStepType.recordedFlow:
        return '执行录制手势流程';
      case CustomFlowStepType.restartActivity:
        return '重启当前Activity';
      case CustomFlowStepType.shutdownComputer:
        return '关机操作';
    }
  }

  String _deviceScopeLabel(CustomFlowDeviceScope scope) {
    switch (scope) {
      case CustomFlowDeviceScope.all:
        return '对所有模拟器生效';
      case CustomFlowDeviceScope.first:
        return '仅对第一个模拟器生效';
      case CustomFlowDeviceScope.others:
        return '对除第一个以外的其他模拟器生效';
    }
  }

  String _safeDefaultTemplateName() {
    if (_availableTemplateNames.isNotEmpty) {
      return _availableTemplateNames.first;
    }
    return 'pk_start.png';
  }

  String _loopTemplateLabel(String templateKey) {
    switch (templateKey) {
      case 'simple':
        return '简单循环模板';
      case 'farm':
        return '刷图模板';
      case 'wait_then_click':
        return '等图后点击模板';
      case 'branch_loop':
        return '分支循环模板';
      default:
        return '完整示例模板';
    }
  }

  String _loopModeLabel(CustomFlowLoopMode mode) {
    switch (mode) {
      case CustomFlowLoopMode.fixedCount:
        return '固定次数';
      case CustomFlowLoopMode.imageCondition:
        return '识图条件';
      case CustomFlowLoopMode.textLines:
        return '按文本逐行';
    }
  }

  String _loopImageActionLabel(
    CustomFlowLoopImageAction action, {
    CustomFlowRecognitionMode recognitionMode = CustomFlowRecognitionMode.image,
  }) {
    final targetText = recognitionMode == CustomFlowRecognitionMode.text
        ? '文字'
        : '图片';
    switch (action) {
      case CustomFlowLoopImageAction.continueOnMatch:
        return '识别到$targetText继续循环';
      case CustomFlowLoopImageAction.stopOnMatch:
        return '识别到$targetText停止循环';
    }
  }

  String _recognitionModeLabel(CustomFlowRecognitionMode mode) {
    switch (mode) {
      case CustomFlowRecognitionMode.image:
        return '图片识别';
      case CustomFlowRecognitionMode.text:
        return '文字识别（RapidOCR）';
    }
  }

  String _ocrMatchModeLabel(CustomFlowOcrMatchMode mode) {
    switch (mode) {
      case CustomFlowOcrMatchMode.contains:
        return '包含匹配';
      case CustomFlowOcrMatchMode.exact:
        return '完全相等';
      case CustomFlowOcrMatchMode.regex:
        return '正则匹配';
    }
  }

  String _buildOcrRegionDescriptor(CustomFlowStep step) {
    final hasRegion =
        step.ocrRegionLeft >= 0 &&
        step.ocrRegionTop >= 0 &&
        step.ocrRegionRight > step.ocrRegionLeft &&
        step.ocrRegionBottom > step.ocrRegionTop;
    if (!hasRegion) {
      return '识别区域: 全屏';
    }
    return '识别区域: (${step.ocrRegionLeft}, ${step.ocrRegionTop})-'
        '(${step.ocrRegionRight}, ${step.ocrRegionBottom})';
  }

  String _buildImageDescriptor({
    required CustomFlowImageSource source,
    required String templateName,
    required String templatePath,
  }) {
    if (source == CustomFlowImageSource.localFile) {
      return templatePath.isEmpty ? '本地图片: 未选择' : '本地图片: $templatePath';
    }
    return templateName.isEmpty ? '内置图片: 未填写' : '内置图片: $templateName';
  }

  String _branchImageDisplayName(CustomFlowBranchImage image) {
    if (image.imageSource == CustomFlowImageSource.localFile) {
      return image.templatePath.trim().isNotEmpty
          ? p.basename(image.templatePath.trim())
          : '未选择';
    }
    return image.templateName.trim().isNotEmpty
        ? image.templateName.trim()
        : '未填写';
  }

  String _buildBranchImageDescriptor(CustomFlowBranchCase branchCase) {
    if (branchCase.recognitionMode == CustomFlowRecognitionMode.text) {
      final target = branchCase.ocrTargetText.trim().isEmpty
          ? '未填写'
          : branchCase.ocrTargetText.trim();
      return '目标文字: $target，${_ocrMatchModeLabel(branchCase.ocrMatchMode)}';
    }
    final images = branchCase.effectiveTemplateImages;
    if (images.isEmpty) {
      return '条件图片: 未配置';
    }
    if (images.length == 1) {
      final image = images.first;
      return _buildImageDescriptor(
        source: image.imageSource,
        templateName: image.templateName,
        templatePath: image.templatePath,
      );
    }
    final previewNames = images.take(3).map(_branchImageDisplayName).join('，');
    final suffix = images.length > 3 ? ' 等' : '';
    return '条件图片: ${images.length} 张（$previewNames$suffix）';
  }

  Widget _buildImagePreviewPlaceholder(IconData icon) {
    return Icon(icon, size: 32, color: Colors.blueGrey.shade300);
  }

  Widget _buildCustomFlowImagePreview({
    required CustomFlowImageSource source,
    required String templateName,
    required String templatePath,
  }) {
    Widget child;
    if (source == CustomFlowImageSource.asset) {
      final assetName = templateName.trim();
      if (assetName.isEmpty) {
        child = _buildImagePreviewPlaceholder(Icons.image_outlined);
      } else {
        child = Image.asset(
          'assets/images/$assetName',
          key: ValueKey('asset-preview-$assetName'),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) =>
              _buildImagePreviewPlaceholder(Icons.broken_image_outlined),
        );
      }
    } else {
      final path = templatePath.trim();
      if (path.isEmpty) {
        child = _buildImagePreviewPlaceholder(Icons.image_outlined);
      } else {
        try {
          final file = File(path);
          if (!file.existsSync()) {
            child = _buildImagePreviewPlaceholder(Icons.broken_image_outlined);
          } else {
            child = Image.memory(
              file.readAsBytesSync(),
              key: ValueKey(
                'local-preview-$path-${file.lastModifiedSync().millisecondsSinceEpoch}',
              ),
              fit: BoxFit.contain,
              gaplessPlayback: false,
              errorBuilder: (context, error, stackTrace) =>
                  _buildImagePreviewPlaceholder(Icons.broken_image_outlined),
            );
          }
        } catch (_) {
          child = _buildImagePreviewPlaceholder(Icons.broken_image_outlined);
        }
      }
    }

    return Container(
      width: 124,
      height: 96,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.blueGrey.shade100),
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade50,
      ),
      child: Center(child: SizedBox(width: 116, height: 88, child: child)),
    );
  }

  Widget _buildImagePickerWithPreview({
    required Widget controls,
    required CustomFlowImageSource source,
    required String templateName,
    required String templatePath,
  }) {
    final preview = _buildCustomFlowImagePreview(
      source: source,
      templateName: templateName,
      templatePath: templatePath,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite && constraints.maxWidth < 460) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [controls, const SizedBox(height: 12), preview],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: controls),
            const SizedBox(width: 12),
            preview,
          ],
        );
      },
    );
  }

  String _formatSeconds(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _secondsText(double value) => _formatSeconds(value);

  double _parseSeconds(String raw, {double fallback = 0}) {
    final value = double.tryParse(raw.trim());
    if (value == null || value.isNaN || value.isInfinite) {
      return fallback;
    }
    return value < 0 ? 0 : value;
  }

  Future<String> _customFlowMacShutdownPidFilePath() async {
    final tempDir = await getTemporaryDirectory();
    return p.join(tempDir.path, 'py_auto_custom_flow_shutdown.pid');
  }

  Future<List<String>> _customFlowMacShutdownPidFileCandidates() async {
    final result = <String>{await _customFlowMacShutdownPidFilePath()};
    final envTmpDir = Platform.environment['TMPDIR']?.trim();
    if (envTmpDir != null && envTmpDir.isNotEmpty) {
      result.add(p.join(envTmpDir, 'py_auto_custom_flow_shutdown.pid'));
    }
    result.add('/tmp/py_auto_custom_flow_shutdown.pid');
    return result.toList();
  }

  Future<String> _cancelCustomFlowShutdownTask() async {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      throw UnsupportedError('当前平台不支持桌面关机任务');
    }
    if (Platform.isWindows) {
      final result = await Process.run('shutdown', ['/a']);
      if (result.exitCode != 0) {
        final message = result.stderr.toString().trim().isEmpty
            ? result.stdout.toString().trim()
            : result.stderr.toString().trim();
        throw Exception(message.isEmpty ? '没有可取消的 Windows 关机任务' : message);
      }
      return '已取消当前 Windows 关机任务';
    }
    if (Platform.isMacOS) {
      final candidatePaths = await _customFlowMacShutdownPidFileCandidates();
      File? pidFile;
      for (final candidatePath in candidatePaths) {
        final file = File(candidatePath);
        if (await file.exists()) {
          pidFile = file;
          break;
        }
      }
      if (pidFile == null) {
        throw Exception('当前没有可取消的关机操作');
      }
      final pid = int.tryParse((await pidFile.readAsString()).trim());
      if (pid == null || pid <= 0) {
        if (await pidFile.exists()) {
          await pidFile.delete();
        }
        throw Exception('当前 macOS 关机任务信息无效，已清理');
      }
      final result = await Process.run('kill', ['-TERM', '--', '-$pid']);
      if (result.exitCode != 0) {
        final message = result.stderr.toString().trim().isEmpty
            ? result.stdout.toString().trim()
            : result.stderr.toString().trim();
        throw Exception(message.isEmpty ? '取消 macOS 关机任务失败' : message);
      }
      if (await pidFile.exists()) {
        await pidFile.delete();
      }
      return '已取消当前 macOS 关机任务';
    }
    throw UnsupportedError('当前仅支持 Windows 和 macOS 的桌面关机任务');
  }

  int _durationHoursPart(double seconds) =>
      Duration(seconds: seconds.floor()).inHours;

  int _durationMinutesPart(double seconds) =>
      Duration(seconds: seconds.floor()).inMinutes.remainder(60);

  String _durationSecondsPartText(double seconds) {
    final normalized = seconds < 0 ? 0 : seconds;
    final wholeSeconds = normalized.floor();
    final remainder = normalized - wholeSeconds;
    final secondsPart = wholeSeconds % 60;
    if (remainder == 0) {
      return secondsPart.toString();
    }
    return (secondsPart + remainder)
        .toStringAsFixed(3)
        .replaceFirst(RegExp(r'\.?0+$'), '');
  }

  double _parseDurationPartsToSeconds({
    required String hoursText,
    required String minutesText,
    required String secondsText,
    double fallback = 0,
  }) {
    final hours = int.tryParse(hoursText.trim()) ?? 0;
    final minutes = int.tryParse(minutesText.trim()) ?? 0;
    final seconds = _parseSeconds(secondsText, fallback: 0);
    final total =
        (max(hours, 0) * 3600) + (max(minutes, 0) * 60) + max(seconds, 0);
    return total.isNaN || total.isInfinite ? fallback : total.toDouble();
  }

  String _customFlowNumericPrefKey(String scope, String field) =>
      'customFlowNumeric.$scope.$field';

  double _getCustomFlowDoublePref(String scope, String field, double fallback) {
    if (!init) {
      return fallback;
    }
    final key = _customFlowNumericPrefKey(scope, field);
    final direct = _prefs.getDouble(key);
    if (direct != null) {
      return direct;
    }
    final legacyString = _prefs.getString(key);
    final parsed = legacyString == null ? null : double.tryParse(legacyString);
    return parsed ?? fallback;
  }

  int _getCustomFlowIntPref(String scope, String field, int fallback) {
    if (!init) {
      return fallback;
    }
    final key = _customFlowNumericPrefKey(scope, field);
    final direct = _prefs.getInt(key);
    if (direct != null) {
      return direct;
    }
    final legacyString = _prefs.getString(key);
    final parsed = legacyString == null ? null : int.tryParse(legacyString);
    return parsed ?? fallback;
  }

  void _setCustomFlowDoublePref(String scope, String field, double value) {
    if (!init) {
      return;
    }
    _prefs.setDouble(_customFlowNumericPrefKey(scope, field), value);
  }

  void _setCustomFlowIntPref(String scope, String field, int value) {
    if (!init) {
      return;
    }
    _prefs.setInt(_customFlowNumericPrefKey(scope, field), value);
  }

  double _defaultBranchCaseConfidence() =>
      _getCustomFlowDoublePref('branchCase', 'confidence', 0.68);

  CustomFlowStep _applyCachedNumericDefaultsToStep(CustomFlowStep step) {
    switch (step.type) {
      case CustomFlowStepType.wait:
        return step.copyWith(
          waitMinSeconds: _getCustomFlowDoublePref(
            'wait',
            'waitMinSeconds',
            step.waitMinSeconds,
          ),
          waitMaxSeconds: _getCustomFlowDoublePref(
            'wait',
            'waitMaxSeconds',
            step.waitMaxSeconds,
          ),
        );
      case CustomFlowStepType.imageTap:
        return step.copyWith(
          confidence: _getCustomFlowDoublePref(
            'imageTap',
            'confidence',
            step.confidence,
          ),
          maxAttempts: _getCustomFlowIntPref(
            'imageTap',
            'maxAttempts',
            step.maxAttempts,
          ),
          retryIntervalSeconds: _getCustomFlowDoublePref(
            'imageTap',
            'retryIntervalSeconds',
            step.retryIntervalSeconds,
          ),
          randomOffsetPx: _getCustomFlowIntPref(
            'imageTap',
            'randomOffsetPx',
            step.randomOffsetPx,
          ),
          postWaitMinSeconds: _getCustomFlowDoublePref(
            'imageTap',
            'postWaitMinSeconds',
            step.postWaitMinSeconds,
          ),
          postWaitMaxSeconds: _getCustomFlowDoublePref(
            'imageTap',
            'postWaitMaxSeconds',
            step.postWaitMaxSeconds,
          ),
        );
      case CustomFlowStepType.ocrTap:
        return step.copyWith(
          confidence: _getCustomFlowDoublePref(
            'ocrTap',
            'confidence',
            step.confidence,
          ),
          maxAttempts: _getCustomFlowIntPref(
            'ocrTap',
            'maxAttempts',
            step.maxAttempts,
          ),
          retryIntervalSeconds: _getCustomFlowDoublePref(
            'ocrTap',
            'retryIntervalSeconds',
            step.retryIntervalSeconds,
          ),
          ocrMatchIndex: _getCustomFlowIntPref(
            'ocrTap',
            'ocrMatchIndex',
            step.ocrMatchIndex,
          ),
          randomOffsetPx: _getCustomFlowIntPref(
            'ocrTap',
            'randomOffsetPx',
            step.randomOffsetPx,
          ),
          postWaitMinSeconds: _getCustomFlowDoublePref(
            'ocrTap',
            'postWaitMinSeconds',
            step.postWaitMinSeconds,
          ),
          postWaitMaxSeconds: _getCustomFlowDoublePref(
            'ocrTap',
            'postWaitMaxSeconds',
            step.postWaitMaxSeconds,
          ),
        );
      case CustomFlowStepType.coordinateTap:
        return step.copyWith(
          x: _getCustomFlowIntPref('coordinateTap', 'x', step.x),
          y: _getCustomFlowIntPref('coordinateTap', 'y', step.y),
          branchPositionOffsetX: _getCustomFlowIntPref(
            'coordinateTap',
            'branchPositionOffsetX',
            step.branchPositionOffsetX,
          ),
          branchPositionOffsetY: _getCustomFlowIntPref(
            'coordinateTap',
            'branchPositionOffsetY',
            step.branchPositionOffsetY,
          ),
          randomOffsetPx: _getCustomFlowIntPref(
            'coordinateTap',
            'randomOffsetPx',
            step.randomOffsetPx,
          ),
          postWaitMinSeconds: _getCustomFlowDoublePref(
            'coordinateTap',
            'postWaitMinSeconds',
            step.postWaitMinSeconds,
          ),
          postWaitMaxSeconds: _getCustomFlowDoublePref(
            'coordinateTap',
            'postWaitMaxSeconds',
            step.postWaitMaxSeconds,
          ),
        );
      case CustomFlowStepType.pasteText:
        return step;
      case CustomFlowStepType.waitImageState:
        return step.copyWith(
          confidence: _getCustomFlowDoublePref(
            'waitImageState',
            'confidence',
            step.confidence,
          ),
          timeoutSeconds: _getCustomFlowDoublePref(
            'waitImageState',
            'timeoutSeconds',
            step.timeoutSeconds,
          ),
          pollIntervalSeconds: _getCustomFlowDoublePref(
            'waitImageState',
            'pollIntervalSeconds',
            step.pollIntervalSeconds,
          ),
        );
      case CustomFlowStepType.imageBranch:
        return step;
      case CustomFlowStepType.imagePositionBranch:
        return step.copyWith(
          confidence: _getCustomFlowDoublePref(
            'imagePositionBranch',
            'confidence',
            step.confidence,
          ),
        );
      case CustomFlowStepType.loopBlock:
        return step.copyWith(
          loopCount: _getCustomFlowIntPref(
            'loopBlock',
            'loopCount',
            step.loopCount,
          ),
          confidence: _getCustomFlowDoublePref(
            'loopBlock',
            'confidence',
            step.confidence,
          ),
        );
      case CustomFlowStepType.flowGroup:
        return step;
      case CustomFlowStepType.gameMode:
        return step;
      case CustomFlowStepType.recordedFlow:
        return step;
      case CustomFlowStepType.restartActivity:
        return step;
      case CustomFlowStepType.shutdownComputer:
        return step.copyWith(
          shutdownDelaySeconds: _getCustomFlowDoublePref(
            'shutdownComputer',
            'shutdownDelaySeconds',
            step.shutdownDelaySeconds,
          ),
        );
    }
  }

  void _saveCustomFlowNumericDefaultsForStep(CustomFlowStep step) {
    switch (step.type) {
      case CustomFlowStepType.wait:
        _setCustomFlowDoublePref('wait', 'waitMinSeconds', step.waitMinSeconds);
        _setCustomFlowDoublePref('wait', 'waitMaxSeconds', step.waitMaxSeconds);
        return;
      case CustomFlowStepType.imageTap:
        _setCustomFlowDoublePref('imageTap', 'confidence', step.confidence);
        _setCustomFlowIntPref('imageTap', 'maxAttempts', step.maxAttempts);
        _setCustomFlowDoublePref(
          'imageTap',
          'retryIntervalSeconds',
          step.retryIntervalSeconds,
        );
        _setCustomFlowIntPref(
          'imageTap',
          'randomOffsetPx',
          step.randomOffsetPx,
        );
        _setCustomFlowDoublePref(
          'imageTap',
          'postWaitMinSeconds',
          step.postWaitMinSeconds,
        );
        _setCustomFlowDoublePref(
          'imageTap',
          'postWaitMaxSeconds',
          step.postWaitMaxSeconds,
        );
        return;
      case CustomFlowStepType.ocrTap:
        _setCustomFlowDoublePref('ocrTap', 'confidence', step.confidence);
        _setCustomFlowIntPref('ocrTap', 'maxAttempts', step.maxAttempts);
        _setCustomFlowDoublePref(
          'ocrTap',
          'retryIntervalSeconds',
          step.retryIntervalSeconds,
        );
        _setCustomFlowIntPref('ocrTap', 'ocrMatchIndex', step.ocrMatchIndex);
        _setCustomFlowIntPref('ocrTap', 'randomOffsetPx', step.randomOffsetPx);
        _setCustomFlowDoublePref(
          'ocrTap',
          'postWaitMinSeconds',
          step.postWaitMinSeconds,
        );
        _setCustomFlowDoublePref(
          'ocrTap',
          'postWaitMaxSeconds',
          step.postWaitMaxSeconds,
        );
        return;
      case CustomFlowStepType.coordinateTap:
        _setCustomFlowIntPref('coordinateTap', 'x', step.x);
        _setCustomFlowIntPref('coordinateTap', 'y', step.y);
        _setCustomFlowIntPref(
          'coordinateTap',
          'branchPositionOffsetX',
          step.branchPositionOffsetX,
        );
        _setCustomFlowIntPref(
          'coordinateTap',
          'branchPositionOffsetY',
          step.branchPositionOffsetY,
        );
        _setCustomFlowIntPref(
          'coordinateTap',
          'randomOffsetPx',
          step.randomOffsetPx,
        );
        _setCustomFlowDoublePref(
          'coordinateTap',
          'postWaitMinSeconds',
          step.postWaitMinSeconds,
        );
        _setCustomFlowDoublePref(
          'coordinateTap',
          'postWaitMaxSeconds',
          step.postWaitMaxSeconds,
        );
        return;
      case CustomFlowStepType.pasteText:
        return;
      case CustomFlowStepType.waitImageState:
        _setCustomFlowDoublePref(
          'waitImageState',
          'confidence',
          step.confidence,
        );
        _setCustomFlowDoublePref(
          'waitImageState',
          'timeoutSeconds',
          step.timeoutSeconds,
        );
        _setCustomFlowDoublePref(
          'waitImageState',
          'pollIntervalSeconds',
          step.pollIntervalSeconds,
        );
        return;
      case CustomFlowStepType.imageBranch:
        return;
      case CustomFlowStepType.imagePositionBranch:
        _setCustomFlowDoublePref(
          'imagePositionBranch',
          'confidence',
          step.confidence,
        );
        return;
      case CustomFlowStepType.loopBlock:
        _setCustomFlowIntPref('loopBlock', 'loopCount', step.loopCount);
        _setCustomFlowDoublePref('loopBlock', 'confidence', step.confidence);
        return;
      case CustomFlowStepType.flowGroup:
        return;
      case CustomFlowStepType.gameMode:
        return;
      case CustomFlowStepType.recordedFlow:
        return;
      case CustomFlowStepType.restartActivity:
        return;
      case CustomFlowStepType.shutdownComputer:
        _setCustomFlowDoublePref(
          'shutdownComputer',
          'shutdownDelaySeconds',
          step.shutdownDelaySeconds,
        );
        return;
    }
  }

  void _saveCustomFlowNumericDefaultsForBranchCase(CustomFlowBranchCase item) {
    _setCustomFlowDoublePref('branchCase', 'confidence', item.confidence);
  }

  void _rememberCustomFlowNumericDefaultsFromSteps(List<CustomFlowStep> steps) {
    for (final step in steps) {
      _saveCustomFlowNumericDefaultsForStep(step);
      for (final branchCase in step.branchCases) {
        _saveCustomFlowNumericDefaultsForBranchCase(branchCase);
        _rememberCustomFlowNumericDefaultsFromSteps(branchCase.steps);
      }
      _rememberCustomFlowNumericDefaultsFromSteps(step.children);
      _rememberCustomFlowNumericDefaultsFromSteps(step.fallbackChildren);
    }
  }

  String _buildStepTitle(CustomFlowStep step, int index) {
    final label = step.label.trim().isEmpty
        ? _stepTypeLabel(step.type)
        : step.label.trim();
    return '${index + 1}. $label';
  }

  String _buildPositionConditionSummary(CustomFlowBranchCase branchCase) {
    final parts = <String>[];
    if (branchCase.centerXMin != null) {
      parts.add('X>=${_formatSeconds(branchCase.centerXMin!)}');
    }
    if (branchCase.centerXMax != null) {
      parts.add('X<=${_formatSeconds(branchCase.centerXMax!)}');
    }
    if (branchCase.centerYMin != null) {
      parts.add('Y>=${_formatSeconds(branchCase.centerYMin!)}');
    }
    if (branchCase.centerYMax != null) {
      parts.add('Y<=${_formatSeconds(branchCase.centerYMax!)}');
    }
    if (parts.isEmpty) {
      return '无坐标限制';
    }
    return parts.join('，');
  }

  String _buildStepSubtitleDetails(CustomFlowStep step) {
    String branchScreenshotReuseSuffix() {
      return step.reuseParentBranchScreenshot ? '，复用上级截图' : '';
    }

    switch (step.type) {
      case CustomFlowStepType.wait:
        return '随机等待 ${_formatSeconds(step.waitMinSeconds)}-${_formatSeconds(step.waitMaxSeconds)} 秒';
      case CustomFlowStepType.imageTap:
        if (step.recognitionMode == CustomFlowRecognitionMode.text) {
          final target = step.ocrTargetText.trim().isEmpty
              ? '未填写'
              : step.ocrTargetText.trim();
          return '文字识别: $target，${_ocrMatchModeLabel(step.ocrMatchMode)}，'
              '${_buildOcrRegionDescriptor(step)}，阈值: ${step.confidence.toStringAsFixed(2)}，'
              '第 ${step.ocrMatchIndex <= 0 ? 1 : step.ocrMatchIndex} 个命中，'
              '点击偏移: (${step.ocrClickOffsetX}, ${step.ocrClickOffsetY})，'
              '随机偏移: ${step.randomOffsetPx}px，点击后等待: '
              '${_formatSeconds(step.postWaitMinSeconds)}-${_formatSeconds(step.postWaitMaxSeconds)} 秒';
        }
        return '${_buildImageDescriptor(source: step.imageSource, templateName: step.templateName, templatePath: step.templatePath)}，'
            '阈值: ${step.confidence.toStringAsFixed(2)}，重试: ${step.maxAttempts} 次，'
            '点击偏移: ${step.randomOffsetPx}px，点击后等待: ${_formatSeconds(step.postWaitMinSeconds)}-${_formatSeconds(step.postWaitMaxSeconds)} 秒';
      case CustomFlowStepType.ocrTap:
        final target = step.ocrTargetText.trim().isEmpty
            ? '未填写'
            : step.ocrTargetText.trim();
        return '目标文字: $target，${_ocrMatchModeLabel(step.ocrMatchMode)}，'
            '${_buildOcrRegionDescriptor(step)}，阈值: ${step.confidence.toStringAsFixed(2)}，'
            '第 ${step.ocrMatchIndex <= 0 ? 1 : step.ocrMatchIndex} 个命中，'
            '点击偏移: (${step.ocrClickOffsetX}, ${step.ocrClickOffsetY})，'
            '随机偏移: ${step.randomOffsetPx}px，点击后等待: '
            '${_formatSeconds(step.postWaitMinSeconds)}-${_formatSeconds(step.postWaitMaxSeconds)} 秒';
      case CustomFlowStepType.coordinateTap:
        if (step.useBranchDetectedPosition) {
          return '使用上层识图坐标分支命中的中心点，偏移 '
              '(${step.branchPositionOffsetX}, ${step.branchPositionOffsetY})，'
              '点击偏移: ${step.randomOffsetPx}px，点击后等待: '
              '${_formatSeconds(step.postWaitMinSeconds)}-${_formatSeconds(step.postWaitMaxSeconds)} 秒';
        }
        return '点击坐标 (${step.x}, ${step.y})，点击偏移: ${step.randomOffsetPx}px，'
            '点击后等待: ${_formatSeconds(step.postWaitMinSeconds)}-${_formatSeconds(step.postWaitMaxSeconds)} 秒';
      case CustomFlowStepType.pasteText:
        if (step.useParentLoopText) {
          return '清空输入框后，粘贴上层文本循环当前下发的文字';
        }
        final preview = step.textContent.replaceAll(RegExp(r'\s+'), ' ').trim();
        return preview.isEmpty
            ? '清空输入框，不输入文字'
            : '清空输入框后粘贴：${preview.length > 40 ? '${preview.substring(0, 40)}…' : preview}';
      case CustomFlowStepType.waitImageState:
        if (step.recognitionMode == CustomFlowRecognitionMode.text) {
          final target = step.ocrTargetText.trim().isEmpty
              ? '未填写'
              : step.ocrTargetText.trim();
          return '文字识别: $target，${_ocrMatchModeLabel(step.ocrMatchMode)}，'
              '等待直到${step.waitTargetState == CustomFlowWaitTargetState.appear ? '出现' : '消失'}，'
              '超时: ${_formatSeconds(step.timeoutSeconds)} 秒，轮询: ${_formatSeconds(step.pollIntervalSeconds)} 秒';
        }
        return '${_buildImageDescriptor(source: step.imageSource, templateName: step.templateName, templatePath: step.templatePath)}，'
            '等待直到${step.waitTargetState == CustomFlowWaitTargetState.appear ? '出现' : '消失'}，'
            '超时: ${_formatSeconds(step.timeoutSeconds)} 秒，轮询: ${_formatSeconds(step.pollIntervalSeconds)} 秒';
      case CustomFlowStepType.imageBranch:
        return '分支条件 ${step.branchCases.length} 个，默认分支 ${step.fallbackChildren.length} 步'
            '${branchScreenshotReuseSuffix()}';
      case CustomFlowStepType.imagePositionBranch:
        if (step.recognitionMode == CustomFlowRecognitionMode.text) {
          final target = step.ocrTargetText.trim().isEmpty
              ? '未填写'
              : step.ocrTargetText.trim();
          return '文字识别: $target，按命中文字中心坐标分支，条件 ${step.branchCases.length} 个，默认分支 ${step.fallbackChildren.length} 步'
              '${branchScreenshotReuseSuffix()}';
        }
        return '${_buildImageDescriptor(source: step.imageSource, templateName: step.templateName, templatePath: step.templatePath)}，'
            '按识图中心坐标分支，条件 ${step.branchCases.length} 个，默认分支 ${step.fallbackChildren.length} 步'
            '${branchScreenshotReuseSuffix()}';
      case CustomFlowStepType.loopBlock:
        if (step.loopMode == CustomFlowLoopMode.textLines) {
          return '按文本逐行循环 ${splitCustomFlowTextLines(step.loopTextContent).length} 次，'
              '子步骤 ${step.children.length} 个';
        }
        if (step.loopMode == CustomFlowLoopMode.imageCondition) {
          if (step.recognitionMode == CustomFlowRecognitionMode.text) {
            final target = step.ocrTargetText.trim().isEmpty
                ? '未填写'
                : step.ocrTargetText.trim();
            return '文字识别条件循环，${_loopImageActionLabel(step.loopImageAction, recognitionMode: step.recognitionMode)}，'
                '目标文字: $target，阈值: ${step.confidence.toStringAsFixed(2)}，子步骤 ${step.children.length} 个';
          }
          return '识图条件循环，${_loopImageActionLabel(step.loopImageAction, recognitionMode: step.recognitionMode)}，'
              '${_buildImageDescriptor(source: step.imageSource, templateName: step.templateName, templatePath: step.templatePath)}，'
              '阈值: ${step.confidence.toStringAsFixed(2)}，子步骤 ${step.children.length} 个';
        }
        return '循环 ${step.loopCount <= 0 ? '无限' : step.loopCount} 次，子步骤 ${step.children.length} 个';
      case CustomFlowStepType.flowGroup:
        return '作为一个整体执行，子步骤 ${step.children.length} 个';
      case CustomFlowStepType.gameMode:
        return '执行模式：${_gameModeLabel(step.gameModeName)}';
      case CustomFlowStepType.recordedFlow:
        return step.recordedFlowName.trim().isEmpty
            ? '未选择录制流程'
            : '回放录制流程：${step.recordedFlowName}，次数 ${step.recordedFlowLoopCount <= 0 ? '无限' : step.recordedFlowLoopCount}';
      case CustomFlowStepType.restartActivity:
        return step.activityComponent.trim().isEmpty
            ? '执行前自动读取当前前台 Activity，再执行 am start -W -S -n'
            : '重启指定 Activity: ${step.activityComponent.trim()}';
      case CustomFlowStepType.shutdownComputer:
        return '执行此步骤后 ${_formatSeconds(step.shutdownDelaySeconds)} 秒后关闭当前电脑';
    }
  }

  String _buildStepSubtitle(CustomFlowStep step) {
    return '${_deviceScopeLabel(step.deviceScope)}，${_buildStepSubtitleDetails(step)}';
  }

  List<CustomFlowStep> _buildLoopBlockExampleSteps(String templateName) {
    final appearTemplate = templateName.isEmpty ? 'pk_start.png' : templateName;
    return [
      CustomFlowStep(
        id: '${_newCustomFlowId()}_wait',
        type: CustomFlowStepType.wait,
        label: '示例1-等待',
        waitMinSeconds: 0.8,
        waitMaxSeconds: 1.2,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_tap',
        type: CustomFlowStepType.coordinateTap,
        label: '示例2-固定坐标点击',
        x: 800,
        y: 450,
        randomOffsetPx: 0,
        postWaitMinSeconds: 0.5,
        postWaitMaxSeconds: 0.8,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_wait_image',
        type: CustomFlowStepType.waitImageState,
        label: '示例3-等待图片出现',
        templateName: appearTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.68,
        waitTargetState: CustomFlowWaitTargetState.appear,
        timeoutSeconds: 15,
        pollIntervalSeconds: 1,
        continueOnFailure: true,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_image_tap',
        type: CustomFlowStepType.imageTap,
        label: '示例4-识图点击',
        templateName: appearTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.68,
        maxAttempts: 3,
        retryIntervalSeconds: 1,
        randomOffsetPx: 10,
        postWaitMinSeconds: 0.8,
        postWaitMaxSeconds: 1.2,
        continueOnFailure: true,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_branch',
        type: CustomFlowStepType.imageBranch,
        label: '示例5-多图条件分支',
        branchCases: [
          CustomFlowBranchCase(
            id: '${_newCustomFlowId()}_branch_case1',
            label: '分支A-命中图片后点左上',
            templateName: appearTemplate,
            imageSource: CustomFlowImageSource.localFile,
            confidence: 0.68,
            steps: [
              CustomFlowStep(
                id: '${_newCustomFlowId()}_branch_case1_tap',
                type: CustomFlowStepType.coordinateTap,
                label: '分支A点击',
                x: 300,
                y: 220,
                randomOffsetPx: 0,
                postWaitMinSeconds: 0.4,
                postWaitMaxSeconds: 0.7,
              ),
            ],
          ),
        ],
        fallbackChildren: [
          CustomFlowStep(
            id: '${_newCustomFlowId()}_branch_fallback_wait',
            type: CustomFlowStepType.wait,
            label: '默认分支-等待',
            waitMinSeconds: 0.6,
            waitMaxSeconds: 0.9,
          ),
        ],
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_nested_loop',
        type: CustomFlowStepType.loopBlock,
        label: '示例6-内层循环2次',
        loopCount: 2,
        children: [
          CustomFlowStep(
            id: '${_newCustomFlowId()}_nested_wait',
            type: CustomFlowStepType.wait,
            label: '内层等待',
            waitMinSeconds: 0.3,
            waitMaxSeconds: 0.5,
          ),
          CustomFlowStep(
            id: '${_newCustomFlowId()}_nested_tap',
            type: CustomFlowStepType.coordinateTap,
            label: '内层固定点击',
            x: 1000,
            y: 520,
            randomOffsetPx: 0,
            postWaitMinSeconds: 0.3,
            postWaitMaxSeconds: 0.5,
          ),
        ],
      ),
    ];
  }

  List<CustomFlowStep> _buildSimpleLoopTemplateSteps() {
    return [
      CustomFlowStep(
        id: '${_newCustomFlowId()}_simple_wait',
        type: CustomFlowStepType.wait,
        label: '等待1秒',
        waitMinSeconds: 1,
        waitMaxSeconds: 1,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_simple_tap',
        type: CustomFlowStepType.coordinateTap,
        label: '固定点击',
        x: 800,
        y: 450,
        randomOffsetPx: 0,
        postWaitMinSeconds: 0.5,
        postWaitMaxSeconds: 0.8,
      ),
    ];
  }

  List<CustomFlowStep> _buildFarmLoopTemplateSteps(String templateName) {
    final safeTemplate = templateName.isEmpty
        ? _safeDefaultTemplateName()
        : templateName;
    return [
      CustomFlowStep(
        id: '${_newCustomFlowId()}_farm_wait_start',
        type: CustomFlowStepType.waitImageState,
        label: '等待开始按钮出现',
        templateName: safeTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.68,
        waitTargetState: CustomFlowWaitTargetState.appear,
        timeoutSeconds: 20,
        pollIntervalSeconds: 1,
        continueOnFailure: false,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_farm_click_start',
        type: CustomFlowStepType.imageTap,
        label: '点击开始',
        templateName: safeTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.68,
        maxAttempts: 3,
        retryIntervalSeconds: 1,
        randomOffsetPx: 8,
        postWaitMinSeconds: 1.2,
        postWaitMaxSeconds: 1.8,
        continueOnFailure: false,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_farm_wait_battle',
        type: CustomFlowStepType.wait,
        label: '等待战斗结束',
        waitMinSeconds: 15,
        waitMaxSeconds: 18,
      ),
    ];
  }

  List<CustomFlowStep> _buildWaitThenClickTemplateSteps(String templateName) {
    final safeTemplate = templateName.isEmpty
        ? _safeDefaultTemplateName()
        : templateName;
    return [
      CustomFlowStep(
        id: '${_newCustomFlowId()}_wait_click_wait',
        type: CustomFlowStepType.waitImageState,
        label: '等待目标图片出现',
        templateName: safeTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.68,
        waitTargetState: CustomFlowWaitTargetState.appear,
        timeoutSeconds: 15,
        pollIntervalSeconds: 1,
        continueOnFailure: false,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_wait_click_tap',
        type: CustomFlowStepType.imageTap,
        label: '出现后点击图片',
        templateName: safeTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.68,
        maxAttempts: 2,
        retryIntervalSeconds: 0.8,
        randomOffsetPx: 10,
        postWaitMinSeconds: 0.6,
        postWaitMaxSeconds: 1,
        continueOnFailure: false,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_wait_click_disappear',
        type: CustomFlowStepType.waitImageState,
        label: '等待目标图片消失',
        templateName: safeTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.68,
        waitTargetState: CustomFlowWaitTargetState.disappear,
        timeoutSeconds: 10,
        pollIntervalSeconds: 0.8,
        continueOnFailure: true,
      ),
    ];
  }

  List<CustomFlowStep> _buildBranchLoopTemplateSteps(String templateName) {
    final safeTemplate = templateName.isEmpty
        ? _safeDefaultTemplateName()
        : templateName;
    return [
      CustomFlowStep(
        id: '${_newCustomFlowId()}_branch_entry_wait',
        type: CustomFlowStepType.wait,
        label: '进入分支前等待',
        waitMinSeconds: 0.8,
        waitMaxSeconds: 1.2,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_branch_entry',
        type: CustomFlowStepType.imageBranch,
        label: '按图片分支执行',
        branchCases: [
          CustomFlowBranchCase(
            id: '${_newCustomFlowId()}_branch_a',
            label: '分支A',
            templateName: safeTemplate,
            imageSource: CustomFlowImageSource.localFile,
            confidence: 0.68,
            steps: [
              CustomFlowStep(
                id: '${_newCustomFlowId()}_branch_a_tap',
                type: CustomFlowStepType.coordinateTap,
                label: '分支A点击左侧',
                x: 360,
                y: 360,
                randomOffsetPx: 0,
                postWaitMinSeconds: 0.4,
                postWaitMaxSeconds: 0.7,
              ),
            ],
          ),
        ],
        fallbackChildren: [
          CustomFlowStep(
            id: '${_newCustomFlowId()}_branch_fallback',
            type: CustomFlowStepType.coordinateTap,
            label: '默认分支点击右侧',
            x: 1100,
            y: 360,
            randomOffsetPx: 0,
            postWaitMinSeconds: 0.4,
            postWaitMaxSeconds: 0.7,
          ),
        ],
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_branch_nested_loop',
        type: CustomFlowStepType.loopBlock,
        label: '分支后补偿循环',
        loopCount: 2,
        children: [
          CustomFlowStep(
            id: '${_newCustomFlowId()}_branch_nested_wait',
            type: CustomFlowStepType.wait,
            label: '补偿等待',
            waitMinSeconds: 0.3,
            waitMaxSeconds: 0.5,
          ),
          CustomFlowStep(
            id: '${_newCustomFlowId()}_branch_nested_tap',
            type: CustomFlowStepType.coordinateTap,
            label: '补偿点击',
            x: 900,
            y: 540,
            randomOffsetPx: 0,
            postWaitMinSeconds: 0.3,
            postWaitMaxSeconds: 0.5,
          ),
        ],
      ),
    ];
  }

  List<CustomFlowBranchCase> _buildImageBranchExampleCases(
    String templateName,
  ) {
    final safeTemplate = templateName.isEmpty
        ? _safeDefaultTemplateName()
        : templateName;
    return [
      CustomFlowBranchCase(
        id: '${_newCustomFlowId()}_branch_case_a',
        label: '分支A-命中图片后点击',
        templateName: safeTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.68,
        steps: [
          CustomFlowStep(
            id: '${_newCustomFlowId()}_branch_case_a_wait',
            type: CustomFlowStepType.wait,
            label: '分支A-短等待',
            waitMinSeconds: 0.5,
            waitMaxSeconds: 0.9,
          ),
          CustomFlowStep(
            id: '${_newCustomFlowId()}_branch_case_a_tap',
            type: CustomFlowStepType.coordinateTap,
            label: '分支A-点击左上',
            x: 360,
            y: 240,
            randomOffsetPx: 0,
            postWaitMinSeconds: 0.4,
            postWaitMaxSeconds: 0.7,
          ),
        ],
      ),
      CustomFlowBranchCase(
        id: '${_newCustomFlowId()}_branch_case_b',
        label: '分支B-命中图片后等待消失',
        templateName: safeTemplate,
        imageSource: CustomFlowImageSource.localFile,
        confidence: 0.72,
        steps: [
          CustomFlowStep(
            id: '${_newCustomFlowId()}_branch_case_b_wait_disappear',
            type: CustomFlowStepType.waitImageState,
            label: '分支B-等待图片消失',
            templateName: safeTemplate,
            imageSource: CustomFlowImageSource.localFile,
            confidence: 0.68,
            waitTargetState: CustomFlowWaitTargetState.disappear,
            timeoutSeconds: 8,
            pollIntervalSeconds: 0.8,
            continueOnFailure: true,
          ),
        ],
      ),
    ];
  }

  List<CustomFlowBranchCase> _buildImagePositionBranchExampleCases() {
    return [
      CustomFlowBranchCase(
        id: '${_newCustomFlowId()}_position_branch_a',
        label: '右下区域',
        centerXMin: 800,
        centerYMin: 700,
        steps: [
          CustomFlowStep(
            id: '${_newCustomFlowId()}_position_branch_a_tap',
            type: CustomFlowStepType.coordinateTap,
            label: '命中右下后点击识图中心附近',
            useBranchDetectedPosition: true,
            branchPositionOffsetX: 20,
            branchPositionOffsetY: 10,
            randomOffsetPx: 0,
            postWaitMinSeconds: 0.4,
            postWaitMaxSeconds: 0.7,
          ),
        ],
      ),
      CustomFlowBranchCase(
        id: '${_newCustomFlowId()}_position_branch_b',
        label: '左半区域',
        centerXMax: 799,
        steps: [
          CustomFlowStep(
            id: '${_newCustomFlowId()}_position_branch_b_wait',
            type: CustomFlowStepType.wait,
            label: '命中左半后等待',
            waitMinSeconds: 0.5,
            waitMaxSeconds: 0.8,
          ),
        ],
      ),
    ];
  }

  List<CustomFlowStep> _buildImagePositionBranchFallbackSteps() {
    return [
      CustomFlowStep(
        id: '${_newCustomFlowId()}_position_branch_fallback_tap',
        type: CustomFlowStepType.coordinateTap,
        label: '默认分支点击B',
        x: 500,
        y: 500,
        randomOffsetPx: 0,
        postWaitMinSeconds: 0.4,
        postWaitMaxSeconds: 0.7,
      ),
    ];
  }

  List<CustomFlowStep> _buildImageBranchFallbackSteps() {
    return [
      CustomFlowStep(
        id: '${_newCustomFlowId()}_branch_fallback_wait',
        type: CustomFlowStepType.wait,
        label: '默认分支-等待',
        waitMinSeconds: 0.8,
        waitMaxSeconds: 1.2,
      ),
      CustomFlowStep(
        id: '${_newCustomFlowId()}_branch_fallback_tap',
        type: CustomFlowStepType.coordinateTap,
        label: '默认分支-点击右侧',
        x: 1080,
        y: 360,
        randomOffsetPx: 0,
        postWaitMinSeconds: 0.4,
        postWaitMaxSeconds: 0.7,
      ),
    ];
  }

  List<CustomFlowStep> _buildLoopTemplateStepsByKey(
    String templateKey,
    String templateName,
  ) {
    switch (templateKey) {
      case 'simple':
        return _buildSimpleLoopTemplateSteps();
      case 'farm':
        return _buildFarmLoopTemplateSteps(templateName);
      case 'wait_then_click':
        return _buildWaitThenClickTemplateSteps(templateName);
      case 'branch_loop':
        return _buildBranchLoopTemplateSteps(templateName);
      default:
        return _buildLoopBlockExampleSteps(templateName);
    }
  }

  String _buildLoopBlockUserGuide() {
    return [
      '循环块使用说明：',
      '1. 循环次数表示执行对应轮数，填写 0 表示无限循环。',
      '2. 也可以切换成识图条件模式。每轮子步骤执行完后检查一次图片或文字，按你的设置决定继续还是停止。',
      '3. 识图条件模式支持图片识别和文字识别；文字识别可设置为识别到文字继续循环，或识别到文字停止循环。',
      '4. 按文本逐行模式会按换行拆分文字，每行去除首尾空格并忽略空行；每个有效行执行一轮。',
      '5. 文本循环会把当前行下发给子步骤，子步骤中的“粘贴文字”可直接读取。',
      '6. 你可以直接修改默认示例中的数值，例如把坐标、等待时间、模板图片名改成自己的。',
      '7. 可以在编辑器里切换模板，并一键覆盖当前子步骤。',
    ].join('\n');
  }

  String _buildImageBranchUserGuide() {
    return [
      '多图条件分支使用说明：识别到A图走A内部的流程，识别到B图走B内部的流程，都没识别到，走else里的流程',
      '1. 默认示例的大致意思是：',
      '   识别到分支A命中的图片后，先短等待再点击一个固定坐标；这时条件判断结束',
      '   假如分支A未命中，接着判断分支B命中图片后，等待这个图片消失；',
      '   如果两个分支都没命中，就走默认分支做一次等待加固定点击。',
      '2. 你通常只需要改图片名、坐标、等待时间和阈值，就可以把示例改成自己的流程。',
      '3. 如果有多个相似图片，建议把更明确、更优先的条件放在前面。',
    ].join('\n');
  }

  String _buildImagePositionBranchUserGuide() {
    return [
      '识图坐标分支使用说明：先识别一张目标图片，再根据识别结果中心点坐标决定走哪个分支。',
      '1. 步骤顶部只配置一张图片和阈值，运行时只识别这一次。',
      '2. 每个 IF / ELSE IF 分支里填写中心点坐标条件，比如 X 最小值 800、Y 最小值 700。',
      '3. 一个分支里的多个条件会同时生效，等价于 “x >= 800 且 y >= 700”。',
      '4. 分支命中后，识别到的中心点会下发给该分支子步骤；子步骤里的“固定坐标点击”可以直接引用这组坐标。',
      '5. 留空表示这一项不限制。所有分支都不命中时，会走 ELSE 默认分支。',
    ].join('\n');
  }

  CustomFlowStep _createDefaultStep(CustomFlowStepType type) {
    final templateName = _availableTemplateNames.isNotEmpty
        ? _availableTemplateNames.first
        : '';
    late final CustomFlowStep step;
    switch (type) {
      case CustomFlowStepType.wait:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '等待',
          waitMinSeconds: 0.8,
          waitMaxSeconds: 1.2,
        );
      case CustomFlowStepType.imageTap:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '识图点击',
          templateName: templateName,
          imageSource: CustomFlowImageSource.localFile,
          confidence: 0.68,
          maxAttempts: 3,
          retryIntervalSeconds: 1.2,
          randomOffsetPx: 1,
          postWaitMinSeconds: 0.8,
          postWaitMaxSeconds: 1.5,
        );
      case CustomFlowStepType.ocrTap:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '识图点击（文字识别）',
          ocrTargetText: '',
          ocrMatchMode: CustomFlowOcrMatchMode.contains,
          ocrRegionLeft: -1,
          ocrRegionTop: -1,
          ocrRegionRight: -1,
          ocrRegionBottom: -1,
          ocrMatchIndex: 1,
          ocrClickOffsetX: 0,
          ocrClickOffsetY: 0,
          confidence: 0.50,
          maxAttempts: 3,
          retryIntervalSeconds: 1.2,
          randomOffsetPx: 1,
          postWaitMinSeconds: 0.8,
          postWaitMaxSeconds: 1.5,
        );
      case CustomFlowStepType.coordinateTap:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '固定坐标点击',
          x: 800,
          y: 450,
          randomOffsetPx: 5,
          postWaitMinSeconds: 0.8,
          postWaitMaxSeconds: 1.2,
        );
      case CustomFlowStepType.pasteText:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '粘贴文字',
          textContent: '',
          useParentLoopText: false,
        );
      case CustomFlowStepType.waitImageState:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '识图等待',
          templateName: templateName,
          imageSource: CustomFlowImageSource.localFile,
          confidence: 0.68,
          waitTargetState: CustomFlowWaitTargetState.appear,
          timeoutSeconds: 30,
          pollIntervalSeconds: 1.2,
        );
      case CustomFlowStepType.imageBranch:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '多图条件分支',
          branchCases: _buildImageBranchExampleCases(templateName),
          fallbackChildren: _buildImageBranchFallbackSteps(),
        );
      case CustomFlowStepType.imagePositionBranch:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '识图坐标分支',
          templateName: templateName,
          imageSource: CustomFlowImageSource.localFile,
          confidence: 0.68,
          branchCases: _buildImagePositionBranchExampleCases(),
          fallbackChildren: _buildImagePositionBranchFallbackSteps(),
        );
      case CustomFlowStepType.loopBlock:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '循环块',
          loopCount: 1,
          loopMode: CustomFlowLoopMode.fixedCount,
          loopImageAction: CustomFlowLoopImageAction.stopOnMatch,
          templateName: templateName,
          imageSource: CustomFlowImageSource.localFile,
          confidence: 0.68,
          children: _buildLoopBlockExampleSteps(templateName),
        );
      case CustomFlowStepType.flowGroup:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '流程组',
          children: const [],
        );
      case CustomFlowStepType.gameMode:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '执行寮突破模式',
          gameModeName: 'liao_tupo',
          gameModeConfigJson: jsonEncode(
            _buildCurrentGameModeConfigSnapshot('liao_tupo'),
          ),
          gameModeDeviceIds: const [],
        );
      case CustomFlowStepType.recordedFlow:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '执行录制流程',
          recordedFlowName: _selectedFlowName,
          recordedFlowLoopCount: 1,
        );
      case CustomFlowStepType.restartActivity:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '重启当前Activity',
          activityComponent: '',
        );
      case CustomFlowStepType.shutdownComputer:
        step = CustomFlowStep(
          id: _newCustomFlowId(),
          type: type,
          label: '关机操作',
          shutdownDelaySeconds: 60,
        );
    }
    return _applyCachedNumericDefaultsToStep(step);
  }

  String _suggestSelectedCustomFlowName() {
    final baseName = _customFlowNameController.text.trim().isEmpty
        ? 'custom_flow'
        : _customFlowNameController.text.trim();
    return '${_customFlowStorageService.sanitizeFlowName(baseName)}_selection';
  }

  Future<String?> _showSaveSelectedCustomFlowNameDialog({
    required String suggestedName,
  }) async {
    final controller = TextEditingController(text: suggestedName);
    String? errorText;
    try {
      return await showAdaptiveDialog<String>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setLocalState) {
              return AlertDialog(
                title: const Text('保存选中节点为流程'),
                content: SizedBox(
                  width: 420,
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: '流程名称',
                      errorText: errorText,
                    ),
                    onChanged: (_) {
                      if (errorText == null) {
                        return;
                      }
                      setLocalState(() {
                        errorText = null;
                      });
                    },
                    onSubmitted: (_) {
                      final value = controller.text.trim();
                      if (value.isEmpty) {
                        setLocalState(() {
                          errorText = '请先填写流程名称。';
                        });
                        return;
                      }
                      Navigator.of(context).pop(value);
                    },
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(
                      '取消',
                      style: TextStyle(color: Colors.blue),
                    ),
                  ),
                  FilledButton(
                    onPressed: () {
                      final value = controller.text.trim();
                      if (value.isEmpty) {
                        setLocalState(() {
                          errorText = '请先填写流程名称。';
                        });
                        return;
                      }
                      Navigator.of(context).pop(value);
                    },
                    child: const Text('确认'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  Future<bool> _confirmOverwriteCustomFlow(String flowName) async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('覆盖同名流程'),
        content: Text('已存在名为“$flowName”的自定义流程，确认覆盖吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.blue)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _saveSelectedCustomFlowStepsAsFlow(
    List<CustomFlowStep> sourceSteps,
    Set<String> selectedStepIds,
  ) async {
    final selectedSteps = _cloneSelectedStepsForNewFlow(
      sourceSteps,
      selectedStepIds,
    );
    if (selectedSteps.isEmpty) {
      setState(() {
        _output += '请先选择至少一个节点，再保存为单独流程。\n';
        _scrollToBottom();
      });
      return;
    }

    final flowName = await _showSaveSelectedCustomFlowNameDialog(
      suggestedName: _suggestSelectedCustomFlowName(),
    );
    if (flowName == null) {
      return;
    }

    final sanitizedName = _customFlowStorageService.sanitizeFlowName(flowName);
    final existing = await _customFlowStorageService.loadFlow(sanitizedName);
    if (existing != null) {
      final overwrite = await _confirmOverwriteCustomFlow(sanitizedName);
      if (!overwrite) {
        return;
      }
    }

    final now = DateTime.now();
    final flow = CustomFlowDefinition(
      name: sanitizedName,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      steps: selectedSteps,
    );
    _rememberCustomFlowNumericDefaultsFromSteps(flow.steps);
    final filePath = await _customFlowStorageService.saveFlow(flow);
    await _reloadSavedCustomFlows();
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedCustomFlowName = sanitizedName;
      _savePreferences();
      _output += '已将 ${selectedSteps.length} 个选中节点保存为自定义流程：$sanitizedName\n';
      _output += '保存路径：$filePath\n';
      _scrollToBottom();
    });
  }

  Future<void> _saveCurrentCustomFlow() async {
    final flowName = _customFlowNameController.text.trim();
    if (flowName.isEmpty) {
      setState(() {
        _output += '请先填写自定义流程名称。\n';
        _scrollToBottom();
      });
      return;
    }
    if (_customFlowSteps.isEmpty) {
      setState(() {
        _output += '请先添加至少一个步骤，再保存自定义流程。\n';
        _scrollToBottom();
      });
      return;
    }

    final sanitizedName = _customFlowStorageService.sanitizeFlowName(flowName);
    final existing = await _customFlowStorageService.loadFlow(sanitizedName);
    final now = DateTime.now();
    final flow = CustomFlowDefinition(
      name: sanitizedName,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      steps: List<CustomFlowStep>.from(_customFlowSteps),
    );
    _rememberCustomFlowNumericDefaultsFromSteps(flow.steps);
    final filePath = await _customFlowStorageService.saveFlow(flow);
    final savedFlow = await _customFlowStorageService.loadFlow(sanitizedName);
    await _reloadSavedCustomFlows();
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedCustomFlowName = sanitizedName;
      _customFlowNameController.text = sanitizedName;
      if (savedFlow != null) {
        _customFlowSteps = List<CustomFlowStep>.from(savedFlow.steps);
      }
      _selectedCustomFlowStepIds = <String>{};
      _savePreferences();
      _output += '已保存自定义流程：$sanitizedName\n';
      _output += '保存路径：$filePath\n';
      _scrollToBottom();
    });
  }

  Future<void> _exportCurrentCustomFlow() async {
    final flowName = _customFlowNameController.text.trim();
    if (flowName.isEmpty) {
      setState(() {
        _output += '请先填写自定义流程名称，再导出流程。\n';
        _scrollToBottom();
      });
      return;
    }
    if (_customFlowSteps.isEmpty) {
      setState(() {
        _output += '请先添加至少一个自定义流程步骤，再导出流程。\n';
        _scrollToBottom();
      });
      return;
    }

    final sanitizedName = _customFlowStorageService.sanitizeFlowName(flowName);
    final location = await getSaveLocation(
      suggestedName:
          '$sanitizedName.${CustomFlowStorageService.exportFileExtension}',
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'custom flow package',
          extensions: [CustomFlowStorageService.exportFileExtension],
        ),
      ],
    );
    if (location == null) {
      return;
    }

    try {
      final now = DateTime.now();
      final payloadFlow = CustomFlowDefinition(
        name: sanitizedName,
        createdAt: now,
        updatedAt: now,
        steps: List<CustomFlowStep>.from(_customFlowSteps),
      );
      await _customFlowStorageService.exportFlowPackage(
        flow: payloadFlow,
        exportPath: location.path,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '已导出自定义流程：$sanitizedName\n';
        _output += '导出文件：${location.path}\n';
        _scrollToBottom();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '导出自定义流程失败：$e\n';
        _scrollToBottom();
      });
    }
  }

  Future<void> _importCustomFlow() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'custom flow package',
          extensions: [CustomFlowStorageService.exportFileExtension, 'json'],
        ),
      ],
    );
    if (file == null) {
      return;
    }
    try {
      final importResult = await _customFlowStorageService.importFlowPackage(
        file.path,
      );
      final importedFlow = importResult.flow;
      await _reloadSavedFlows();
      await _reloadSavedCustomFlows();
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedCustomFlowName = importedFlow.name;
        _customFlowNameController.text = importedFlow.name;
        _customFlowSteps = List<CustomFlowStep>.from(importedFlow.steps);
        _selectedCustomFlowStepIds = <String>{};
        _savePreferences();
        _output += '已导入自定义流程：${importedFlow.name}\n';
        if (importResult.importedRecordedFlowNames.isNotEmpty) {
          _output +=
              '已导入关联录制流程：${importResult.importedRecordedFlowNames.join(', ')}\n';
        }
        for (final entry in importResult.recordedFlowNameMap.entries) {
          if (entry.key != entry.value) {
            _output += '录制流程重名，已自动改名：${entry.key} -> ${entry.value}\n';
          }
        }
        _output += '导入来源：${file.path}\n';
        _scrollToBottom();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '导入自定义流程失败：$e\n';
        _scrollToBottom();
      });
    }
  }

  Future<void> _loadSelectedCustomFlow() async {
    if (_selectedCustomFlowName.isEmpty) {
      setState(() {
        _output += '请先选择一个已保存的自定义流程。\n';
        _scrollToBottom();
      });
      return;
    }
    final flow = await _customFlowStorageService.loadFlow(
      _selectedCustomFlowName,
    );
    if (flow == null) {
      setState(() {
        _output += '未找到自定义流程：$_selectedCustomFlowName\n';
        _scrollToBottom();
      });
      return;
    }
    setState(() {
      _customFlowNameController.text = flow.name;
      _customFlowSteps = List<CustomFlowStep>.from(flow.steps);
      _selectedCustomFlowStepIds = <String>{};
      _output += '已加载自定义流程：${flow.name}，步骤数：${flow.steps.length}\n';
      _scrollToBottom();
    });
  }

  Future<void> _appendSelectedCustomFlowToCurrent() async {
    if (_selectedCustomFlowName.isEmpty) {
      setState(() {
        _output += '请先选择一个已保存的自定义流程，再追加到当前流程。\n';
        _scrollToBottom();
      });
      return;
    }
    final appendResult = await _buildSavedCustomFlowGroupForAppend(
      _selectedCustomFlowName,
      emptySelectionMessage: '请先选择一个已保存的自定义流程，再追加到当前流程。',
      onError: (message) {
        if (!mounted) {
          return;
        }
        setState(() {
          _output += '$message\n';
          _scrollToBottom();
        });
      },
    );
    if (appendResult == null || !mounted) {
      return;
    }

    setState(() {
      _customFlowSteps = [..._customFlowSteps, appendResult.group];
      _selectedCustomFlowStepIds = <String>{appendResult.group.id};
      _output +=
          '已将自定义流程“${appendResult.flow.name}”作为流程组追加到当前流程末尾，组内 ${appendResult.group.children.length} 个步骤。\n';
      _scrollToBottom();
    });
  }

  Future<void> _deleteSelectedCustomFlow() async {
    if (_selectedCustomFlowName.isEmpty) {
      setState(() {
        _output += '请先选择要删除的自定义流程。\n';
        _scrollToBottom();
      });
      return;
    }
    final flowName = _selectedCustomFlowName;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除自定义流程'),
        content: Text('确认删除自定义流程“$flowName”吗？删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.blue)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final deleted = await _customFlowStorageService.deleteFlow(flowName);
    await _reloadSavedCustomFlows();
    if (!mounted) {
      return;
    }
    setState(() {
      if (deleted) {
        if (_customFlowNameController.text.trim() == flowName) {
          _customFlowNameController.text = 'custom_flow';
          _customFlowSteps = [];
          _selectedCustomFlowStepIds = <String>{};
        }
        _output += '已删除自定义流程：$flowName\n';
      } else {
        _output += '删除失败：未找到自定义流程 $flowName\n';
      }
      _scrollToBottom();
    });
  }

  Future<bool> _confirmClearStepList({
    required String title,
    required String content,
  }) async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.blue)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  List<CustomFlowStep> _replaceStepInList(
    List<CustomFlowStep> steps,
    int index,
    CustomFlowStep updated,
  ) {
    final result = List<CustomFlowStep>.from(steps);
    result[index] = updated;
    return result;
  }

  List<CustomFlowStep> _removeStepFromList(
    List<CustomFlowStep> steps,
    int index,
  ) {
    final result = List<CustomFlowStep>.from(steps);
    result.removeAt(index);
    return result;
  }

  List<CustomFlowStep> _moveStepInList(
    List<CustomFlowStep> steps,
    int index,
    int offset,
  ) {
    final target = index + offset;
    if (target < 0 || target >= steps.length) {
      return steps;
    }
    final result = List<CustomFlowStep>.from(steps);
    final item = result.removeAt(index);
    result.insert(target, item);
    return result;
  }

  List<T> _reorderItems<T>(List<T> items, int oldIndex, int newIndex) {
    final result = List<T>.from(items);
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final item = result.removeAt(oldIndex);
    result.insert(newIndex, item);
    return result;
  }

  List<T> _moveItemInList<T>(List<T> items, int index, int offset) {
    final target = index + offset;
    if (target < 0 || target >= items.length) {
      return items;
    }
    final result = List<T>.from(items);
    final item = result.removeAt(index);
    result.insert(target, item);
    return result;
  }

  Future<CustomFlowBranchCase?> _showBranchCaseEditor({
    required CustomFlowBranchCase initialCase,
    bool usePositionCondition = false,
  }) async {
    final labelController = TextEditingController(text: initialCase.label);
    final confidenceController = TextEditingController(
      text: initialCase.confidence.toString(),
    );
    final templatePathController = TextEditingController(
      text: initialCase.templatePath,
    );
    final ocrTargetTextController = TextEditingController(
      text: initialCase.ocrTargetText,
    );
    final ocrRegionLeftController = TextEditingController(
      text: initialCase.ocrRegionLeft >= 0
          ? initialCase.ocrRegionLeft.toString()
          : '',
    );
    final ocrRegionTopController = TextEditingController(
      text: initialCase.ocrRegionTop >= 0
          ? initialCase.ocrRegionTop.toString()
          : '',
    );
    final ocrRegionRightController = TextEditingController(
      text: initialCase.ocrRegionRight >= 0
          ? initialCase.ocrRegionRight.toString()
          : '',
    );
    final ocrRegionBottomController = TextEditingController(
      text: initialCase.ocrRegionBottom >= 0
          ? initialCase.ocrRegionBottom.toString()
          : '',
    );
    final centerXMinController = TextEditingController(
      text: initialCase.centerXMin == null
          ? ''
          : _secondsText(initialCase.centerXMin!),
    );
    final centerXMaxController = TextEditingController(
      text: initialCase.centerXMax == null
          ? ''
          : _secondsText(initialCase.centerXMax!),
    );
    final centerYMinController = TextEditingController(
      text: initialCase.centerYMin == null
          ? ''
          : _secondsText(initialCase.centerYMin!),
    );
    final centerYMaxController = TextEditingController(
      text: initialCase.centerYMax == null
          ? ''
          : _secondsText(initialCase.centerYMax!),
    );
    String selectedTemplate = initialCase.templateName;
    String selectedTemplatePath = initialCase.templatePath;
    CustomFlowImageSource selectedImageSource = initialCase.imageSource;
    CustomFlowRecognitionMode selectedRecognitionMode =
        initialCase.recognitionMode;
    CustomFlowOcrMatchMode selectedOcrMatchMode = initialCase.ocrMatchMode;
    List<CustomFlowBranchImage> editableTemplateImages =
        List<CustomFlowBranchImage>.from(initialCase.effectiveTemplateImages);
    List<CustomFlowStep> editableSteps = List<CustomFlowStep>.from(
      initialCase.steps,
    );
    String selectedInsertFlowName = _defaultSavedCustomFlowName();
    String? insertFlowMessage;
    Set<String> selectedBranchStepIds = <String>{};
    CustomFlowBranchCase? result;

    await showAdaptiveDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            Future<void> addBranchStep(CustomFlowStepType type) async {
              final created = _createDefaultStep(type);
              await _showStepEditor(
                initialStep: created,
                onConfirm: (updated) {
                  setLocalState(() {
                    editableSteps = [...editableSteps, updated];
                  });
                },
              );
            }

            Future<void> editBranchStep(int index) async {
              await _showStepEditor(
                initialStep: editableSteps[index],
                onConfirm: (updated) {
                  setLocalState(() {
                    editableSteps = _replaceStepInList(
                      editableSteps,
                      index,
                      updated,
                    );
                  });
                },
              );
            }

            Future<void> appendSavedFlowToBranchSteps() async {
              final appendResult = await _buildSavedCustomFlowGroupForAppend(
                selectedInsertFlowName,
                onError: (message) {
                  if (!context.mounted) {
                    return;
                  }
                  setLocalState(() {
                    insertFlowMessage = message;
                  });
                },
              );
              if (appendResult == null || !context.mounted) {
                return;
              }
              setLocalState(() {
                editableSteps = [...editableSteps, appendResult.group];
                insertFlowMessage =
                    '已插入自定义流程“${appendResult.flow.name}”，组内 ${appendResult.group.children.length} 个步骤。';
              });
            }

            void toggleBranchStepSelection(String stepId, {bool? selected}) {
              setLocalState(() {
                final nextSelection = Set<String>.from(selectedBranchStepIds);
                final shouldSelect =
                    selected ?? !nextSelection.contains(stepId);
                if (shouldSelect) {
                  nextSelection.add(stepId);
                } else {
                  nextSelection.remove(stepId);
                }
                selectedBranchStepIds = nextSelection;
              });
            }

            void clearBranchStepSelection() {
              if (selectedBranchStepIds.isEmpty) {
                return;
              }
              setLocalState(() {
                selectedBranchStepIds = <String>{};
              });
            }

            void copySelectedBranchSteps() {
              final copyResult = _copySelectedStepsInList(
                editableSteps,
                selectedBranchStepIds,
              );
              if (copyResult == null) {
                return;
              }
              setLocalState(() {
                editableSteps = copyResult.steps;
                selectedBranchStepIds = copyResult.copiedStepIds;
              });
            }

            Future<void> deleteSelectedBranchSteps() async {
              final selectedCount = selectedBranchStepIds.length;
              if (selectedCount == 0) {
                return;
              }
              final confirmed = await _confirmClearStepList(
                title: '删除选中节点',
                content: '确认删除已选中的 $selectedCount 个节点吗？删除后不可恢复。',
              );
              if (!confirmed) {
                return;
              }
              final deleteResult = _deleteSelectedStepsInList(
                editableSteps,
                selectedBranchStepIds,
              );
              if (deleteResult == null || !context.mounted) {
                return;
              }
              setLocalState(() {
                editableSteps = deleteResult.steps;
                selectedBranchStepIds = <String>{};
              });
            }

            Widget buildBranchStepList() {
              if (editableSteps.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.blueGrey.shade100),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey.shade50,
                  ),
                  child: const Text(
                    '这个分支还没有步骤。可以添加等待、识图点击、固定坐标点击、粘贴文字、识图等待、多图条件分支、识图坐标分支、循环块等。',
                    style: TextStyle(fontSize: 12.5, color: Colors.blueGrey),
                  ),
                );
              }
              return ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: editableSteps.length,
                onReorder: (oldIndex, newIndex) {
                  setLocalState(() {
                    editableSteps = _reorderItems(
                      editableSteps,
                      oldIndex,
                      newIndex,
                    );
                  });
                },
                itemBuilder: (context, index) {
                  final step = editableSteps[index];
                  final isSelected = selectedBranchStepIds.contains(step.id);
                  final stepForegroundColor = isSelected
                      ? LinglongTheme.ink
                      : null;
                  final stepSubtleColor = isSelected
                      ? LinglongTheme.inkSoft
                      : null;
                  return Card(
                    key: ValueKey('branch-step-${step.id}-$index'),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: isSelected ? const Color(0xFFFFF6E3) : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: LinglongTheme.panelRadius,
                      side: BorderSide(
                        color: isSelected
                            ? LinglongTheme.mountainBlue
                            : Colors.blueGrey.shade100,
                        width: isSelected ? 1.4 : 1,
                      ),
                    ),
                    child: ListTile(
                      selected: isSelected,
                      selectedColor: LinglongTheme.ink,
                      iconColor: stepForegroundColor,
                      textColor: stepForegroundColor,
                      onTap: () => toggleBranchStepSelection(step.id),
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: isSelected,
                            checkColor: Colors.white,
                            fillColor: WidgetStateProperty.resolveWith((
                              states,
                            ) {
                              return states.contains(WidgetState.selected)
                                  ? LinglongTheme.mountainBlue
                                  : null;
                            }),
                            side: BorderSide(
                              color: isSelected
                                  ? LinglongTheme.mountainBlue
                                  : LinglongTheme.ink,
                              width: 1.8,
                            ),
                            onChanged: (value) => toggleBranchStepSelection(
                              step.id,
                              selected: value,
                            ),
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: Icon(
                              Icons.drag_handle,
                              color: stepForegroundColor,
                            ),
                          ),
                        ],
                      ),
                      title: Text(
                        _buildStepTitle(step, index),
                        style: TextStyle(
                          color: stepForegroundColor,
                          fontWeight: isSelected ? FontWeight.w700 : null,
                        ),
                      ),
                      subtitle: Text(
                        _buildStepSubtitle(step),
                        style: TextStyle(color: stepSubtleColor),
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            tooltip: '上移',
                            color: stepForegroundColor,
                            disabledColor: isSelected
                                ? const Color(0x993F5D65)
                                : null,
                            onPressed: index == 0
                                ? null
                                : () => setLocalState(() {
                                    editableSteps = _moveStepInList(
                                      editableSteps,
                                      index,
                                      -1,
                                    );
                                  }),
                            icon: const Icon(Icons.keyboard_arrow_up),
                          ),
                          IconButton(
                            tooltip: '下移',
                            color: stepForegroundColor,
                            disabledColor: isSelected
                                ? const Color(0x993F5D65)
                                : null,
                            onPressed: index == editableSteps.length - 1
                                ? null
                                : () => setLocalState(() {
                                    editableSteps = _moveStepInList(
                                      editableSteps,
                                      index,
                                      1,
                                    );
                                  }),
                            icon: const Icon(Icons.keyboard_arrow_down),
                          ),
                          IconButton(
                            tooltip: '编辑',
                            color: stepForegroundColor,
                            onPressed: () => editBranchStep(index),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: '删除',
                            color: stepForegroundColor,
                            onPressed: () => setLocalState(() {
                              final removedStepId = editableSteps[index].id;
                              editableSteps = _removeStepFromList(
                                editableSteps,
                                index,
                              );
                              selectedBranchStepIds =
                                  _removeStepIdFromSelection(
                                    selectedBranchStepIds,
                                    removedStepId,
                                  );
                            }),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            }

            // ignore: unused_element
            Widget buildImagePicker() {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<CustomFlowImageSource>(
                    initialValue: selectedImageSource,
                    decoration: _solidDropdownDecoration('图片来源'),
                    dropdownColor: LinglongTheme.dropdownSurface,
                    items: CustomFlowImageSource.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              value == CustomFlowImageSource.asset
                                  ? '内置图片'
                                  : '本地图片',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setLocalState(() {
                        selectedImageSource = value;
                        if (value == CustomFlowImageSource.asset &&
                            selectedTemplate.isEmpty &&
                            _availableTemplateNames.isNotEmpty) {
                          selectedTemplate = _availableTemplateNames.first;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  if (selectedImageSource == CustomFlowImageSource.asset) ...[
                    DropdownButtonFormField<String>(
                      initialValue:
                          _availableTemplateNames.contains(selectedTemplate)
                          ? selectedTemplate
                          : null,
                      decoration: _solidDropdownDecoration('选择模板图片'),
                      dropdownColor: LinglongTheme.dropdownSurface,
                      items: _availableTemplateNames
                          .map(
                            (value) => DropdownMenuItem<String>(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setLocalState(() {
                          selectedTemplate = value ?? '';
                          if (selectedTemplate.isNotEmpty) {
                            selectedTemplatePath = '';
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: selectedTemplate,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: '模板图片文件名',
                      ),
                      onChanged: (value) {
                        setLocalState(() {
                          selectedTemplate = value.trim();
                          if (selectedTemplate.isNotEmpty) {
                            selectedTemplatePath = '';
                          }
                        });
                      },
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: templatePathController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '本地图片路径',
                            ),
                            onChanged: (value) {
                              setLocalState(() {
                                selectedTemplatePath = value.trim();
                                if (selectedTemplatePath.isNotEmpty) {
                                  selectedTemplate = p.basename(
                                    selectedTemplatePath,
                                  );
                                }
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () async {
                            final file = await openFile(
                              acceptedTypeGroups: const [
                                XTypeGroup(
                                  label: 'images',
                                  extensions: ['png', 'jpg', 'jpeg', 'bmp'],
                                ),
                              ],
                            );
                            if (file == null) {
                              return;
                            }
                            setLocalState(() {
                              selectedTemplatePath = file.path;
                              templatePathController.text = file.path;
                              selectedTemplate = p.basename(file.path);
                            });
                          },
                          child: const Text('选择本地图片'),
                        ),
                      ],
                    ),
                  ],
                ],
              );
            }

            CustomFlowBranchImage buildDefaultBranchImage() {
              final imageId = editableTemplateImages.isEmpty
                  ? initialCase.id
                  : _newCustomFlowId();
              return CustomFlowBranchImage(
                id: imageId,
                templateName: _safeDefaultTemplateName(),
                imageSource: CustomFlowImageSource.localFile,
              );
            }

            void updateBranchImage(
              int index,
              CustomFlowBranchImage updatedImage,
            ) {
              final images = List<CustomFlowBranchImage>.from(
                editableTemplateImages,
              );
              images[index] = updatedImage;
              editableTemplateImages = images;
            }

            Widget buildTemplateImageCard(
              CustomFlowBranchImage image,
              int index,
            ) {
              return Card(
                key: ValueKey('branch-template-image-${image.id}-$index'),
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_handle),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '条件图片 ${index + 1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          _buildCustomFlowImagePreview(
                            source: image.imageSource,
                            templateName: image.templateName,
                            templatePath: image.templatePath,
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: '上移',
                            onPressed: index == 0
                                ? null
                                : () => setLocalState(() {
                                    editableTemplateImages = _moveItemInList(
                                      editableTemplateImages,
                                      index,
                                      -1,
                                    );
                                  }),
                            icon: const Icon(Icons.keyboard_arrow_up),
                          ),
                          IconButton(
                            tooltip: '下移',
                            onPressed:
                                index == editableTemplateImages.length - 1
                                ? null
                                : () => setLocalState(() {
                                    editableTemplateImages = _moveItemInList(
                                      editableTemplateImages,
                                      index,
                                      1,
                                    );
                                  }),
                            icon: const Icon(Icons.keyboard_arrow_down),
                          ),
                          IconButton(
                            tooltip: '删除',
                            onPressed: () => setLocalState(() {
                              final images = List<CustomFlowBranchImage>.from(
                                editableTemplateImages,
                              )..removeAt(index);
                              editableTemplateImages = images;
                            }),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<CustomFlowImageSource>(
                        initialValue: image.imageSource,
                        decoration: _solidDropdownDecoration('图片来源'),
                        dropdownColor: LinglongTheme.dropdownSurface,
                        items: CustomFlowImageSource.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(
                                  value == CustomFlowImageSource.asset
                                      ? '内置图片'
                                      : '本地图片',
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setLocalState(() {
                            updateBranchImage(
                              index,
                              image.copyWith(
                                imageSource: value,
                                templateName:
                                    value == CustomFlowImageSource.asset &&
                                        image.templateName.isEmpty
                                    ? _safeDefaultTemplateName()
                                    : image.templateName,
                                templatePath:
                                    value == CustomFlowImageSource.asset
                                    ? ''
                                    : image.templatePath,
                              ),
                            );
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                      if (image.imageSource == CustomFlowImageSource.asset) ...[
                        DropdownButtonFormField<String>(
                          initialValue:
                              _availableTemplateNames.contains(
                                image.templateName,
                              )
                              ? image.templateName
                              : null,
                          decoration: _solidDropdownDecoration('选择模板图片'),
                          dropdownColor: LinglongTheme.dropdownSurface,
                          items: _availableTemplateNames
                              .map(
                                (value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            setLocalState(() {
                              updateBranchImage(
                                index,
                                image.copyWith(
                                  templateName: value ?? '',
                                  templatePath: '',
                                ),
                              );
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          key: ValueKey(
                            'branch-template-name-${image.id}-${image.templateName}',
                          ),
                          initialValue: image.templateName,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '模板图片文件名',
                          ),
                          onChanged: (value) {
                            setLocalState(() {
                              updateBranchImage(
                                index,
                                image.copyWith(
                                  templateName: value.trim(),
                                  templatePath: '',
                                ),
                              );
                            });
                          },
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                key: ValueKey(
                                  'branch-template-path-${image.id}-${image.templatePath}',
                                ),
                                initialValue: image.templatePath,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '本地图片路径',
                                ),
                                onChanged: (value) {
                                  setLocalState(() {
                                    final path = value.trim();
                                    updateBranchImage(
                                      index,
                                      image.copyWith(
                                        templatePath: path,
                                        templateName: path.isNotEmpty
                                            ? p.basename(path)
                                            : image.templateName,
                                      ),
                                    );
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () async {
                                final file = await openFile(
                                  acceptedTypeGroups: const [
                                    XTypeGroup(
                                      label: 'images',
                                      extensions: ['png', 'jpg', 'jpeg', 'bmp'],
                                    ),
                                  ],
                                );
                                if (file == null) {
                                  return;
                                }
                                setLocalState(() {
                                  updateBranchImage(
                                    index,
                                    image.copyWith(
                                      templatePath: file.path,
                                      templateName: p.basename(file.path),
                                    ),
                                  );
                                });
                              },
                              child: const Text('选择本地图片'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }

            Widget buildTemplateImageList() {
              final images = editableTemplateImages;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '条件图片组（任意一张命中即执行此分支）',
                          style: TextStyle(
                            color: Colors.blueGrey.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () => setLocalState(() {
                          editableTemplateImages = [
                            ...editableTemplateImages,
                            buildDefaultBranchImage(),
                          ];
                        }),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('添加图片'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (images.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.blueGrey.shade100),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey.shade50,
                      ),
                      child: const Text(
                        '还没有条件图片。请至少添加一张图片。',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.blueGrey,
                        ),
                      ),
                    )
                  else
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: images.length,
                      onReorder: (oldIndex, newIndex) {
                        setLocalState(() {
                          editableTemplateImages = _reorderItems(
                            editableTemplateImages,
                            oldIndex,
                            newIndex,
                          );
                        });
                      },
                      itemBuilder: (context, index) {
                        return buildTemplateImageCard(images[index], index);
                      },
                    ),
                ],
              );
            }

            Widget buildBranchRecognitionModeDropdown() {
              return DropdownButtonFormField<CustomFlowRecognitionMode>(
                initialValue: selectedRecognitionMode,
                decoration: _solidDropdownDecoration('识别模式'),
                dropdownColor: LinglongTheme.dropdownSurface,
                items: CustomFlowRecognitionMode.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(_recognitionModeLabel(value)),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setLocalState(() {
                    selectedRecognitionMode = value;
                  });
                },
              );
            }

            List<Widget> buildBranchOcrFields() {
              return [
                TextField(
                  controller: ocrTargetTextController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '目标文字',
                    hintText: '例如：确定',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<CustomFlowOcrMatchMode>(
                  initialValue: selectedOcrMatchMode,
                  decoration: _solidDropdownDecoration('匹配规则'),
                  dropdownColor: LinglongTheme.dropdownSurface,
                  items: CustomFlowOcrMatchMode.values
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(_ocrMatchModeLabel(value)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setLocalState(() {
                      selectedOcrMatchMode = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confidenceController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'OCR 置信度阈值（0-1）',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^[0-9.]*$')),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  '识别区域（留空为全屏）',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ocrRegionLeftController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '左',
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: ocrRegionTopController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '上',
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ocrRegionRightController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '右',
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: ocrRegionBottomController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '下',
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                  ],
                ),
              ];
            }

            ({int left, int top, int right, int bottom})
            parseBranchOcrRegion() {
              final regionTexts = [
                ocrRegionLeftController.text.trim(),
                ocrRegionTopController.text.trim(),
                ocrRegionRightController.text.trim(),
                ocrRegionBottomController.text.trim(),
              ];
              final hasAnyRegion = regionTexts.any((item) => item.isNotEmpty);
              final hasFullRegion = regionTexts.every(
                (item) => item.isNotEmpty,
              );
              if (!hasAnyRegion) {
                return (left: -1, top: -1, right: -1, bottom: -1);
              }
              if (!hasFullRegion) {
                throw Exception('识别区域需要同时填写左、上、右、下四个坐标，或全部留空');
              }
              final left = int.tryParse(regionTexts[0]) ?? -1;
              final top = int.tryParse(regionTexts[1]) ?? -1;
              final right = int.tryParse(regionTexts[2]) ?? -1;
              final bottom = int.tryParse(regionTexts[3]) ?? -1;
              if (left < 0 || top < 0 || right <= left || bottom <= top) {
                throw Exception('识别区域必须满足：右 > 左，且下 > 上');
              }
              return (left: left, top: top, right: right, bottom: bottom);
            }

            return AlertDialog(
              title: const Text('编辑分支条件'),
              content: SizedBox(
                width: 680,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: labelController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '分支名称',
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (!usePositionCondition) ...[
                        buildBranchRecognitionModeDropdown(),
                        const SizedBox(height: 12),
                        if (selectedRecognitionMode ==
                            CustomFlowRecognitionMode.image) ...[
                          buildTemplateImageList(),
                          const SizedBox(height: 12),
                          TextField(
                            controller: confidenceController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '识图阈值（0-1）',
                            ),
                          ),
                        ] else ...[
                          ...buildBranchOcrFields(),
                        ],
                      ] else ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: const Text(
                            '按识图中心坐标填写条件。留空表示这一项不限制；多个条件会同时生效。',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: centerXMinController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'X 最小值',
                                ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'^\d*\.?\d*$'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: centerXMaxController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'X 最大值',
                                ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'^\d*\.?\d*$'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: centerYMinController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'Y 最小值',
                                ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'^\d*\.?\d*$'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: centerYMaxController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'Y 最大值',
                                ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'^\d*\.?\d*$'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton(
                            onPressed: () =>
                                addBranchStep(CustomFlowStepType.wait),
                            child: const Text('添加等待'),
                          ),
                          ElevatedButton(
                            onPressed: () =>
                                addBranchStep(CustomFlowStepType.imageTap),
                            child: const Text('添加识图点击'),
                          ),
                          ElevatedButton(
                            onPressed: () =>
                                addBranchStep(CustomFlowStepType.coordinateTap),
                            child: const Text('添加固定坐标点击'),
                          ),
                          ElevatedButton(
                            onPressed: () =>
                                addBranchStep(CustomFlowStepType.pasteText),
                            child: const Text('添加粘贴文字'),
                          ),
                          ElevatedButton(
                            onPressed: () => addBranchStep(
                              CustomFlowStepType.waitImageState,
                            ),
                            child: const Text('添加识图等待'),
                          ),
                          ElevatedButton(
                            onPressed: () =>
                                addBranchStep(CustomFlowStepType.imageBranch),
                            child: const Text('添加多图条件分支'),
                          ),
                          ElevatedButton(
                            onPressed: () => addBranchStep(
                              CustomFlowStepType.imagePositionBranch,
                            ),
                            child: const Text('添加识图坐标分支'),
                          ),
                          ElevatedButton(
                            onPressed: () =>
                                addBranchStep(CustomFlowStepType.loopBlock),
                            child: const Text('添加循环块'),
                          ),
                          ElevatedButton(
                            onPressed: () =>
                                addBranchStep(CustomFlowStepType.gameMode),
                            child: const Text('添加痒痒鼠模式'),
                          ),
                          ElevatedButton(
                            onPressed: () =>
                                addBranchStep(CustomFlowStepType.recordedFlow),
                            child: const Text('添加录制手势'),
                          ),
                          ElevatedButton(
                            onPressed: () => addBranchStep(
                              CustomFlowStepType.restartActivity,
                            ),
                            child: const Text('添加重启Activity（可以用来重启游戏）'),
                          ),
                          ElevatedButton(
                            onPressed: () => addBranchStep(
                              CustomFlowStepType.shutdownComputer,
                            ),
                            child: const Text('添加关机操作'),
                          ),
                          ElevatedButton(
                            onPressed: selectedBranchStepIds.isEmpty
                                ? null
                                : () => _saveSelectedCustomFlowStepsAsFlow(
                                    editableSteps,
                                    selectedBranchStepIds,
                                  ),
                            child: Text(
                              selectedBranchStepIds.isEmpty
                                  ? '保存选中为流程'
                                  : '保存选中为流程（${selectedBranchStepIds.length}）',
                            ),
                          ),
                          ElevatedButton(
                            onPressed: selectedBranchStepIds.isEmpty
                                ? null
                                : copySelectedBranchSteps,
                            child: Text(
                              selectedBranchStepIds.isEmpty
                                  ? '复制选中节点'
                                  : '复制选中节点（${selectedBranchStepIds.length}）',
                            ),
                          ),
                          ElevatedButton(
                            onPressed: selectedBranchStepIds.isEmpty
                                ? null
                                : deleteSelectedBranchSteps,
                            style: _dangerButtonStyle(),
                            child: Text(
                              selectedBranchStepIds.isEmpty
                                  ? '删除选中节点'
                                  : '删除选中节点（${selectedBranchStepIds.length}）',
                            ),
                          ),
                          OutlinedButton(
                            onPressed: selectedBranchStepIds.isEmpty
                                ? null
                                : clearBranchStepSelection,
                            child: const Text('取消选中'),
                          ),
                          ElevatedButton(
                            onPressed: editableSteps.isEmpty
                                ? null
                                : () async {
                                    final confirmed =
                                        await _confirmClearStepList(
                                          title: '清空分支步骤',
                                          content: '确认清空这个分支下的所有步骤吗？',
                                        );
                                    if (!confirmed) {
                                      return;
                                    }
                                    setLocalState(() {
                                      editableSteps = [];
                                      selectedBranchStepIds = <String>{};
                                    });
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade50,
                              foregroundColor: Colors.red.shade700,
                            ),
                            child: const Text('清空列表'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildSavedCustomFlowInsertControls(
                        selectedFlowName: selectedInsertFlowName,
                        onSelectedFlowChanged: (value) {
                          setLocalState(() {
                            selectedInsertFlowName = value;
                            insertFlowMessage = null;
                          });
                        },
                        onInsertPressed: appendSavedFlowToBranchSteps,
                        message: insertFlowMessage,
                      ),
                      const SizedBox(height: 12),
                      buildBranchStepList(),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消', style: TextStyle(color: Colors.blue)),
                ),
                FilledButton(
                  onPressed: () {
                    final parsedCenterXMin =
                        centerXMinController.text.trim().isEmpty
                        ? null
                        : _parseSeconds(centerXMinController.text);
                    final parsedCenterXMax =
                        centerXMaxController.text.trim().isEmpty
                        ? null
                        : _parseSeconds(centerXMaxController.text);
                    final parsedCenterYMin =
                        centerYMinController.text.trim().isEmpty
                        ? null
                        : _parseSeconds(centerYMinController.text);
                    final parsedCenterYMax =
                        centerYMaxController.text.trim().isEmpty
                        ? null
                        : _parseSeconds(centerYMaxController.text);
                    final usesTextRecognition =
                        !usePositionCondition &&
                        selectedRecognitionMode ==
                            CustomFlowRecognitionMode.text;
                    final targetText = ocrTargetTextController.text.trim();
                    if (usesTextRecognition && targetText.isEmpty) {
                      throw Exception('文字识别需要填写目标文字');
                    }
                    final ocrRegion = usesTextRecognition
                        ? parseBranchOcrRegion()
                        : (
                            left: initialCase.ocrRegionLeft,
                            top: initialCase.ocrRegionTop,
                            right: initialCase.ocrRegionRight,
                            bottom: initialCase.ocrRegionBottom,
                          );
                    final nextTemplateImages = usePositionCondition
                        ? const <CustomFlowBranchImage>[]
                        : (usesTextRecognition
                              ? const <CustomFlowBranchImage>[]
                              : editableTemplateImages);
                    result = initialCase.copyWith(
                      label: labelController.text.trim(),
                      recognitionMode: usePositionCondition
                          ? initialCase.recognitionMode
                          : selectedRecognitionMode,
                      templateImages: nextTemplateImages,
                      confidence: usePositionCondition
                          ? initialCase.confidence
                          : (double.tryParse(
                                      confidenceController.text.trim(),
                                    ) ??
                                    0.68)
                                .clamp(0.01, 0.99)
                                .toDouble(),
                      ocrTargetText: usesTextRecognition
                          ? targetText
                          : initialCase.ocrTargetText,
                      ocrMatchMode: selectedOcrMatchMode,
                      ocrRegionLeft: ocrRegion.left,
                      ocrRegionTop: ocrRegion.top,
                      ocrRegionRight: ocrRegion.right,
                      ocrRegionBottom: ocrRegion.bottom,
                      centerXMin: parsedCenterXMin,
                      centerXMax: parsedCenterXMax,
                      centerYMin: parsedCenterYMin,
                      centerYMax: parsedCenterYMax,
                      steps: editableSteps,
                    );
                    if (result != null) {
                      _saveCustomFlowNumericDefaultsForBranchCase(result!);
                    }
                    Navigator.of(context).pop();
                  },
                  child: const Text('确认'),
                ),
              ],
            );
          },
        );
      },
    );
    return result;
  }

  Future<void> _showStepEditor({
    required CustomFlowStep initialStep,
    required ValueChanged<CustomFlowStep> onConfirm,
  }) async {
    final secondsInputFormatter = FilteringTextInputFormatter.allow(
      RegExp(r'^\d*\.?\d*$'),
    );
    final integerInputFormatter = FilteringTextInputFormatter.digitsOnly;
    final signedIntegerInputFormatter = FilteringTextInputFormatter.allow(
      RegExp(r'^-?\d*$'),
    );
    final labelController = TextEditingController(text: initialStep.label);
    final waitMinHourController = TextEditingController(
      text: _durationHoursPart(initialStep.waitMinSeconds).toString(),
    );
    final waitMinMinuteController = TextEditingController(
      text: _durationMinutesPart(initialStep.waitMinSeconds).toString(),
    );
    final waitMinSecondController = TextEditingController(
      text: _durationSecondsPartText(initialStep.waitMinSeconds),
    );
    final waitMaxHourController = TextEditingController(
      text: _durationHoursPart(initialStep.waitMaxSeconds).toString(),
    );
    final waitMaxMinuteController = TextEditingController(
      text: _durationMinutesPart(initialStep.waitMaxSeconds).toString(),
    );
    final waitMaxSecondController = TextEditingController(
      text: _durationSecondsPartText(initialStep.waitMaxSeconds),
    );
    final confidenceController = TextEditingController(
      text: initialStep.confidence.toString(),
    );
    final maxAttemptsController = TextEditingController(
      text: initialStep.maxAttempts.toString(),
    );
    final retryIntervalController = TextEditingController(
      text: _secondsText(initialStep.retryIntervalSeconds),
    );
    final ocrTargetTextController = TextEditingController(
      text: initialStep.ocrTargetText,
    );
    final ocrRegionLeftController = TextEditingController(
      text: initialStep.ocrRegionLeft >= 0
          ? initialStep.ocrRegionLeft.toString()
          : '',
    );
    final ocrRegionTopController = TextEditingController(
      text: initialStep.ocrRegionTop >= 0
          ? initialStep.ocrRegionTop.toString()
          : '',
    );
    final ocrRegionRightController = TextEditingController(
      text: initialStep.ocrRegionRight >= 0
          ? initialStep.ocrRegionRight.toString()
          : '',
    );
    final ocrRegionBottomController = TextEditingController(
      text: initialStep.ocrRegionBottom >= 0
          ? initialStep.ocrRegionBottom.toString()
          : '',
    );
    final ocrMatchIndexController = TextEditingController(
      text: max(initialStep.ocrMatchIndex, 1).toString(),
    );
    final ocrClickOffsetXController = TextEditingController(
      text: initialStep.ocrClickOffsetX.toString(),
    );
    final ocrClickOffsetYController = TextEditingController(
      text: initialStep.ocrClickOffsetY.toString(),
    );
    final randomOffsetController = TextEditingController(
      text: initialStep.randomOffsetPx.toString(),
    );
    final postWaitMinController = TextEditingController(
      text: _secondsText(initialStep.postWaitMinSeconds),
    );
    final postWaitMaxController = TextEditingController(
      text: _secondsText(initialStep.postWaitMaxSeconds),
    );
    final xController = TextEditingController(text: initialStep.x.toString());
    final yController = TextEditingController(text: initialStep.y.toString());
    final branchPositionOffsetXController = TextEditingController(
      text: initialStep.branchPositionOffsetX.toString(),
    );
    final branchPositionOffsetYController = TextEditingController(
      text: initialStep.branchPositionOffsetY.toString(),
    );
    final textContentController = TextEditingController(
      text: initialStep.textContent,
    );
    final loopTextContentController = TextEditingController(
      text: initialStep.loopTextContent,
    );
    final timeoutController = TextEditingController(
      text: _secondsText(initialStep.timeoutSeconds),
    );
    final pollIntervalController = TextEditingController(
      text: _secondsText(initialStep.pollIntervalSeconds),
    );
    final shutdownDelayController = TextEditingController(
      text: _secondsText(initialStep.shutdownDelaySeconds),
    );
    final loopCountController = TextEditingController(
      text: initialStep.loopCount.toString(),
    );
    final recordedFlowLoopCountController = TextEditingController(
      text: initialStep.recordedFlowLoopCount.toString(),
    );
    final activityComponentController = TextEditingController(
      text: initialStep.activityComponent,
    );
    final templatePathController = TextEditingController(
      text: initialStep.templatePath,
    );
    String selectedTemplate = initialStep.templateName;
    String selectedTemplatePath = initialStep.templatePath;
    CustomFlowDeviceScope selectedDeviceScope = initialStep.deviceScope;
    CustomFlowImageSource selectedImageSource = initialStep.imageSource;
    CustomFlowRecognitionMode selectedRecognitionMode =
        initialStep.recognitionMode;
    CustomFlowWaitTargetState selectedWaitState = initialStep.waitTargetState;
    CustomFlowOcrMatchMode selectedOcrMatchMode = initialStep.ocrMatchMode;
    CustomFlowLoopMode selectedLoopMode = initialStep.loopMode;
    CustomFlowLoopImageAction selectedLoopImageAction =
        initialStep.loopImageAction;
    bool continueOnFailure = initialStep.continueOnFailure;
    bool useBranchDetectedPosition = initialStep.useBranchDetectedPosition;
    bool useParentLoopText = initialStep.useParentLoopText;
    String selectedLoopTemplateKey =
        initialStep.type == CustomFlowStepType.loopBlock ? 'full' : 'full';
    List<CustomFlowStep> editableChildren = List<CustomFlowStep>.from(
      initialStep.children,
    );
    List<CustomFlowBranchCase> editableBranchCases =
        List<CustomFlowBranchCase>.from(initialStep.branchCases);
    List<CustomFlowStep> editableFallbackChildren = List<CustomFlowStep>.from(
      initialStep.fallbackChildren,
    );
    bool reuseParentBranchScreenshot = initialStep.reuseParentBranchScreenshot;
    String selectedInsertFlowName = _defaultSavedCustomFlowName();
    String? insertFlowMessage;
    Set<String> selectedNestedStepIds = <String>{};
    final initialRecordedFlowName = initialStep.recordedFlowName.trim();
    String selectedRecordedFlowName = initialRecordedFlowName.isNotEmpty
        ? initialRecordedFlowName
        : (_savedFlows.isNotEmpty ? _savedFlows.first : '');
    final recordedFlowOptions = <String>[
      if (selectedRecordedFlowName.isNotEmpty &&
          !_savedFlows.contains(selectedRecordedFlowName))
        selectedRecordedFlowName,
      ..._savedFlows,
    ];
    String selectedGameModeName = _selectableGameModeNameOrDefault(
      initialStep.gameModeName,
    );
    Map<String, dynamic> gameModeConfig = _parseGameModeConfigSnapshot(
      initialStep.gameModeConfigJson,
      selectedGameModeName,
    );
    final gameModeBattleTimeController = TextEditingController(
      text: gameModeConfig['battleTime']?.toString() ?? '0',
    );
    final gameModeBottomController = TextEditingController(
      text: gameModeConfig['bottom']?.toString() ?? '-1',
    );
    final gameModeRightController = TextEditingController(
      text: gameModeConfig['right']?.toString() ?? '-1',
    );
    final gameModeRunTimesController = TextEditingController(
      text: gameModeConfig['runTimes']?.toString() ?? '0',
    );
    final gameModeBattleTimeAddController = TextEditingController(
      text: gameModeConfig['battleTimeAdd']?.toString() ?? '0',
    );
    final gameModePicCtrlController = TextEditingController(
      text: gameModeConfig['picCtrl']?.toString() ?? '0.68',
    );
    final gameModeTupoOutTimeController = TextEditingController(
      text: gameModeConfig['tupoOutTime']?.toString() ?? '4',
    );
    bool gameModeIsKuaQuSwitchOn =
        gameModeConfig['isKuaQuSwitchOn'] as bool? ?? false;
    bool gameModeIsKun1SwitchOn =
        gameModeConfig['isKun1SwitchOn'] as bool? ?? false;
    bool gameModeIsLoopToTupoSwitchOn =
        gameModeConfig['isLoopToTupoSwitchOn'] as bool? ?? false;
    bool gameModeIsLoopToTupoSwitchOn1 =
        gameModeConfig['isLoopToTupoSwitchOn1'] as bool? ?? true;
    bool gameModeIsLoopToTupoSwitchOn2 =
        gameModeConfig['isLoopToTupoSwitchOn2'] as bool? ?? true;
    bool gameModeIsLoopToTupoSwitchOn3 =
        gameModeConfig['isLoopToTupoSwitchOn3'] as bool? ?? true;
    bool gameModeIsLoopToTupoSwitchOn4 =
        gameModeConfig['isLoopToTupoSwitchOn4'] as bool? ?? true;
    bool gameModeIsTestUser = gameModeConfig['isTestUser'] as bool? ?? false;
    bool gameModeNeedCheck = gameModeConfig['needCheck'] as bool? ?? false;
    bool gameModeIsFirstDoneTupo =
        gameModeConfig['isFirstDoneTupo'] as bool? ?? false;
    bool isFetchingActivityComponent = false;

    void confirmStep(CustomFlowStep step) {
      onConfirm(step.copyWith(deviceScope: selectedDeviceScope));
    }

    void applyGameModeConfigSnapshot(Map<String, dynamic> config) {
      gameModeConfig = config;
      gameModeBattleTimeController.text =
          config['battleTime']?.toString() ?? '0';
      gameModeBottomController.text = config['bottom']?.toString() ?? '-1';
      gameModeRightController.text = config['right']?.toString() ?? '-1';
      gameModeRunTimesController.text = config['runTimes']?.toString() ?? '0';
      gameModeBattleTimeAddController.text =
          config['battleTimeAdd']?.toString() ?? '0';
      gameModePicCtrlController.text = config['picCtrl']?.toString() ?? '0.68';
      gameModeTupoOutTimeController.text =
          config['tupoOutTime']?.toString() ?? '4';
      gameModeIsKuaQuSwitchOn = config['isKuaQuSwitchOn'] as bool? ?? false;
      gameModeIsKun1SwitchOn = config['isKun1SwitchOn'] as bool? ?? false;
      gameModeIsLoopToTupoSwitchOn =
          config['isLoopToTupoSwitchOn'] as bool? ?? false;
      gameModeIsLoopToTupoSwitchOn1 =
          config['isLoopToTupoSwitchOn1'] as bool? ?? true;
      gameModeIsLoopToTupoSwitchOn2 =
          config['isLoopToTupoSwitchOn2'] as bool? ?? true;
      gameModeIsLoopToTupoSwitchOn3 =
          config['isLoopToTupoSwitchOn3'] as bool? ?? true;
      gameModeIsLoopToTupoSwitchOn4 =
          config['isLoopToTupoSwitchOn4'] as bool? ?? true;
      gameModeIsTestUser = config['isTestUser'] as bool? ?? false;
      gameModeNeedCheck = config['needCheck'] as bool? ?? false;
      gameModeIsFirstDoneTupo = config['isFirstDoneTupo'] as bool? ?? false;
    }

    await showAdaptiveDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            Widget buildImagePicker() {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<CustomFlowImageSource>(
                    initialValue: selectedImageSource,
                    decoration: _solidDropdownDecoration('图片来源'),
                    dropdownColor: LinglongTheme.dropdownSurface,
                    items: CustomFlowImageSource.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              value == CustomFlowImageSource.asset
                                  ? '内置图片'
                                  : '本地图片',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setLocalState(() {
                        selectedImageSource = value;
                        if (value == CustomFlowImageSource.asset &&
                            selectedTemplate.isEmpty &&
                            _availableTemplateNames.isNotEmpty) {
                          selectedTemplate = _availableTemplateNames.first;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  if (selectedImageSource == CustomFlowImageSource.asset) ...[
                    DropdownButtonFormField<String>(
                      initialValue:
                          _availableTemplateNames.contains(selectedTemplate)
                          ? selectedTemplate
                          : null,
                      decoration: _solidDropdownDecoration('选择模板图片'),
                      dropdownColor: LinglongTheme.dropdownSurface,
                      items: _availableTemplateNames
                          .map(
                            (value) => DropdownMenuItem<String>(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setLocalState(() {
                          selectedTemplate = value ?? '';
                          if (selectedTemplate.isNotEmpty) {
                            selectedTemplatePath = '';
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: selectedTemplate,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: '模板图片文件名',
                      ),
                      onChanged: (value) {
                        setLocalState(() {
                          selectedTemplate = value.trim();
                          if (selectedTemplate.isNotEmpty) {
                            selectedTemplatePath = '';
                          }
                        });
                      },
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: templatePathController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '本地图片路径',
                            ),
                            onChanged: (value) {
                              setLocalState(() {
                                selectedTemplatePath = value.trim();
                                if (selectedTemplatePath.isNotEmpty) {
                                  selectedTemplate = p.basename(
                                    selectedTemplatePath,
                                  );
                                }
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () async {
                            final file = await openFile(
                              acceptedTypeGroups: const [
                                XTypeGroup(
                                  label: 'images',
                                  extensions: ['png', 'jpg', 'jpeg', 'bmp'],
                                ),
                              ],
                            );
                            if (file == null) {
                              return;
                            }
                            setLocalState(() {
                              selectedTemplatePath = file.path;
                              templatePathController.text = file.path;
                              selectedTemplate = p.basename(file.path);
                            });
                          },
                          child: const Text('选择本地图片'),
                        ),
                      ],
                    ),
                  ],
                ],
              );
            }

            Widget buildImagePickerWithPreview() {
              return _buildImagePickerWithPreview(
                controls: buildImagePicker(),
                source: selectedImageSource,
                templateName: selectedTemplate,
                templatePath: selectedTemplatePath,
              );
            }

            Widget buildRecognitionModeDropdown() {
              return DropdownButtonFormField<CustomFlowRecognitionMode>(
                initialValue: selectedRecognitionMode,
                decoration: _solidDropdownDecoration('识别模式'),
                dropdownColor: LinglongTheme.dropdownSurface,
                items: CustomFlowRecognitionMode.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(_recognitionModeLabel(value)),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setLocalState(() {
                    selectedRecognitionMode = value;
                  });
                },
              );
            }

            List<Widget> buildOcrCommonFields({
              bool includeMatchIndex = false,
              bool includeClickOffset = false,
            }) {
              return [
                TextField(
                  key: const ValueKey('ocr-target-text-field'),
                  controller: ocrTargetTextController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '目标文字',
                    hintText: '例如：确定',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<CustomFlowOcrMatchMode>(
                  key: const ValueKey('ocr-match-mode-dropdown'),
                  initialValue: selectedOcrMatchMode,
                  decoration: _solidDropdownDecoration('匹配规则'),
                  dropdownColor: LinglongTheme.dropdownSurface,
                  items: CustomFlowOcrMatchMode.values
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(_ocrMatchModeLabel(value)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setLocalState(() {
                      selectedOcrMatchMode = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confidenceController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'OCR 置信度阈值（0-1）',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^[0-9.]*$')),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  '识别区域（留空为全屏）',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ocrRegionLeftController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '左',
                        ),
                        inputFormatters: [integerInputFormatter],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: ocrRegionTopController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '上',
                        ),
                        inputFormatters: [integerInputFormatter],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ocrRegionRightController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '右',
                        ),
                        inputFormatters: [integerInputFormatter],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: ocrRegionBottomController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '下',
                        ),
                        inputFormatters: [integerInputFormatter],
                      ),
                    ),
                  ],
                ),
                if (includeMatchIndex) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: ocrMatchIndexController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '使用第几个命中结果',
                    ),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ],
                if (includeClickOffset) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ocrClickOffsetXController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '点击 X 偏移',
                          ),
                          inputFormatters: [signedIntegerInputFormatter],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: ocrClickOffsetYController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '点击 Y 偏移',
                          ),
                          inputFormatters: [signedIntegerInputFormatter],
                        ),
                      ),
                    ],
                  ),
                ],
              ];
            }

            ({int left, int top, int right, int bottom}) parseOcrRegion() {
              final regionTexts = [
                ocrRegionLeftController.text.trim(),
                ocrRegionTopController.text.trim(),
                ocrRegionRightController.text.trim(),
                ocrRegionBottomController.text.trim(),
              ];
              final hasAnyRegion = regionTexts.any((item) => item.isNotEmpty);
              final hasFullRegion = regionTexts.every(
                (item) => item.isNotEmpty,
              );
              if (!hasAnyRegion) {
                return (left: -1, top: -1, right: -1, bottom: -1);
              }
              if (!hasFullRegion) {
                throw Exception('识别区域需要同时填写左、上、右、下四个坐标，或全部留空');
              }
              final left = int.tryParse(regionTexts[0]) ?? -1;
              final top = int.tryParse(regionTexts[1]) ?? -1;
              final right = int.tryParse(regionTexts[2]) ?? -1;
              final bottom = int.tryParse(regionTexts[3]) ?? -1;
              if (left < 0 || top < 0 || right <= left || bottom <= top) {
                throw Exception('识别区域必须满足：右 > 左，且下 > 上');
              }
              return (left: left, top: top, right: right, bottom: bottom);
            }

            String resolveLoopTemplateName() {
              if (selectedImageSource == CustomFlowImageSource.localFile) {
                if (selectedTemplatePath.trim().isNotEmpty) {
                  return p.basename(selectedTemplatePath.trim());
                }
              }
              if (selectedTemplate.trim().isNotEmpty) {
                return selectedTemplate.trim();
              }
              return _safeDefaultTemplateName();
            }

            Future<void> addNestedStep({
              required List<CustomFlowStep> currentSteps,
              required void Function(List<CustomFlowStep>) onChanged,
              required CustomFlowStepType type,
            }) async {
              final created = _createDefaultStep(type);
              await _showStepEditor(
                initialStep: created,
                onConfirm: (updated) {
                  setLocalState(() {
                    onChanged([...currentSteps, updated]);
                  });
                },
              );
            }

            Future<void> editNestedStep({
              required List<CustomFlowStep> currentSteps,
              required int index,
              required void Function(List<CustomFlowStep>) onChanged,
            }) async {
              await _showStepEditor(
                initialStep: currentSteps[index],
                onConfirm: (updated) {
                  setLocalState(() {
                    onChanged(_replaceStepInList(currentSteps, index, updated));
                  });
                },
              );
            }

            Future<void> appendSavedFlowToNestedSteps({
              required List<CustomFlowStep> currentSteps,
              required void Function(List<CustomFlowStep>) onChanged,
            }) async {
              final appendResult = await _buildSavedCustomFlowGroupForAppend(
                selectedInsertFlowName,
                onError: (message) {
                  if (!context.mounted) {
                    return;
                  }
                  setLocalState(() {
                    insertFlowMessage = message;
                  });
                },
              );
              if (appendResult == null || !context.mounted) {
                return;
              }
              setLocalState(() {
                onChanged([...currentSteps, appendResult.group]);
                insertFlowMessage =
                    '已插入自定义流程“${appendResult.flow.name}”，组内 ${appendResult.group.children.length} 个步骤。';
              });
            }

            void toggleNestedStepSelection(String stepId, {bool? selected}) {
              setLocalState(() {
                final nextSelection = Set<String>.from(selectedNestedStepIds);
                final shouldSelect =
                    selected ?? !nextSelection.contains(stepId);
                if (shouldSelect) {
                  nextSelection.add(stepId);
                } else {
                  nextSelection.remove(stepId);
                }
                selectedNestedStepIds = nextSelection;
              });
            }

            void clearNestedStepSelection() {
              if (selectedNestedStepIds.isEmpty) {
                return;
              }
              setLocalState(() {
                selectedNestedStepIds = <String>{};
              });
            }

            void copySelectedNestedSteps({
              required List<CustomFlowStep> currentSteps,
              required void Function(List<CustomFlowStep>) onChanged,
            }) {
              final copyResult = _copySelectedStepsInList(
                currentSteps,
                selectedNestedStepIds,
              );
              if (copyResult == null) {
                return;
              }
              setLocalState(() {
                onChanged(copyResult.steps);
                selectedNestedStepIds = copyResult.copiedStepIds;
              });
            }

            Future<void> deleteSelectedNestedSteps({
              required List<CustomFlowStep> currentSteps,
              required void Function(List<CustomFlowStep>) onChanged,
            }) async {
              final selectedCount = selectedNestedStepIds.length;
              if (selectedCount == 0) {
                return;
              }
              final confirmed = await _confirmClearStepList(
                title: '删除选中节点',
                content: '确认删除已选中的 $selectedCount 个节点吗？删除后不可恢复。',
              );
              if (!confirmed) {
                return;
              }
              final deleteResult = _deleteSelectedStepsInList(
                currentSteps,
                selectedNestedStepIds,
              );
              if (deleteResult == null || !context.mounted) {
                return;
              }
              setLocalState(() {
                onChanged(deleteResult.steps);
                selectedNestedStepIds = <String>{};
              });
            }

            Widget buildNestedStepCards({
              required List<CustomFlowStep> steps,
              required String emptyText,
              required void Function(List<CustomFlowStep>) onChanged,
              required String groupTag,
            }) {
              if (steps.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.blueGrey.shade100),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey.shade50,
                  ),
                  child: Text(
                    emptyText,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Colors.blueGrey,
                    ),
                  ),
                );
              }
              return ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: steps.length,
                onReorder: (oldIndex, newIndex) {
                  setLocalState(() {
                    onChanged(_reorderItems(steps, oldIndex, newIndex));
                  });
                },
                itemBuilder: (context, index) {
                  final step = steps[index];
                  final isSelected = selectedNestedStepIds.contains(step.id);
                  final stepForegroundColor = isSelected
                      ? LinglongTheme.ink
                      : null;
                  final stepSubtleColor = isSelected
                      ? LinglongTheme.inkSoft
                      : null;
                  return Container(
                    key: ValueKey('$groupTag-${step.id}-$index'),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected
                            ? LinglongTheme.mountainBlue
                            : Colors.blueGrey.shade100,
                        width: isSelected ? 1.4 : 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      color: isSelected ? const Color(0xFFFFF6E3) : null,
                    ),
                    child: ListTile(
                      selected: isSelected,
                      selectedColor: LinglongTheme.ink,
                      iconColor: stepForegroundColor,
                      textColor: stepForegroundColor,
                      onTap: () => toggleNestedStepSelection(step.id),
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: isSelected,
                            checkColor: Colors.white,
                            fillColor: WidgetStateProperty.resolveWith((
                              states,
                            ) {
                              return states.contains(WidgetState.selected)
                                  ? LinglongTheme.mountainBlue
                                  : null;
                            }),
                            side: BorderSide(
                              color: isSelected
                                  ? LinglongTheme.mountainBlue
                                  : LinglongTheme.ink,
                              width: 1.8,
                            ),
                            onChanged: (value) => toggleNestedStepSelection(
                              step.id,
                              selected: value,
                            ),
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: Icon(
                              Icons.drag_handle,
                              color: stepForegroundColor,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.blueGrey.shade50,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              groupTag,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.blueGrey.shade700,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      title: Text(
                        _buildStepTitle(step, index),
                        style: TextStyle(
                          color: stepForegroundColor,
                          fontWeight: isSelected ? FontWeight.w700 : null,
                        ),
                      ),
                      subtitle: Text(
                        _buildStepSubtitle(step),
                        style: TextStyle(color: stepSubtleColor),
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            tooltip: '上移',
                            color: stepForegroundColor,
                            disabledColor: isSelected
                                ? const Color(0x993F5D65)
                                : null,
                            onPressed: index == 0
                                ? null
                                : () => setLocalState(() {
                                    onChanged(
                                      _moveStepInList(steps, index, -1),
                                    );
                                  }),
                            icon: const Icon(Icons.keyboard_arrow_up),
                          ),
                          IconButton(
                            tooltip: '下移',
                            color: stepForegroundColor,
                            disabledColor: isSelected
                                ? const Color(0x993F5D65)
                                : null,
                            onPressed: index == steps.length - 1
                                ? null
                                : () => setLocalState(() {
                                    onChanged(_moveStepInList(steps, index, 1));
                                  }),
                            icon: const Icon(Icons.keyboard_arrow_down),
                          ),
                          IconButton(
                            tooltip: '编辑',
                            color: stepForegroundColor,
                            onPressed: () => editNestedStep(
                              currentSteps: steps,
                              index: index,
                              onChanged: onChanged,
                            ),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: '删除',
                            color: stepForegroundColor,
                            onPressed: () => setLocalState(() {
                              final removedStepId = steps[index].id;
                              onChanged(_removeStepFromList(steps, index));
                              selectedNestedStepIds =
                                  _removeStepIdFromSelection(
                                    selectedNestedStepIds,
                                    removedStepId,
                                  );
                            }),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            }

            Widget buildNestedStepToolbar(
              void Function(List<CustomFlowStep>) onChanged,
              List<CustomFlowStep> currentSteps,
            ) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.wait,
                        ),
                        child: const Text('添加等待'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.imageTap,
                        ),
                        child: const Text('添加识图点击'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.coordinateTap,
                        ),
                        child: const Text('添加固定坐标点击'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.pasteText,
                        ),
                        child: const Text('添加粘贴文字'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.waitImageState,
                        ),
                        child: const Text('添加识图等待'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.imageBranch,
                        ),
                        child: const Text('添加多图条件分支'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.imagePositionBranch,
                        ),
                        child: const Text('添加识图坐标分支'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.loopBlock,
                        ),
                        child: const Text('添加循环块'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.gameMode,
                        ),
                        child: const Text('添加痒痒鼠模式'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.recordedFlow,
                        ),
                        child: const Text('添加录制手势'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.restartActivity,
                        ),
                        child: const Text('添加重启Activity（可以用来重启游戏）'),
                      ),
                      ElevatedButton(
                        onPressed: () => addNestedStep(
                          currentSteps: currentSteps,
                          onChanged: onChanged,
                          type: CustomFlowStepType.shutdownComputer,
                        ),
                        child: const Text('添加关机操作'),
                      ),
                      ElevatedButton(
                        onPressed: selectedNestedStepIds.isEmpty
                            ? null
                            : () => _saveSelectedCustomFlowStepsAsFlow(
                                currentSteps,
                                selectedNestedStepIds,
                              ),
                        child: Text(
                          selectedNestedStepIds.isEmpty
                              ? '保存选中为流程'
                              : '保存选中为流程（${selectedNestedStepIds.length}）',
                        ),
                      ),
                      ElevatedButton(
                        onPressed: selectedNestedStepIds.isEmpty
                            ? null
                            : () => copySelectedNestedSteps(
                                currentSteps: currentSteps,
                                onChanged: onChanged,
                              ),
                        child: Text(
                          selectedNestedStepIds.isEmpty
                              ? '复制选中节点'
                              : '复制选中节点（${selectedNestedStepIds.length}）',
                        ),
                      ),
                      ElevatedButton(
                        onPressed: selectedNestedStepIds.isEmpty
                            ? null
                            : () => deleteSelectedNestedSteps(
                                currentSteps: currentSteps,
                                onChanged: onChanged,
                              ),
                        style: _dangerButtonStyle(),
                        child: Text(
                          selectedNestedStepIds.isEmpty
                              ? '删除选中节点'
                              : '删除选中节点（${selectedNestedStepIds.length}）',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: selectedNestedStepIds.isEmpty
                            ? null
                            : clearNestedStepSelection,
                        child: const Text('取消选中'),
                      ),
                      ElevatedButton(
                        onPressed: currentSteps.isEmpty
                            ? null
                            : () async {
                                final confirmed = await _confirmClearStepList(
                                  title: '清空步骤列表',
                                  content: '确认清空当前列表中的所有步骤吗？',
                                );
                                if (!confirmed) {
                                  return;
                                }
                                setLocalState(() {
                                  onChanged(const []);
                                  selectedNestedStepIds = <String>{};
                                });
                              },
                        style: _dangerButtonStyle(),
                        child: const Text('清空列表'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildSavedCustomFlowInsertControls(
                    selectedFlowName: selectedInsertFlowName,
                    onSelectedFlowChanged: (value) {
                      setLocalState(() {
                        selectedInsertFlowName = value;
                        insertFlowMessage = null;
                      });
                    },
                    onInsertPressed: () => appendSavedFlowToNestedSteps(
                      currentSteps: currentSteps,
                      onChanged: onChanged,
                    ),
                    message: insertFlowMessage,
                  ),
                ],
              );
            }

            return AlertDialog(
              title: Text('编辑${_stepTypeLabel(initialStep.type)}'),
              content: SizedBox(
                width: 580,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: labelController,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '步骤名称',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<CustomFlowDeviceScope>(
                        initialValue: selectedDeviceScope,
                        decoration: _solidDropdownDecoration('选择要操作的模拟器对象'),
                        dropdownColor: LinglongTheme.dropdownSurface,
                        items: CustomFlowDeviceScope.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_deviceScopeLabel(value)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setLocalState(() {
                            selectedDeviceScope = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      if (initialStep.type == CustomFlowStepType.wait) ...[
                        const Text(
                          '最短等待时间',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: waitMinHourController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '时',
                                ),
                                inputFormatters: [integerInputFormatter],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: waitMinMinuteController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '分',
                                ),
                                inputFormatters: [integerInputFormatter],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: waitMinSecondController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '秒',
                                ),
                                inputFormatters: [secondsInputFormatter],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '最长等待时间',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: waitMaxHourController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '时',
                                ),
                                inputFormatters: [integerInputFormatter],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: waitMaxMinuteController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '分',
                                ),
                                inputFormatters: [integerInputFormatter],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: waitMaxSecondController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '秒',
                                ),
                                inputFormatters: [secondsInputFormatter],
                              ),
                            ),
                          ],
                        ),
                      ] else if (initialStep.type ==
                          CustomFlowStepType.coordinateTap) ...[
                        SwitchListTile(
                          value: useBranchDetectedPosition,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('使用上层识图坐标分支命中的中心点'),
                          subtitle: const Text(
                            '开启后会把当前步骤的点击位置改成“识图中心点 + 偏移量”；仅在识图坐标分支子流程中生效。',
                          ),
                          onChanged: (value) {
                            setLocalState(() {
                              useBranchDetectedPosition = value;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        if (!useBranchDetectedPosition) ...[
                          TextField(
                            controller: xController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: 'X 坐标',
                            ),
                            inputFormatters: [signedIntegerInputFormatter],
                          ),
                        ] else ...[
                          TextField(
                            controller: branchPositionOffsetXController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: 'X 偏移',
                              helperText: '实际点击 X = 识图中心点 X + 此偏移',
                            ),
                            inputFormatters: [signedIntegerInputFormatter],
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (!useBranchDetectedPosition) ...[
                          TextField(
                            controller: yController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: 'Y 坐标',
                            ),
                            inputFormatters: [signedIntegerInputFormatter],
                          ),
                        ] else ...[
                          TextField(
                            controller: branchPositionOffsetYController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: 'Y 偏移',
                              helperText: '实际点击 Y = 识图中心点 Y + 此偏移',
                            ),
                            inputFormatters: [signedIntegerInputFormatter],
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: randomOffsetController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '随机点击偏移半径（像素）',
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: postWaitMinController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '点击后最短等待（秒）',
                          ),
                          inputFormatters: [secondsInputFormatter],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: postWaitMaxController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '点击后最长等待（秒）',
                          ),
                          inputFormatters: [secondsInputFormatter],
                        ),
                      ] else if (initialStep.type ==
                          CustomFlowStepType.ocrTap) ...[
                        TextField(
                          controller: ocrTargetTextController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '目标文字',
                            hintText: '例如：确定',
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<CustomFlowOcrMatchMode>(
                          initialValue: selectedOcrMatchMode,
                          decoration: _solidDropdownDecoration('匹配规则'),
                          dropdownColor: LinglongTheme.dropdownSurface,
                          items: CustomFlowOcrMatchMode.values
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(_ocrMatchModeLabel(value)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setLocalState(() {
                              selectedOcrMatchMode = value;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: confidenceController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'OCR 置信度阈值（0-1）',
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^[0-9.]*$'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: maxAttemptsController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '最大重试次数',
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: retryIntervalController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '每次重试间隔（秒）',
                          ),
                          inputFormatters: [secondsInputFormatter],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '识别区域（留空为全屏）',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: ocrRegionLeftController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '左',
                                ),
                                inputFormatters: [integerInputFormatter],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: ocrRegionTopController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '上',
                                ),
                                inputFormatters: [integerInputFormatter],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: ocrRegionRightController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '右',
                                ),
                                inputFormatters: [integerInputFormatter],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: ocrRegionBottomController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '下',
                                ),
                                inputFormatters: [integerInputFormatter],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: ocrMatchIndexController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '点击第几个命中结果',
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: ocrClickOffsetXController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '点击 X 偏移',
                                ),
                                inputFormatters: [signedIntegerInputFormatter],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: ocrClickOffsetYController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: '点击 Y 偏移',
                                ),
                                inputFormatters: [signedIntegerInputFormatter],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: randomOffsetController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '随机点击偏移半径（像素）',
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: postWaitMinController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '点击后最短等待（秒）',
                          ),
                          inputFormatters: [secondsInputFormatter],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: postWaitMaxController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '点击后最长等待（秒）',
                          ),
                          inputFormatters: [secondsInputFormatter],
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          value: continueOnFailure,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('找不到文字时继续后续步骤'),
                          onChanged: (value) {
                            setLocalState(() {
                              continueOnFailure = value;
                            });
                          },
                        ),
                      ] else if (initialStep.type ==
                          CustomFlowStepType.pasteText) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: const Text(
                            '执行前请先用固定坐标点击或识图点击让目标输入框获得焦点。'
                            '本步骤会清空输入框原内容，再通过 ADB Keyboard 输入文字；'
                            '设备未安装时，执行流程会先弹出 APK 安装向导。',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          value: useParentLoopText,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('使用上层文本循环下发的当前文字'),
                          subtitle: const Text(
                            '开启后忽略下方固定文字；仅在“按文本逐行”循环的子流程中生效。',
                          ),
                          onChanged: (value) {
                            setLocalState(() {
                              useParentLoopText = value;
                            });
                          },
                        ),
                        if (!useParentLoopText) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: textContentController,
                            minLines: 3,
                            maxLines: 8,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '要粘贴的固定文字',
                              alignLabelWithHint: true,
                            ),
                          ),
                        ],
                      ] else if (initialStep.type ==
                          CustomFlowStepType.loopBlock) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: Text(
                            _buildLoopBlockUserGuide(),
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<CustomFlowLoopMode>(
                          initialValue: selectedLoopMode,
                          decoration: _solidDropdownDecoration('循环模式'),
                          dropdownColor: LinglongTheme.dropdownSurface,
                          items: CustomFlowLoopMode.values
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(_loopModeLabel(value)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setLocalState(() {
                              selectedLoopMode = value;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: selectedLoopTemplateKey,
                                decoration: _solidDropdownDecoration('循环块模板'),
                                dropdownColor: LinglongTheme.dropdownSurface,
                                items:
                                    const [
                                      'full',
                                      'simple',
                                      'farm',
                                      'wait_then_click',
                                      'branch_loop',
                                    ].map((value) {
                                      return DropdownMenuItem<String>(
                                        value: value,
                                        child: Text(_loopTemplateLabel(value)),
                                      );
                                    }).toList(),
                                onChanged: (value) {
                                  if (value == null) {
                                    return;
                                  }
                                  setLocalState(() {
                                    selectedLoopTemplateKey = value;
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () {
                                final steps = _buildLoopTemplateStepsByKey(
                                  selectedLoopTemplateKey,
                                  resolveLoopTemplateName(),
                                );
                                setLocalState(() {
                                  editableChildren = steps;
                                });
                              },
                              child: const Text('套用模板'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (selectedLoopMode ==
                            CustomFlowLoopMode.fixedCount) ...[
                          TextField(
                            controller: loopCountController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '循环次数（0 为无限）',
                            ),
                          ),
                          const SizedBox(height: 12),
                        ] else if (selectedLoopMode ==
                            CustomFlowLoopMode.imageCondition) ...[
                          DropdownButtonFormField<CustomFlowLoopImageAction>(
                            initialValue: selectedLoopImageAction,
                            decoration: _solidDropdownDecoration('识别后的循环动作'),
                            dropdownColor: LinglongTheme.dropdownSurface,
                            items: CustomFlowLoopImageAction.values
                                .map(
                                  (value) => DropdownMenuItem(
                                    value: value,
                                    child: Text(
                                      _loopImageActionLabel(
                                        value,
                                        recognitionMode:
                                            selectedRecognitionMode,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setLocalState(() {
                                selectedLoopImageAction = value;
                              });
                            },
                          ),
                          const SizedBox(height: 12),
                          buildRecognitionModeDropdown(),
                          const SizedBox(height: 12),
                          if (selectedRecognitionMode ==
                              CustomFlowRecognitionMode.image) ...[
                            buildImagePickerWithPreview(),
                            const SizedBox(height: 12),
                            TextField(
                              controller: confidenceController,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: '识图阈值（0-1）',
                              ),
                              inputFormatters: [secondsInputFormatter],
                            ),
                          ] else ...[
                            ...buildOcrCommonFields(),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            '说明：每轮子步骤执行完成后截图识别一次。命中后是继续还是停止，由上面的“识别后的循环动作”决定。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blueGrey.shade700,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ] else if (selectedLoopMode ==
                            CustomFlowLoopMode.textLines) ...[
                          TextField(
                            controller: loopTextContentController,
                            minLines: 6,
                            maxLines: 14,
                            onChanged: (_) => setLocalState(() {}),
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '循环文字（每行执行一次）',
                              hintText: '第一条文字\n第二条文字\n第三条文字',
                              helperText: '每行会去除首尾空格，空行不会执行。',
                              alignLabelWithHint: true,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '当前有效行数：${splitCustomFlowTextLines(loopTextContentController.text).length}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blueGrey.shade700,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        buildNestedStepToolbar((value) {
                          editableChildren = value;
                        }, editableChildren),
                        const SizedBox(height: 12),
                        buildNestedStepCards(
                          steps: editableChildren,
                          emptyText:
                              '这个循环块还没有子步骤。可以添加等待、识图点击、固定坐标点击、粘贴文字、识图等待、多图条件分支、识图坐标分支、循环块等。',
                          onChanged: (value) {
                            editableChildren = value;
                          },
                          groupTag: 'LOOP',
                        ),
                      ] else if (initialStep.type ==
                          CustomFlowStepType.flowGroup) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: const Text(
                            '流程组会把一段拼接进来的流程当成一个整体来执行。你可以把它整体拖拽、复制、删除，也可以在这里继续编辑组内步骤。',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        buildNestedStepToolbar((value) {
                          editableChildren = value;
                        }, editableChildren),
                        const SizedBox(height: 12),
                        buildNestedStepCards(
                          steps: editableChildren,
                          emptyText:
                              '这个流程组还没有子步骤。可以添加等待、识图点击、固定坐标点击、粘贴文字、识图等待、多图条件分支、识图坐标分支、循环块等。',
                          onChanged: (value) {
                            editableChildren = value;
                          },
                          groupTag: 'GROUP',
                        ),
                      ] else if (initialStep.type ==
                          CustomFlowStepType.gameMode) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: const Text(
                            '这个步骤会在自定义流程中同步执行一个痒痒鼠模式，并在该模式执行完成后继续后续步骤。\n'
                            '目标模拟器由上方“选择要操作的模拟器对象”统一决定。',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: selectedGameModeName,
                          decoration: _solidDropdownDecoration('痒痒鼠模式'),
                          dropdownColor: LinglongTheme.dropdownSurface,
                          items: _availableGameModeNames
                              .map(
                                (value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(_gameModeLabel(value)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setLocalState(() {
                              selectedGameModeName = value;
                              applyGameModeConfigSnapshot(
                                _buildCurrentGameModeConfigSnapshot(value),
                              );
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: gameModeRunTimesController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '战斗次数（0 为不设置）',
                          ),
                          inputFormatters: [integerInputFormatter],
                          enabled: selectedGameModeName != 'tu_po',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: gameModePicCtrlController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '识图阈值',
                          ),
                          inputFormatters: [secondsInputFormatter],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: gameModeBattleTimeController,
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            labelText: selectedGameModeName == 'tu_po'
                                ? '单次突破最短时间'
                                : selectedGameModeName == 'PK_mode'
                                ? '多少秒后自动认输时间'
                                : '单次战斗时间',
                          ),
                          inputFormatters: [secondsInputFormatter],
                          enabled:
                              selectedGameModeName != 'bai_gui' &&
                              selectedGameModeName != 'daoguan',
                        ),
                        if (selectedGameModeName == 'tu_po') ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: gameModeTupoOutTimeController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '打九退4或3',
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^[3-4]*$'),
                              ),
                            ],
                          ),
                        ],
                        if (selectedGameModeName == 'kun28_double' ||
                            selectedGameModeName == 'kun28_single') ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: gameModeBattleTimeAddController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '设备卡顿时间偏移',
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^-?[0-9.]*$'),
                              ),
                            ],
                          ),
                        ],
                        if (selectedGameModeName == 'single_mode') ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: gameModeBottomController,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: 'Bottom',
                                  ),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(
                                      RegExp(r'^-?[0-9.]*$'),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: gameModeRightController,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: 'Right',
                                  ),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(
                                      RegExp(r'^-?[0-9.]*$'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('是否在测试服'),
                          value: gameModeIsTestUser,
                          onChanged: (value) {
                            setLocalState(() {
                              gameModeIsTestUser = value;
                            });
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('是否开启校验'),
                          value: gameModeNeedCheck,
                          onChanged: (value) {
                            setLocalState(() {
                              gameModeNeedCheck = value;
                            });
                          },
                        ),
                        if (selectedGameModeName == 'qi_lin_double' ||
                            (selectedGameModeName == 'kun28_double' &&
                                gameModeIsLoopToTupoSwitchOn)) ...[
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('是否跨区'),
                            value: gameModeIsKuaQuSwitchOn,
                            onChanged: (value) {
                              setLocalState(() {
                                gameModeIsKuaQuSwitchOn = value;
                              });
                            },
                          ),
                        ],
                        if (selectedGameModeName == 'kun28_double' ||
                            selectedGameModeName == 'kun28_single') ...[
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('是否困1'),
                            value: gameModeIsKun1SwitchOn,
                            onChanged: (value) {
                              setLocalState(() {
                                gameModeIsKun1SwitchOn = value;
                              });
                            },
                          ),
                        ],
                        if (selectedGameModeName == 'double_mode' ||
                            selectedGameModeName == 'ye_huo_yuan' ||
                            selectedGameModeName == 'kun28_double' ||
                            selectedGameModeName == 'kun28_single') ...[
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('是否自动结界突破'),
                            value: gameModeIsLoopToTupoSwitchOn,
                            onChanged: (value) {
                              setLocalState(() {
                                gameModeIsLoopToTupoSwitchOn = value;
                              });
                            },
                          ),
                          if (gameModeIsLoopToTupoSwitchOn) ...[
                            if (selectedGameModeName == 'kun28_double' ||
                                selectedGameModeName == 'double_mode') ...[
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('队长自动'),
                                value: gameModeIsLoopToTupoSwitchOn1,
                                onChanged: (value) {
                                  setLocalState(() {
                                    gameModeIsLoopToTupoSwitchOn1 = value;
                                  });
                                },
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('队员1自动'),
                                value: gameModeIsLoopToTupoSwitchOn2,
                                onChanged: (value) {
                                  setLocalState(() {
                                    gameModeIsLoopToTupoSwitchOn2 = value;
                                  });
                                },
                              ),
                              if (selectedGameModeName == 'double_mode')
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('队员2自动'),
                                  value: gameModeIsLoopToTupoSwitchOn4,
                                  onChanged: (value) {
                                    setLocalState(() {
                                      gameModeIsLoopToTupoSwitchOn4 = value;
                                    });
                                  },
                                ),
                            ],
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('是否自动切换阵容'),
                              value: gameModeIsLoopToTupoSwitchOn3,
                              onChanged: (value) {
                                setLocalState(() {
                                  gameModeIsLoopToTupoSwitchOn3 = value;
                                });
                              },
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('是否打完第一轮立马去突破'),
                              value: gameModeIsFirstDoneTupo,
                              onChanged: (value) {
                                setLocalState(() {
                                  gameModeIsFirstDoneTupo = value;
                                });
                              },
                            ),
                          ],
                        ],
                      ] else if (initialStep.type ==
                          CustomFlowStepType.recordedFlow) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: const Text(
                            '这个步骤会在自定义流程里同步回放一个已保存的手势录制流程。适合拼接复杂拖拽、长按、滑动等手势操作。',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: selectedRecordedFlowName.isEmpty
                              ? null
                              : selectedRecordedFlowName,
                          decoration: _solidDropdownDecoration('已保存录制流程'),
                          dropdownColor: LinglongTheme.dropdownSurface,
                          items: recordedFlowOptions
                              .map(
                                (value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            setLocalState(() {
                              selectedRecordedFlowName = value ?? '';
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: recordedFlowLoopCountController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '回放次数',
                            hintText: '0 为无限循环',
                          ),
                          inputFormatters: [integerInputFormatter],
                        ),
                        if (_savedFlows.isEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            '当前还没有已保存的录制流程，请先到“流程录制与回放”里录制或导入一个。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blueGrey.shade700,
                            ),
                          ),
                        ],
                      ] else if (initialStep.type ==
                              CustomFlowStepType.imageBranch ||
                          initialStep.type ==
                              CustomFlowStepType.imagePositionBranch) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: Text(
                            initialStep.type ==
                                    CustomFlowStepType.imagePositionBranch
                                ? _buildImagePositionBranchUserGuide()
                                : _buildImageBranchUserGuide(),
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          value: reuseParentBranchScreenshot,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('复用上级分支截图'),
                          subtitle: const Text(
                            '开启后会优先复用最近上级分支节点的截图；没有上级截图时，本节点只截图一次并供当前分支所有条件复用。',
                          ),
                          onChanged: (value) {
                            setLocalState(() {
                              reuseParentBranchScreenshot = value;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        if (initialStep.type ==
                            CustomFlowStepType.imagePositionBranch) ...[
                          buildRecognitionModeDropdown(),
                          const SizedBox(height: 12),
                          if (selectedRecognitionMode ==
                              CustomFlowRecognitionMode.image) ...[
                            buildImagePickerWithPreview(),
                            const SizedBox(height: 12),
                            TextField(
                              controller: confidenceController,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: '识图阈值（0-1）',
                              ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'^[0-9.]*$'),
                                ),
                              ],
                            ),
                          ] else ...[
                            ...buildOcrCommonFields(includeMatchIndex: true),
                          ],
                          const SizedBox(height: 12),
                        ],
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ElevatedButton(
                              onPressed: () async {
                                final branchCaseId = _newCustomFlowId();
                                final isPositionBranch =
                                    initialStep.type ==
                                    CustomFlowStepType.imagePositionBranch;
                                final defaultImage = CustomFlowBranchImage(
                                  id: branchCaseId,
                                  templateName: _safeDefaultTemplateName(),
                                  imageSource: CustomFlowImageSource.localFile,
                                );
                                final created = CustomFlowBranchCase(
                                  id: branchCaseId,
                                  label: editableBranchCases.isEmpty
                                      ? 'IF 条件'
                                      : 'ELSE IF 条件',
                                  templateName: isPositionBranch
                                      ? ''
                                      : defaultImage.templateName,
                                  imageSource: CustomFlowImageSource.localFile,
                                  templateImages: isPositionBranch
                                      ? const []
                                      : [defaultImage],
                                  confidence: isPositionBranch
                                      ? 0.68
                                      : _defaultBranchCaseConfidence(),
                                );
                                final updated = await _showBranchCaseEditor(
                                  initialCase: created,
                                  usePositionCondition:
                                      initialStep.type ==
                                      CustomFlowStepType.imagePositionBranch,
                                );
                                if (updated == null) {
                                  return;
                                }
                                setLocalState(() {
                                  editableBranchCases = [
                                    ...editableBranchCases,
                                    updated,
                                  ];
                                });
                              },
                              child: const Text('添加条件分支'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (editableBranchCases.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.blueGrey.shade100,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.grey.shade50,
                            ),
                            child: const Text(
                              '还没有 if / else if 分支。点击“添加条件分支”开始配置。',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Colors.blueGrey,
                              ),
                            ),
                          )
                        else
                          ReorderableListView.builder(
                            shrinkWrap: true,
                            buildDefaultDragHandles: false,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: editableBranchCases.length,
                            onReorder: (oldIndex, newIndex) {
                              setLocalState(() {
                                editableBranchCases = _reorderItems(
                                  editableBranchCases,
                                  oldIndex,
                                  newIndex,
                                );
                              });
                            },
                            itemBuilder: (context, index) {
                              final branchCase = editableBranchCases[index];
                              final tag = index == 0 ? 'IF' : 'ELSE IF';
                              return Card(
                                key: ValueKey(
                                  'branch-case-${branchCase.id}-$index',
                                ),
                                margin: const EdgeInsets.symmetric(vertical: 6),
                                child: ListTile(
                                  leading: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: const Icon(Icons.drag_handle),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.shade50,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Text(
                                          tag,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.orange.shade800,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  title: Text(
                                    branchCase.label.trim().isEmpty
                                        ? '$tag 条件'
                                        : branchCase.label.trim(),
                                  ),
                                  subtitle: Text(
                                    initialStep.type ==
                                            CustomFlowStepType
                                                .imagePositionBranch
                                        ? '${_buildPositionConditionSummary(branchCase)}，步骤数: ${branchCase.steps.length}'
                                        : '${_buildBranchImageDescriptor(branchCase)}，阈值: ${branchCase.confidence.toStringAsFixed(2)}，步骤数: ${branchCase.steps.length}',
                                  ),
                                  trailing: Wrap(
                                    spacing: 4,
                                    children: [
                                      IconButton(
                                        tooltip: '上移',
                                        onPressed: index == 0
                                            ? null
                                            : () => setLocalState(() {
                                                editableBranchCases =
                                                    _moveItemInList(
                                                      editableBranchCases,
                                                      index,
                                                      -1,
                                                    );
                                              }),
                                        icon: const Icon(
                                          Icons.keyboard_arrow_up,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '下移',
                                        onPressed:
                                            index ==
                                                editableBranchCases.length - 1
                                            ? null
                                            : () => setLocalState(() {
                                                editableBranchCases =
                                                    _moveItemInList(
                                                      editableBranchCases,
                                                      index,
                                                      1,
                                                    );
                                              }),
                                        icon: const Icon(
                                          Icons.keyboard_arrow_down,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '编辑',
                                        onPressed: () async {
                                          final updated =
                                              await _showBranchCaseEditor(
                                                initialCase: branchCase,
                                                usePositionCondition:
                                                    initialStep.type ==
                                                    CustomFlowStepType
                                                        .imagePositionBranch,
                                              );
                                          if (updated == null) {
                                            return;
                                          }
                                          setLocalState(() {
                                            final cases =
                                                List<CustomFlowBranchCase>.from(
                                                  editableBranchCases,
                                                );
                                            cases[index] = updated;
                                            editableBranchCases = cases;
                                          });
                                        },
                                        icon: const Icon(Icons.edit_outlined),
                                      ),
                                      IconButton(
                                        tooltip: '删除',
                                        onPressed: () => setLocalState(() {
                                          final cases =
                                              List<CustomFlowBranchCase>.from(
                                                editableBranchCases,
                                              )..removeAt(index);
                                          editableBranchCases = cases;
                                        }),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.teal.shade50,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  'ELSE',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.teal.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '未命中任何分支时执行的默认步骤',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    buildNestedStepToolbar((value) {
                                      editableFallbackChildren = value;
                                    }, editableFallbackChildren),
                                    const SizedBox(height: 10),
                                    buildNestedStepCards(
                                      steps: editableFallbackChildren,
                                      emptyText:
                                          '默认分支为空。可以添加等待、识图点击、固定坐标点击、粘贴文字、识图等待、多图条件分支、识图坐标分支、循环块等；所有条件都不命中时会直接跳过。',
                                      onChanged: (value) {
                                        editableFallbackChildren = value;
                                      },
                                      groupTag: 'ELSE',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else if (initialStep.type ==
                          CustomFlowStepType.restartActivity) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          //留空时运行步骤时也会现场读取当前前台 Activity 后再执行 `am start -W -S -n`。
                          child: const Text(
                            '可以直接填写要重启的 Activity 组件名(也就是页面)；也可以点击右侧按钮读取当前设备的页面，直接重启到当前页面。\n'
                            '这个功能主要是用来跳转登录页的，比如不管当前游戏是关闭还是在战斗，直接跳到登录页后执行寄养操作',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: activityComponentController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'Activity 组件名',
                                  hintText:
                                      '例如 com.android.documentsui/.files.FilesActivity；留空则运行时自动读取当前前台 Activity',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: isFetchingActivityComponent
                                  ? null
                                  : () async {
                                      final deviceId = _getSingleTargetDevice();
                                      if (deviceId == null) {
                                        if (!context.mounted) {
                                          return;
                                        }
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              '请先只保留一个目标设备，再读取当前 Activity。',
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      setLocalState(() {
                                        isFetchingActivityComponent = true;
                                      });
                                      try {
                                        final component =
                                            await _fetchCurrentActivityComponent(
                                              deviceId,
                                            );
                                        if (!context.mounted) {
                                          return;
                                        }
                                        setLocalState(() {
                                          activityComponentController.text =
                                              component;
                                          activityComponentController
                                                  .selection =
                                              TextSelection.collapsed(
                                                offset: component.length,
                                              );
                                        });
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              '已读取当前 Activity：$component',
                                            ),
                                          ),
                                        );
                                      } catch (e) {
                                        if (!context.mounted) {
                                          return;
                                        }
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(content: Text('读取失败：$e')),
                                        );
                                      } finally {
                                        if (context.mounted) {
                                          setLocalState(() {
                                            isFetchingActivityComponent = false;
                                          });
                                        }
                                      }
                                    },
                              icon: isFetchingActivityComponent
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.sync_alt),
                              label: Text(
                                isFetchingActivityComponent
                                    ? '读取中'
                                    : '获取当前Activity',
                              ),
                            ),
                          ],
                        ),
                      ] else if (initialStep.type ==
                          CustomFlowStepType.shutdownComputer) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueGrey.shade100),
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey.shade50,
                          ),
                          child: Text(
                            Platform.isWindows
                                ? '执行到这个步骤时，会按你设置的延迟时间为当前 Windows 电脑创建关机任务。'
                                : Platform.isMacOS
                                ? '执行到这个步骤时，会为当前 macOS 电脑创建一个延迟关机后台任务。'
                                : '当前平台暂不支持关机操作。',
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Colors.blueGrey,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: shutdownDelayController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: '关机延迟（秒）',
                            hintText: '0 为立即关机',
                          ),
                          inputFormatters: [secondsInputFormatter],
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ElevatedButton(
                            onPressed: (Platform.isWindows || Platform.isMacOS)
                                ? () async {
                                    try {
                                      final message =
                                          await _cancelCustomFlowShutdownTask();
                                      if (!context.mounted) {
                                        return;
                                      }
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text(message)),
                                      );
                                    } catch (e) {
                                      if (!context.mounted) {
                                        return;
                                      }
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text('取消失败：$e')),
                                      );
                                    }
                                  }
                                : null,
                            child: const Text('取消当前关机任务'),
                          ),
                        ),
                      ] else ...[
                        buildRecognitionModeDropdown(),
                        const SizedBox(height: 12),
                        if (selectedRecognitionMode ==
                            CustomFlowRecognitionMode.image) ...[
                          buildImagePickerWithPreview(),
                          const SizedBox(height: 12),
                          TextField(
                            controller: confidenceController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '识图阈值（0-1）',
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^[0-9.]*$'),
                              ),
                            ],
                          ),
                        ] else ...[
                          ...buildOcrCommonFields(
                            includeMatchIndex:
                                initialStep.type == CustomFlowStepType.imageTap,
                            includeClickOffset:
                                initialStep.type == CustomFlowStepType.imageTap,
                          ),
                        ],
                        if (initialStep.type ==
                            CustomFlowStepType.imageTap) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: maxAttemptsController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '最大重试次数',
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: retryIntervalController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '每次重试间隔（秒）',
                            ),
                            inputFormatters: [secondsInputFormatter],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: randomOffsetController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '随机点击偏移半径（像素）',
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: postWaitMinController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '点击后最短等待（秒）',
                            ),
                            inputFormatters: [secondsInputFormatter],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: postWaitMaxController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '点击后最长等待（秒）',
                            ),
                            inputFormatters: [secondsInputFormatter],
                          ),
                        ] else ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<CustomFlowWaitTargetState>(
                            initialValue: selectedWaitState,
                            decoration: _solidDropdownDecoration('等待目标'),
                            dropdownColor: LinglongTheme.dropdownSurface,
                            items: CustomFlowWaitTargetState.values
                                .map(
                                  (value) => DropdownMenuItem(
                                    value: value,
                                    child: Text(
                                      value == CustomFlowWaitTargetState.appear
                                          ? '直到出现'
                                          : '直到消失',
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setLocalState(() {
                                selectedWaitState = value;
                              });
                            },
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: timeoutController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '超时时间（秒，0 为无限）',
                            ),
                            inputFormatters: [secondsInputFormatter],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: pollIntervalController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '轮询间隔（秒）',
                            ),
                            inputFormatters: [secondsInputFormatter],
                          ),
                        ],
                        const SizedBox(height: 12),
                        SwitchListTile(
                          value: continueOnFailure,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            initialStep.type == CustomFlowStepType.imageTap
                                ? '找不到图片时继续后续步骤'
                                : '超时后继续后续步骤',
                          ),
                          onChanged: (value) {
                            setLocalState(() {
                              continueOnFailure = value;
                            });
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消', style: TextStyle(color: Colors.blue)),
                ),
                FilledButton(
                  onPressed: () {
                    try {
                      final label = labelController.text.trim();
                      if (initialStep.type == CustomFlowStepType.wait) {
                        final waitMin = _parseDurationPartsToSeconds(
                          hoursText: waitMinHourController.text,
                          minutesText: waitMinMinuteController.text,
                          secondsText: waitMinSecondController.text,
                          fallback: 0,
                        );
                        final waitMax = _parseDurationPartsToSeconds(
                          hoursText: waitMaxHourController.text,
                          minutesText: waitMaxMinuteController.text,
                          secondsText: waitMaxSecondController.text,
                          fallback: waitMin,
                        );
                        final updatedStep = initialStep.copyWith(
                          label: label,
                          waitMinSeconds: min(waitMin, waitMax),
                          waitMaxSeconds: max(waitMin, waitMax),
                        );
                        _saveCustomFlowNumericDefaultsForStep(updatedStep);
                        confirmStep(updatedStep);
                      } else if (initialStep.type ==
                          CustomFlowStepType.coordinateTap) {
                        final postWaitMin = _parseSeconds(
                          postWaitMinController.text,
                          fallback: 0.8,
                        );
                        final postWaitMax = _parseSeconds(
                          postWaitMaxController.text,
                          fallback: postWaitMin,
                        );
                        final updatedStep = initialStep.copyWith(
                          label: label,
                          x: int.tryParse(xController.text.trim()) ?? 0,
                          y: int.tryParse(yController.text.trim()) ?? 0,
                          useBranchDetectedPosition: useBranchDetectedPosition,
                          branchPositionOffsetX:
                              int.tryParse(
                                branchPositionOffsetXController.text.trim(),
                              ) ??
                              0,
                          branchPositionOffsetY:
                              int.tryParse(
                                branchPositionOffsetYController.text.trim(),
                              ) ??
                              0,
                          randomOffsetPx:
                              int.tryParse(
                                randomOffsetController.text.trim(),
                              ) ??
                              5,
                          postWaitMinSeconds: min(postWaitMin, postWaitMax),
                          postWaitMaxSeconds: max(postWaitMin, postWaitMax),
                        );
                        _saveCustomFlowNumericDefaultsForStep(updatedStep);
                        confirmStep(updatedStep);
                      } else if (initialStep.type ==
                          CustomFlowStepType.ocrTap) {
                        final targetText = ocrTargetTextController.text.trim();
                        if (targetText.isEmpty) {
                          throw Exception('识图点击的文字识别模式需要填写目标文字');
                        }
                        final regionTexts = [
                          ocrRegionLeftController.text.trim(),
                          ocrRegionTopController.text.trim(),
                          ocrRegionRightController.text.trim(),
                          ocrRegionBottomController.text.trim(),
                        ];
                        final hasAnyRegion = regionTexts.any(
                          (item) => item.isNotEmpty,
                        );
                        final hasFullRegion = regionTexts.every(
                          (item) => item.isNotEmpty,
                        );
                        int regionLeft = -1;
                        int regionTop = -1;
                        int regionRight = -1;
                        int regionBottom = -1;
                        if (hasAnyRegion) {
                          if (!hasFullRegion) {
                            throw Exception('识别区域需要同时填写左、上、右、下四个坐标，或全部留空');
                          }
                          regionLeft = int.tryParse(regionTexts[0]) ?? -1;
                          regionTop = int.tryParse(regionTexts[1]) ?? -1;
                          regionRight = int.tryParse(regionTexts[2]) ?? -1;
                          regionBottom = int.tryParse(regionTexts[3]) ?? -1;
                          if (regionLeft < 0 ||
                              regionTop < 0 ||
                              regionRight <= regionLeft ||
                              regionBottom <= regionTop) {
                            throw Exception('识别区域必须满足：右 > 左，且下 > 上');
                          }
                        }
                        final postWaitMin = _parseSeconds(
                          postWaitMinController.text,
                          fallback: 0.8,
                        );
                        final postWaitMax = _parseSeconds(
                          postWaitMaxController.text,
                          fallback: postWaitMin,
                        );
                        final updatedStep = initialStep.copyWith(
                          label: label,
                          ocrTargetText: targetText,
                          ocrMatchMode: selectedOcrMatchMode,
                          confidence:
                              (double.tryParse(
                                        confidenceController.text.trim(),
                                      ) ??
                                      0.50)
                                  .clamp(0.01, 0.99)
                                  .toDouble(),
                          maxAttempts:
                              int.tryParse(maxAttemptsController.text.trim()) ??
                              3,
                          retryIntervalSeconds: _parseSeconds(
                            retryIntervalController.text,
                            fallback: 1.2,
                          ),
                          ocrRegionLeft: regionLeft,
                          ocrRegionTop: regionTop,
                          ocrRegionRight: regionRight,
                          ocrRegionBottom: regionBottom,
                          ocrMatchIndex: max(
                            int.tryParse(ocrMatchIndexController.text.trim()) ??
                                1,
                            1,
                          ),
                          ocrClickOffsetX:
                              int.tryParse(
                                ocrClickOffsetXController.text.trim(),
                              ) ??
                              0,
                          ocrClickOffsetY:
                              int.tryParse(
                                ocrClickOffsetYController.text.trim(),
                              ) ??
                              0,
                          randomOffsetPx:
                              int.tryParse(
                                randomOffsetController.text.trim(),
                              ) ??
                              1,
                          postWaitMinSeconds: min(postWaitMin, postWaitMax),
                          postWaitMaxSeconds: max(postWaitMin, postWaitMax),
                          continueOnFailure: continueOnFailure,
                        );
                        _saveCustomFlowNumericDefaultsForStep(updatedStep);
                        confirmStep(updatedStep);
                      } else if (initialStep.type ==
                          CustomFlowStepType.pasteText) {
                        confirmStep(
                          initialStep.copyWith(
                            label: label,
                            textContent: textContentController.text,
                            useParentLoopText: useParentLoopText,
                          ),
                        );
                      } else if (initialStep.type ==
                          CustomFlowStepType.loopBlock) {
                        final loopTextContent = loopTextContentController.text;
                        if (selectedLoopMode == CustomFlowLoopMode.textLines &&
                            splitCustomFlowTextLines(loopTextContent).isEmpty) {
                          throw Exception('按文本逐行循环至少需要一行有效文字');
                        }
                        final usesTextRecognition =
                            selectedLoopMode ==
                                CustomFlowLoopMode.imageCondition &&
                            selectedRecognitionMode ==
                                CustomFlowRecognitionMode.text;
                        final targetText = ocrTargetTextController.text.trim();
                        if (usesTextRecognition && targetText.isEmpty) {
                          throw Exception('文字识别需要填写目标文字');
                        }
                        final ocrRegion = usesTextRecognition
                            ? parseOcrRegion()
                            : (
                                left: initialStep.ocrRegionLeft,
                                top: initialStep.ocrRegionTop,
                                right: initialStep.ocrRegionRight,
                                bottom: initialStep.ocrRegionBottom,
                              );
                        final updatedStep = initialStep.copyWith(
                          label: label,
                          loopMode: selectedLoopMode,
                          recognitionMode: selectedRecognitionMode,
                          loopImageAction: selectedLoopImageAction,
                          loopCount:
                              int.tryParse(loopCountController.text.trim()) ??
                              1,
                          templateName: selectedTemplate.trim(),
                          imageSource: selectedImageSource,
                          templatePath: selectedTemplatePath.trim(),
                          confidence:
                              double.tryParse(confidenceController.text) ??
                              initialStep.confidence,
                          ocrTargetText: usesTextRecognition
                              ? targetText
                              : initialStep.ocrTargetText,
                          ocrMatchMode: selectedOcrMatchMode,
                          ocrRegionLeft: ocrRegion.left,
                          ocrRegionTop: ocrRegion.top,
                          ocrRegionRight: ocrRegion.right,
                          ocrRegionBottom: ocrRegion.bottom,
                          loopTextContent: loopTextContent,
                          children: editableChildren,
                        );
                        _saveCustomFlowNumericDefaultsForStep(updatedStep);
                        confirmStep(updatedStep);
                      } else if (initialStep.type ==
                          CustomFlowStepType.flowGroup) {
                        confirmStep(
                          initialStep.copyWith(
                            label: label,
                            children: editableChildren,
                          ),
                        );
                      } else if (initialStep.type ==
                          CustomFlowStepType.gameMode) {
                        final config = {
                          'mode': selectedGameModeName,
                          'battleTime': setDefault(
                            gameModeBattleTimeController.text.trim(),
                            '0',
                          ),
                          'bottom': setDefault(
                            gameModeBottomController.text.trim(),
                            '-1',
                          ),
                          'right': setDefault(
                            gameModeRightController.text.trim(),
                            '-1',
                          ),
                          'runTimes': setDefault(
                            gameModeRunTimesController.text.trim(),
                            '0',
                          ),
                          'battleTimeAdd': setDefault(
                            gameModeBattleTimeAddController.text.trim(),
                            '0',
                          ),
                          'picCtrl': setDefault(
                            gameModePicCtrlController.text.trim(),
                            '0.68',
                          ),
                          'tupoOutTime': setDefault(
                            gameModeTupoOutTimeController.text.trim(),
                            '4',
                          ),
                          'isDebug': _isDebug,
                          'isKuaQuSwitchOn': gameModeIsKuaQuSwitchOn,
                          'isKun1SwitchOn': gameModeIsKun1SwitchOn,
                          'isLoopToTupoSwitchOn': gameModeIsLoopToTupoSwitchOn,
                          'isLoopToTupoSwitchOn1':
                              gameModeIsLoopToTupoSwitchOn1,
                          'isLoopToTupoSwitchOn2':
                              gameModeIsLoopToTupoSwitchOn2,
                          'isLoopToTupoSwitchOn3':
                              gameModeIsLoopToTupoSwitchOn3,
                          'isLoopToTupoSwitchOn4':
                              gameModeIsLoopToTupoSwitchOn4,
                          'isTestUser': gameModeIsTestUser,
                          'needCheck': gameModeNeedCheck,
                          'isFirstDoneTupo': gameModeIsFirstDoneTupo,
                        };
                        confirmStep(
                          initialStep.copyWith(
                            label: label,
                            gameModeName: selectedGameModeName,
                            gameModeConfigJson: jsonEncode(config),
                            gameModeDeviceIds: const [],
                          ),
                        );
                      } else if (initialStep.type ==
                          CustomFlowStepType.recordedFlow) {
                        if (selectedRecordedFlowName.trim().isEmpty) {
                          throw Exception('请先选择一个已保存的录制流程');
                        }
                        confirmStep(
                          initialStep.copyWith(
                            label: label,
                            recordedFlowName: selectedRecordedFlowName.trim(),
                            recordedFlowLoopCount:
                                int.tryParse(
                                  recordedFlowLoopCountController.text.trim(),
                                ) ??
                                1,
                          ),
                        );
                      } else if (initialStep.type ==
                              CustomFlowStepType.imageBranch ||
                          initialStep.type ==
                              CustomFlowStepType.imagePositionBranch) {
                        final isPositionBranch =
                            initialStep.type ==
                            CustomFlowStepType.imagePositionBranch;
                        final usesTextRecognition =
                            isPositionBranch &&
                            selectedRecognitionMode ==
                                CustomFlowRecognitionMode.text;
                        final targetText = ocrTargetTextController.text.trim();
                        if (usesTextRecognition && targetText.isEmpty) {
                          throw Exception('文字识别需要填写目标文字');
                        }
                        final ocrRegion = usesTextRecognition
                            ? parseOcrRegion()
                            : (
                                left: initialStep.ocrRegionLeft,
                                top: initialStep.ocrRegionTop,
                                right: initialStep.ocrRegionRight,
                                bottom: initialStep.ocrRegionBottom,
                              );
                        final updatedStep = initialStep.copyWith(
                          label: label,
                          recognitionMode: isPositionBranch
                              ? selectedRecognitionMode
                              : initialStep.recognitionMode,
                          templateName: isPositionBranch
                              ? selectedTemplate.trim()
                              : initialStep.templateName,
                          imageSource: isPositionBranch
                              ? selectedImageSource
                              : initialStep.imageSource,
                          templatePath: isPositionBranch
                              ? selectedTemplatePath.trim()
                              : initialStep.templatePath,
                          confidence: isPositionBranch
                              ? (double.tryParse(
                                          confidenceController.text.trim(),
                                        ) ??
                                        0.68)
                                    .clamp(0.01, 0.99)
                                    .toDouble()
                              : initialStep.confidence,
                          ocrTargetText: usesTextRecognition
                              ? targetText
                              : initialStep.ocrTargetText,
                          ocrMatchMode: selectedOcrMatchMode,
                          ocrRegionLeft: ocrRegion.left,
                          ocrRegionTop: ocrRegion.top,
                          ocrRegionRight: ocrRegion.right,
                          ocrRegionBottom: ocrRegion.bottom,
                          ocrMatchIndex: max(
                            int.tryParse(ocrMatchIndexController.text.trim()) ??
                                1,
                            1,
                          ),
                          reuseParentBranchScreenshot:
                              reuseParentBranchScreenshot,
                          branchCases: editableBranchCases,
                          fallbackChildren: editableFallbackChildren,
                        );
                        _saveCustomFlowNumericDefaultsForStep(updatedStep);
                        confirmStep(updatedStep);
                      } else if (initialStep.type ==
                          CustomFlowStepType.restartActivity) {
                        confirmStep(
                          initialStep.copyWith(
                            label: label,
                            activityComponent: activityComponentController.text
                                .trim(),
                          ),
                        );
                      } else if (initialStep.type ==
                          CustomFlowStepType.shutdownComputer) {
                        final updatedStep = initialStep.copyWith(
                          label: label,
                          shutdownDelaySeconds: _parseSeconds(
                            shutdownDelayController.text,
                            fallback: 60,
                          ),
                        );
                        _saveCustomFlowNumericDefaultsForStep(updatedStep);
                        confirmStep(updatedStep);
                      } else if (initialStep.type ==
                          CustomFlowStepType.imageTap) {
                        final isTextRecognition =
                            selectedRecognitionMode ==
                            CustomFlowRecognitionMode.text;
                        final targetText = ocrTargetTextController.text.trim();
                        if (isTextRecognition && targetText.isEmpty) {
                          throw Exception('文字识别需要填写目标文字');
                        }
                        final ocrRegion = isTextRecognition
                            ? parseOcrRegion()
                            : (
                                left: initialStep.ocrRegionLeft,
                                top: initialStep.ocrRegionTop,
                                right: initialStep.ocrRegionRight,
                                bottom: initialStep.ocrRegionBottom,
                              );
                        final postWaitMin = _parseSeconds(
                          postWaitMinController.text,
                          fallback: 0.8,
                        );
                        final postWaitMax = _parseSeconds(
                          postWaitMaxController.text,
                          fallback: postWaitMin,
                        );
                        final updatedStep = initialStep.copyWith(
                          label: label,
                          recognitionMode: selectedRecognitionMode,
                          templateName: selectedTemplate.trim(),
                          imageSource: selectedImageSource,
                          templatePath: selectedTemplatePath.trim(),
                          confidence:
                              (double.tryParse(
                                        confidenceController.text.trim(),
                                      ) ??
                                      0.68)
                                  .clamp(0.01, 0.99)
                                  .toDouble(),
                          maxAttempts:
                              int.tryParse(maxAttemptsController.text.trim()) ??
                              3,
                          retryIntervalSeconds: _parseSeconds(
                            retryIntervalController.text,
                            fallback: 1.2,
                          ),
                          ocrTargetText: isTextRecognition
                              ? targetText
                              : initialStep.ocrTargetText,
                          ocrMatchMode: selectedOcrMatchMode,
                          ocrRegionLeft: ocrRegion.left,
                          ocrRegionTop: ocrRegion.top,
                          ocrRegionRight: ocrRegion.right,
                          ocrRegionBottom: ocrRegion.bottom,
                          ocrMatchIndex: max(
                            int.tryParse(ocrMatchIndexController.text.trim()) ??
                                1,
                            1,
                          ),
                          ocrClickOffsetX:
                              int.tryParse(
                                ocrClickOffsetXController.text.trim(),
                              ) ??
                              0,
                          ocrClickOffsetY:
                              int.tryParse(
                                ocrClickOffsetYController.text.trim(),
                              ) ??
                              0,
                          randomOffsetPx:
                              int.tryParse(
                                randomOffsetController.text.trim(),
                              ) ??
                              1,
                          postWaitMinSeconds: min(postWaitMin, postWaitMax),
                          postWaitMaxSeconds: max(postWaitMin, postWaitMax),
                          continueOnFailure: continueOnFailure,
                        );
                        _saveCustomFlowNumericDefaultsForStep(updatedStep);
                        confirmStep(updatedStep);
                      } else {
                        final isTextRecognition =
                            selectedRecognitionMode ==
                            CustomFlowRecognitionMode.text;
                        final targetText = ocrTargetTextController.text.trim();
                        if (isTextRecognition && targetText.isEmpty) {
                          throw Exception('文字识别需要填写目标文字');
                        }
                        final ocrRegion = isTextRecognition
                            ? parseOcrRegion()
                            : (
                                left: initialStep.ocrRegionLeft,
                                top: initialStep.ocrRegionTop,
                                right: initialStep.ocrRegionRight,
                                bottom: initialStep.ocrRegionBottom,
                              );
                        final updatedStep = initialStep.copyWith(
                          label: label,
                          recognitionMode: selectedRecognitionMode,
                          templateName: selectedTemplate.trim(),
                          imageSource: selectedImageSource,
                          templatePath: selectedTemplatePath.trim(),
                          confidence:
                              (double.tryParse(
                                        confidenceController.text.trim(),
                                      ) ??
                                      0.68)
                                  .clamp(0.01, 0.99)
                                  .toDouble(),
                          waitTargetState: selectedWaitState,
                          timeoutSeconds: _parseSeconds(
                            timeoutController.text,
                            fallback: 30,
                          ),
                          pollIntervalSeconds: _parseSeconds(
                            pollIntervalController.text,
                            fallback: 1.2,
                          ),
                          ocrTargetText: isTextRecognition
                              ? targetText
                              : initialStep.ocrTargetText,
                          ocrMatchMode: selectedOcrMatchMode,
                          ocrRegionLeft: ocrRegion.left,
                          ocrRegionTop: ocrRegion.top,
                          ocrRegionRight: ocrRegion.right,
                          ocrRegionBottom: ocrRegion.bottom,
                          continueOnFailure: continueOnFailure,
                        );
                        _saveCustomFlowNumericDefaultsForStep(updatedStep);
                        confirmStep(updatedStep);
                      }
                      Navigator.of(context).pop();
                    } catch (e) {
                      setState(() {
                        _output += '步骤配置解析失败: $e\n';
                        _scrollToBottom();
                      });
                    }
                  },
                  child: const Text('确认'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _addStepByType(CustomFlowStepType type) async {
    final step = _createDefaultStep(type);
    await _showStepEditor(
      initialStep: step,
      onConfirm: (updatedStep) {
        setState(() {
          _customFlowSteps = [..._customFlowSteps, updatedStep];
          _selectedCustomFlowStepIds = <String>{updatedStep.id};
        });
      },
    );
  }

  Future<void> _addWaitStep() => _addStepByType(CustomFlowStepType.wait);

  Future<void> _addImageTapStep() =>
      _addStepByType(CustomFlowStepType.imageTap);

  Future<void> _addCoordinateTapStep() =>
      _addStepByType(CustomFlowStepType.coordinateTap);

  Future<void> _addPasteTextStep() =>
      _addStepByType(CustomFlowStepType.pasteText);

  Future<void> _addWaitImageStateStep() =>
      _addStepByType(CustomFlowStepType.waitImageState);

  Future<void> _addImageBranchStep() =>
      _addStepByType(CustomFlowStepType.imageBranch);

  Future<void> _addImagePositionBranchStep() =>
      _addStepByType(CustomFlowStepType.imagePositionBranch);

  Future<void> _addLoopBlockStep() =>
      _addStepByType(CustomFlowStepType.loopBlock);

  Future<void> _addGameModeStep() =>
      _addStepByType(CustomFlowStepType.gameMode);

  Future<void> _addRecordedFlowStep() =>
      _addStepByType(CustomFlowStepType.recordedFlow);

  Future<void> _addRestartActivityStep() =>
      _addStepByType(CustomFlowStepType.restartActivity);

  Future<void> _addShutdownComputerStep() =>
      _addStepByType(CustomFlowStepType.shutdownComputer);

  Future<void> _editCustomFlowStep(int index) async {
    if (index < 0 || index >= _customFlowSteps.length) {
      return;
    }
    final step = _customFlowSteps[index];
    await _showStepEditor(
      initialStep: step,
      onConfirm: (updatedStep) {
        final wasSelected = _selectedCustomFlowStepIds.contains(step.id);
        setState(() {
          final steps = List<CustomFlowStep>.from(_customFlowSteps);
          steps[index] = updatedStep;
          _customFlowSteps = steps;
          if (wasSelected) {
            _selectedCustomFlowStepIds =
                Set<String>.from(_selectedCustomFlowStepIds)
                  ..remove(step.id)
                  ..add(updatedStep.id);
          }
        });
      },
    );
  }

  void _removeCustomFlowStep(int index) {
    if (index < 0 || index >= _customFlowSteps.length) {
      return;
    }
    final removedStepId = _customFlowSteps[index].id;
    setState(() {
      _customFlowSteps = List<CustomFlowStep>.from(_customFlowSteps)
        ..removeAt(index);
      _selectedCustomFlowStepIds = Set<String>.from(_selectedCustomFlowStepIds)
        ..remove(removedStepId);
    });
  }

  void _moveCustomFlowStep(int index, int offset) {
    final newIndex = index + offset;
    if (index < 0 ||
        index >= _customFlowSteps.length ||
        newIndex < 0 ||
        newIndex >= _customFlowSteps.length) {
      return;
    }
    setState(() {
      final steps = List<CustomFlowStep>.from(_customFlowSteps);
      final item = steps.removeAt(index);
      steps.insert(newIndex, item);
      _customFlowSteps = steps;
    });
  }

  void _reorderCustomFlowSteps(int oldIndex, int newIndex) {
    setState(() {
      _customFlowSteps = _reorderItems(_customFlowSteps, oldIndex, newIndex);
    });
  }

  Future<void> _exportStepTemplates(
    List<CustomFlowStep> steps,
    Directory targetDir,
    Map<String, String> result,
  ) async {
    Future<void> exportOne({
      required String id,
      required CustomFlowImageSource imageSource,
      required String templateName,
      required String templatePath,
    }) async {
      if (id.isEmpty) {
        return;
      }
      if (imageSource == CustomFlowImageSource.localFile) {
        if (templatePath.trim().isNotEmpty) {
          result[id] = templatePath.trim();
        }
        return;
      }
      if (templateName.trim().isEmpty) {
        return;
      }
      final assetPath = 'assets/images/${templateName.trim()}';
      final byteData = await rootBundle.load(assetPath);
      final file = File('${targetDir.path}/${id}_${p.basename(templateName)}');
      await file.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
      );
      result[id] = file.path;
    }

    for (final step in steps) {
      if (step.recognitionMode == CustomFlowRecognitionMode.image &&
          (step.type == CustomFlowStepType.imageTap ||
              step.type == CustomFlowStepType.waitImageState ||
              step.type == CustomFlowStepType.imagePositionBranch ||
              (step.type == CustomFlowStepType.loopBlock &&
                  step.loopMode == CustomFlowLoopMode.imageCondition))) {
        await exportOne(
          id: step.id,
          imageSource: step.imageSource,
          templateName: step.templateName,
          templatePath: step.templatePath,
        );
      }
      for (final branchCase in step.branchCases) {
        if (branchCase.recognitionMode == CustomFlowRecognitionMode.image) {
          for (final image in branchCase.effectiveTemplateImages) {
            await exportOne(
              id: image.id,
              imageSource: image.imageSource,
              templateName: image.templateName,
              templatePath: image.templatePath,
            );
          }
        }
        await _exportStepTemplates(branchCase.steps, targetDir, result);
      }
      await _exportStepTemplates(step.children, targetDir, result);
      await _exportStepTemplates(step.fallbackChildren, targetDir, result);
    }
  }

  Future<Map<String, dynamic>> _exportRecordedFlowsForCustomFlow(
    List<CustomFlowStep> steps,
  ) async {
    final collectedNames = <String>{};

    void collect(List<CustomFlowStep> currentSteps) {
      for (final step in currentSteps) {
        if (step.type == CustomFlowStepType.recordedFlow &&
            step.recordedFlowName.trim().isNotEmpty) {
          collectedNames.add(step.recordedFlowName.trim());
        }
        for (final branchCase in step.branchCases) {
          collect(branchCase.steps);
        }
        collect(step.children);
        collect(step.fallbackChildren);
      }
    }

    collect(steps);

    final result = <String, dynamic>{};
    for (final flowName in collectedNames) {
      final flow = await _touchRecorderService.loadFlow(flowName);
      if (flow == null) {
        throw Exception('未找到录制流程：$flowName');
      }
      result[flowName] = flow.toJson();
    }
    return result;
  }

  Future<Map<String, String>> _exportCustomFlowTemplates(
    Directory targetDir,
    List<CustomFlowStep> steps,
  ) async {
    final result = <String, String>{};
    await _exportStepTemplates(steps, targetDir, result);
    return result;
  }

  bool _customFlowContainsGameMode(List<CustomFlowStep> steps) {
    for (final step in steps) {
      if (step.type == CustomFlowStepType.gameMode) {
        return true;
      }
      if (_customFlowContainsGameMode(step.children) ||
          _customFlowContainsGameMode(step.fallbackChildren)) {
        return true;
      }
      for (final branchCase in step.branchCases) {
        if (_customFlowContainsGameMode(branchCase.steps)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _customFlowUsesTextRecognition(List<CustomFlowStep> steps) {
    for (final step in steps) {
      final stepUsesText =
          step.type == CustomFlowStepType.ocrTap ||
          ((step.type == CustomFlowStepType.imageTap ||
                  step.type == CustomFlowStepType.waitImageState ||
                  step.type == CustomFlowStepType.imagePositionBranch ||
                  (step.type == CustomFlowStepType.loopBlock &&
                      step.loopMode == CustomFlowLoopMode.imageCondition)) &&
              step.recognitionMode == CustomFlowRecognitionMode.text);
      if (stepUsesText ||
          _customFlowUsesTextRecognition(step.children) ||
          _customFlowUsesTextRecognition(step.fallbackChildren)) {
        return true;
      }
      for (final branchCase in step.branchCases) {
        if (branchCase.recognitionMode == CustomFlowRecognitionMode.text ||
            _customFlowUsesTextRecognition(branchCase.steps)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<String> _resolvePythonExecutable() async {
    final candidates = Platform.isWindows
        ? const ['python', 'py', 'python3']
        : const ['python3', 'python'];
    final failures = <String>[];
    for (final candidate in candidates) {
      try {
        final result = await Process.run(candidate, [
          '--version',
        ], runInShell: Platform.isWindows);
        final output = [
          result.stdout.toString().trim(),
          result.stderr.toString().trim(),
        ].where((item) => item.isNotEmpty).join(' ');
        if (result.exitCode == 0) {
          return candidate;
        }
        failures.add(
          '$candidate: ${output.isEmpty ? '退出码 ${result.exitCode}' : output}',
        );
      } catch (e) {
        failures.add('$candidate: $e');
      }
    }
    throw Exception('未找到可用 Python。已尝试：${failures.join('；')}');
  }

  Future<bool> _ensureRapidOcrAvailable(String pythonExecutable) async {
    final result = await Process.run(pythonExecutable, [
      '-c',
      'import rapidocr, onnxruntime',
    ], runInShell: Platform.isWindows);
    if (result.exitCode == 0) {
      return true;
    }
    final details = [
      result.stdout.toString().trim(),
      result.stderr.toString().trim(),
    ].where((item) => item.isNotEmpty).join('\n');
    final installCommand =
        '$pythonExecutable -m pip install rapidocr onnxruntime';
    if (mounted) {
      await showAdaptiveDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('需要安装 RapidOCR'),
          content: SelectionArea(
            child: Text(
              '当前自定义流程包含识图的文字识别模式，但未检测到 RapidOCR 运行依赖。\n\n'
              '请在命令行执行：\n$installCommand\n\n'
              '${details.isEmpty ? '' : '检测输出：\n$details'}',
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
    return false;
  }

  Future<List<String>> _devicesMissingAdbKeyboard(
    List<String> deviceIds,
  ) async {
    final missing = <String>[];
    for (final deviceId in deviceIds) {
      final result = await Process.run('adb', [
        '-s',
        deviceId,
        'shell',
        'pm',
        'path',
        'com.android.adbkeyboard',
      ]);
      if (result.exitCode != 0 ||
          !result.stdout.toString().contains('package:')) {
        missing.add(deviceId);
      }
    }
    return missing;
  }

  Future<String?> _selectAdbKeyboardApk({
    required List<String> missingDeviceIds,
  }) async {
    final savedPath = init ? _prefs.getString('adbKeyboardApkPath') ?? '' : '';
    final savedFile = savedPath.isEmpty ? null : File(savedPath);
    final hasSavedApk = savedFile != null && await savedFile.exists();
    if (!mounted) {
      return null;
    }

    final action = await showAdaptiveDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('需要安装 ADB Keyboard'),
          content: SelectionArea(
            child: Text(
              '以下设备尚未安装 ADB Keyboard：\n'
              '${missingDeviceIds.join('\n')}\n\n'
              '“粘贴文字”依赖这个输入法来可靠输入中文、Emoji 和特殊符号。'
              '请先从下面的项目页面下载 ADBKeyboard.apk，然后选择 APK，应用会自动安装到缺失设备。\n\n'
              'https://github.com/senzhk/ADBKeyBoard'
              '${hasSavedApk ? '\n\n上次选择：$savedPath' : ''}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('cancel'),
              child: const Text('取消', style: TextStyle(color: Colors.blue)),
            ),
            if (hasSavedApk)
              FilledButton.tonal(
                onPressed: () => Navigator.of(dialogContext).pop('saved'),
                child: const Text('使用上次 APK'),
              ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('select'),
              child: const Text('选择 APK'),
            ),
          ],
        );
      },
    );
    if (action == 'saved') {
      return savedPath;
    }
    if (action != 'select') {
      return null;
    }

    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Android APK', extensions: ['apk']),
      ],
    );
    if (file == null) {
      return null;
    }
    if (init) {
      await _prefs.setString('adbKeyboardApkPath', file.path);
    }
    return file.path;
  }

  Future<bool> _ensureAdbKeyboardInstalled(List<String> deviceIds) async {
    var missingDeviceIds = await _devicesMissingAdbKeyboard(deviceIds);
    if (missingDeviceIds.isEmpty) {
      return true;
    }

    final apkPath = await _selectAdbKeyboardApk(
      missingDeviceIds: missingDeviceIds,
    );
    if (apkPath == null) {
      if (mounted) {
        setState(() {
          _output += '已取消执行：粘贴文字步骤需要先安装 ADB Keyboard。\n';
          _scrollToBottom();
        });
      }
      return false;
    }
    if (!mounted) {
      return false;
    }

    setState(() {
      _output +=
          '正在为 ${missingDeviceIds.join(', ')} 安装 ADB Keyboard：$apkPath\n';
      _scrollToBottom();
    });
    final failures = <String>[];
    for (final deviceId in missingDeviceIds) {
      final result = await Process.run('adb', [
        '-s',
        deviceId,
        'install',
        '-r',
        apkPath,
      ]);
      final stdout = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();
      if (result.exitCode != 0 || !stdout.toLowerCase().contains('success')) {
        failures.add(
          '[$deviceId] ${stderr.isNotEmpty
              ? stderr
              : stdout.isNotEmpty
              ? stdout
              : '安装失败'}',
        );
      } else if (mounted) {
        setState(() {
          _output += '[$deviceId] ADB Keyboard 安装成功。\n';
          _scrollToBottom();
        });
      }
    }

    missingDeviceIds = await _devicesMissingAdbKeyboard(deviceIds);
    if (failures.isNotEmpty || missingDeviceIds.isNotEmpty) {
      if (mounted) {
        await showAdaptiveDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('ADB Keyboard 安装失败'),
            content: SelectionArea(
              child: Text(
                [
                  ...failures,
                  if (missingDeviceIds.isNotEmpty)
                    '安装后仍未检测到：${missingDeviceIds.join(', ')}',
                ].join('\n'),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      }
      return false;
    }
    return true;
  }

  Future<void> _exportBuiltInImagesForGameModeRunner(Directory workDir) async {
    final manifestContent = await rootBundle.loadString('AssetManifest.json');
    final manifest = jsonDecode(manifestContent) as Map<String, dynamic>;
    final assetPaths =
        manifest.keys.where((key) => key.startsWith('assets/images/')).toList()
          ..sort();

    final releaseImagesDir = Directory(
      p.join(workDir.path, 'data', 'flutter_assets', 'assets', 'images'),
    );
    final debugImagesDir = Directory(p.join(workDir.path, 'assets', 'images'));
    await releaseImagesDir.create(recursive: true);
    await debugImagesDir.create(recursive: true);

    for (final assetPath in assetPaths) {
      final data = await rootBundle.load(assetPath);
      final relativePath = assetPath.replaceFirst('assets/images/', '');
      final releaseFile = File(p.join(releaseImagesDir.path, relativePath));
      final debugFile = File(p.join(debugImagesDir.path, relativePath));
      await releaseFile.parent.create(recursive: true);
      await debugFile.parent.create(recursive: true);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await releaseFile.writeAsBytes(bytes, flush: true);
      await debugFile.writeAsBytes(bytes, flush: true);
    }
  }

  String _buildCustomFlowRunnerScript() {
    return '''
import json
import base64
import math
import os
import random
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np

_template_cache = {}
_ocr_engine = None
_ocr_engine_lock = threading.Lock()
_shutdown_schedule_lock = threading.Lock()
_shutdown_scheduled = False
_mac_shutdown_pid_file = os.path.join(
    tempfile.gettempdir(),
    'py_auto_custom_flow_shutdown.pid',
)
_pointer_slot = 0
_tracking_id = 1
_device_screen_size_cache = {}
_adb_keyboard_component = 'com.android.adbkeyboard/.AdbIME'
_adb_keyboard_package = 'com.android.adbkeyboard'


class SerialDeviceCoordinator:
    def __init__(self, device_ids):
        self._device_ids = [str(item).strip() for item in device_ids if str(item).strip()]
        self._active_device_ids = set(self._device_ids)
        self._next_index = 0
        self._condition = threading.Condition()
        self._owner_device_id = None
        self._owner_depth = 0

    def _advance_locked(self):
        if not self._active_device_ids or not self._device_ids:
            return
        for offset in range(len(self._device_ids)):
            index = (self._next_index + offset) % len(self._device_ids)
            if self._device_ids[index] in self._active_device_ids:
                self._next_index = index
                return

    def run_turn(self, device_id, callback, label=''):
        with self._condition:
            self._advance_locked()
            while (
                device_id in self._active_device_ids
                and self._active_device_ids
                and (
                    self._owner_device_id is not None
                    or self._device_ids[self._next_index] != device_id
                )
            ):
                self._condition.wait()
                self._advance_locked()
            if device_id not in self._active_device_ids:
                return None
            self._owner_device_id = device_id
            self._owner_depth = 1
            if label:
                print(f'[{device_id}] 串行轮次开始: {label}')
        try:
            return callback()
        finally:
            with self._condition:
                if self._owner_device_id == device_id:
                    self._owner_depth = 0
                    self._owner_device_id = None
                    if device_id in self._device_ids:
                        self._next_index = (self._device_ids.index(device_id) + 1) % len(self._device_ids)
                    self._advance_locked()
                    self._condition.notify_all()

    def is_owner(self, device_id):
        with self._condition:
            return self._owner_device_id == device_id

    def run_nested(self, device_id, callback):
        """让当前设备暂时让出轮次，执行递归子步骤后再恢复。"""
        with self._condition:
            if self._owner_device_id != device_id:
                return callback()
            self._owner_device_id = None
            self._owner_depth = 0
            if device_id in self._device_ids:
                self._next_index = (self._device_ids.index(device_id) + 1) % len(self._device_ids)
            self._advance_locked()
            self._condition.notify_all()
        try:
            return callback()
        finally:
            # 子步骤完成后，当前设备必须重新排队，不能直接抢回轮次。
            self.run_turn(device_id, lambda: None, label='恢复父步骤轮次')

    def finish(self, device_id):
        with self._condition:
            self._active_device_ids.discard(device_id)
            self._advance_locked()
            self._condition.notify_all()


def load_image_file(image_path):
    try:
        data = np.fromfile(image_path, dtype=np.uint8)
    except Exception:
        data = None
    if data is not None and data.size > 0:
        image = cv2.imdecode(data, cv2.IMREAD_COLOR)
        if image is not None:
            return image
    return cv2.imread(image_path)


def load_template(template_path):
    template = _template_cache.get(template_path)
    if template is None:
        template = load_image_file(template_path)
        if template is None:
            raise RuntimeError(f'无法加载模板图片: {template_path}')
        _template_cache[template_path] = template
    return template


def get_branch_screenshot_path(runtime_context):
    if not isinstance(runtime_context, dict):
        return None
    branch_screenshot_path = runtime_context.get('branchScreenshotPath')
    if not isinstance(branch_screenshot_path, str):
        return None
    branch_screenshot_path = branch_screenshot_path.strip()
    return branch_screenshot_path or None


def persist_branch_screenshot(screenshot_path):
    screenshot_dir = os.path.dirname(screenshot_path) or None
    fd, branch_screenshot_path = tempfile.mkstemp(
        prefix='custom_flow_branch_',
        suffix='.png',
        dir=screenshot_dir,
    )
    os.close(fd)
    shutil.copy2(screenshot_path, branch_screenshot_path)
    return branch_screenshot_path


def build_branch_child_context(runtime_context, branch_screenshot_path):
    child_context = dict(runtime_context or {})
    if branch_screenshot_path:
        child_context['branchScreenshotPath'] = branch_screenshot_path
    return child_context


def adb_screenshot(device_id, output_path):
    remote_path = f'/sdcard/custom_flow_screen_{device_id}.png'
    print(f'[{device_id}] 截图开始: {output_path}')
    subprocess.run(['adb', '-s', device_id, 'shell', 'screencap', '-p', remote_path], check=True)
    subprocess.run(['adb', '-s', device_id, 'pull', remote_path, output_path], check=True, capture_output=True)
    screen = load_image_file(output_path)
    if screen is None:
        with open(output_path, 'rb') as file:
            data = file.read().replace(b'\\r\\n', b'\\n')
        with open(output_path, 'wb') as file:
            file.write(data)
        screen = load_image_file(output_path)
    if screen is None:
        raise RuntimeError('截图失败')
    print(f'[{device_id}] 截图完成: {output_path}')
    return screen


def sleep_random(min_ms, max_ms):
    low = min(float(min_ms), float(max_ms))
    high = max(float(min_ms), float(max_ms))
    wait_seconds = random.uniform(low, high) if high > low else low
    if wait_seconds > 0:
        time.sleep(wait_seconds)
    return wait_seconds


def choose_wait_seconds(min_seconds, max_seconds):
    low = min(float(min_seconds), float(max_seconds))
    high = max(float(min_seconds), float(max_seconds))
    return random.uniform(low, high) if high > low else low


def get_step_seconds(step, seconds_key, legacy_ms_key, default=0):
    if seconds_key in step:
        return max(float(step.get(seconds_key, default) or 0), 0.0)
    legacy_value = step.get(legacy_ms_key, None)
    if legacy_value is None:
        return max(float(default), 0.0)
    return max(float(legacy_value) / 1000.0, 0.0)


def format_seconds(value):
    normalized = float(value)
    if normalized.is_integer():
        return str(int(normalized))
    return f'{normalized:.3f}'.rstrip('0').rstrip('.')


def format_clock(value):
    total_seconds = max(int(value), 0)
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours > 0:
        return f'{hours:02d}:{minutes:02d}:{seconds:02d}'
    return f'{minutes:02d}:{seconds:02d}'


def sleep_with_countdown(device_id, label, wait_seconds):
    wait_seconds = max(float(wait_seconds), 0.0)
    if wait_seconds <= 0:
        print(f'[{device_id}] [{label}] 倒计时 00:00')
        return 0.0
    end_time = time.time() + wait_seconds
    last_remaining = None
    while True:
        remaining = max(end_time - time.time(), 0.0)
        remaining_seconds = int(math.ceil(remaining))
        if remaining_seconds != last_remaining:
            sys.stdout.write(
                f'\\r[{device_id}] [{label}] 倒计时 {format_clock(remaining_seconds)}'
            )
            sys.stdout.flush()
            last_remaining = remaining_seconds
        if remaining <= 0:
            break
        time.sleep(min(0.2, remaining))
    sys.stdout.write(f'\\r[{device_id}] [{label}] 倒计时 {format_clock(0)}\\n')
    sys.stdout.flush()
    return wait_seconds


def step_label(step, fallback):
    label = (step.get('label', '') or '').strip()
    return label or fallback


def print_log_separator(device_id, label, detail=''):
    suffix = f' {detail}' if detail else ''
    print(f'[{device_id}] ----- {label} 完成{suffix} -----')


def image_display_name(step, template_path):
    template_name = (step.get('templateName', '') or '').strip()
    if template_name:
        return template_name
    return os.path.basename(template_path) or template_path


_tap_min_x = 4
_tap_min_y = 4
_tap_max_x = 1598
_tap_max_y = 898


def clamp_tap_point(x, y, screen_size=None):
    raw_x = int(x)
    raw_y = int(y)
    if screen_size and screen_size[0] > 0 and screen_size[1] > 0:
        max_x = max(int(screen_size[0]) - 2, 0)
        max_y = max(int(screen_size[1]) - 2, 0)
        min_x = _tap_min_x if max_x >= _tap_min_x else 0
        min_y = _tap_min_y if max_y >= _tap_min_y else 0
    else:
        max_x = _tap_max_x
        max_y = _tap_max_y
        min_x = _tap_min_x
        min_y = _tap_min_y
    clamped_x = min(max(raw_x, min_x), max_x)
    clamped_y = min(max(raw_y, min_y), max_y)
    return raw_x, raw_y, clamped_x, clamped_y


def parse_screen_size(output):
    for pattern in (r'Override size:\\s*(\\d+)x(\\d+)', r'Physical size:\\s*(\\d+)x(\\d+)'):
        match = re.search(pattern, output or '', re.IGNORECASE)
        if match:
            return int(match.group(1)), int(match.group(2))
    return None


def get_device_screen_size(device_id):
    cached = _device_screen_size_cache.get(device_id)
    if cached:
        return cached
    result = subprocess.run(
        ['adb', '-s', device_id, 'shell', 'wm', 'size'],
        check=False,
        capture_output=True,
        text=True,
    )
    screen_size = parse_screen_size(f'{result.stdout}\\n{result.stderr}')
    if not screen_size:
        raise RuntimeError(f'无法读取设备分辨率: {device_id}')
    _device_screen_size_cache[device_id] = screen_size
    return screen_size


def recorded_flow_screen_size(flow):
    width = int(flow.get('screenWidth', 0) or 0)
    height = int(flow.get('screenHeight', 0) or 0)
    if width > 0 and height > 0:
        return width, height
    return None


def scale_recorded_point(x, y, source_size, target_size):
    raw_x = int(x)
    raw_y = int(y)
    if (
        source_size
        and target_size
        and source_size[0] > 0
        and source_size[1] > 0
        and target_size[0] > 0
        and target_size[1] > 0
    ):
        raw_x = round(raw_x / source_size[0] * target_size[0])
        raw_y = round(raw_y / source_size[1] * target_size[1])
    return clamp_tap_point(raw_x, raw_y, target_size)


def tap(device_id, x, y):
    raw_x, raw_y, clamped_x, clamped_y = clamp_tap_point(x, y)
    if raw_x != clamped_x or raw_y != clamped_y:
        print(
            f'[{device_id}] 点击坐标超出边界，已从 ({raw_x}, {raw_y}) '
            f'修正为 ({clamped_x}, {clamped_y})，范围 X=0-{_tap_max_x}, Y=0-{_tap_max_y}'
        )
    subprocess.run(['adb', '-s', device_id, 'shell', 'input', 'tap', str(clamped_x), str(clamped_y)], check=True)


def adb_shell(device_id, args, check=True):
    return subprocess.run(
        ['adb', '-s', device_id, 'shell', *args],
        check=check,
        capture_output=True,
        text=True,
    )


def adb_command_error(result):
    return '\\n'.join(
        part for part in [(result.stdout or '').strip(), (result.stderr or '').strip()] if part
    )


def is_ime_command_security_error(message, command=None):
    text = str(message or '').lower()
    if command:
        return (
            f'ime {command} command is disabled for security reasons' in text
            or (f'ime {command}' in text and 'disabled for security reasons' in text)
        )
    return 'ime ' in text and 'disabled for security reasons' in text


def is_ime_set_security_error(message):
    return is_ime_command_security_error(message, 'set')


def get_current_input_method(device_id):
    result = adb_shell(
        device_id,
        ['settings', 'get', 'secure', 'default_input_method'],
        check=False,
    )
    current_ime = (result.stdout or '').strip()
    if current_ime.lower() == 'null':
        return ''
    return current_ime


def raise_adb_keyboard_security_error(command_name, command_error):
    raise RuntimeError(
        f'当前设备禁止通过 ADB 执行 ime {command_name}，无法自动准备 ADB Keyboard。'
        '请在设备/模拟器设置里手动启用并选择 ADB Keyboard 后重新执行，'
        '或更换允许 adb shell ime 命令的模拟器/系统；'
        f'否则“粘贴文字”步骤无法执行。原始错误: {command_error}'
    )


def cleanup_adb_keyboard_enablement(device_id, state):
    state = state or {}
    if bool(state.get('enabledByRunner', False)):
        disable_result = adb_shell(
            device_id,
            ['ime', 'disable', _adb_keyboard_component],
            check=False,
        )
        if disable_result.returncode != 0:
            disable_error = adb_command_error(disable_result)
            if is_ime_command_security_error(disable_error, 'disable'):
                print(
                    f'[{device_id}] 禁用临时 ADB Keyboard 失败: 设备禁止通过 ADB 禁用输入法，'
                    f'如需关闭请在系统设置中手动处理。原始错误: {disable_error}'
                )
            else:
                print(
                    f'[{device_id}] 禁用临时 ADB Keyboard 失败: {disable_error}'
                )


def flow_contains_paste_text(steps):
    for step in steps:
        if step.get('type') == 'pasteText':
            return True
        if flow_contains_paste_text(step.get('children', [])):
            return True
        if flow_contains_paste_text(step.get('fallbackChildren', [])):
            return True
        for branch_case in step.get('branchCases', []):
            if flow_contains_paste_text(branch_case.get('steps', [])):
                return True
    return False


def flow_contains_paste_text_for_device(steps, device_id, runtime_context):
    for step in steps:
        if not step_applies_to_device(step, device_id, runtime_context):
            continue
        if step.get('type') == 'pasteText':
            return True
        if flow_contains_paste_text_for_device(
            step.get('children', []), device_id, runtime_context
        ):
            return True
        if flow_contains_paste_text_for_device(
            step.get('fallbackChildren', []), device_id, runtime_context
        ):
            return True
        for branch_case in step.get('branchCases', []):
            if flow_contains_paste_text_for_device(
                branch_case.get('steps', []), device_id, runtime_context
            ):
                return True
    return False


def prepare_adb_keyboard(device_id):
    package_result = adb_shell(
        device_id,
        ['pm', 'path', _adb_keyboard_package],
        check=False,
    )
    if package_result.returncode != 0 or not (package_result.stdout or '').strip():
        raise RuntimeError(
            '设备未安装 ADB Keyboard。请先安装 com.android.adbkeyboard，'
            '再重新执行包含“粘贴文字”的自定义流程。'
        )

    original_ime = get_current_input_method(device_id)

    enabled_result = adb_shell(device_id, ['ime', 'list', '-s'], check=False)
    enabled_imes = {
        line.strip()
        for line in (enabled_result.stdout or '').splitlines()
        if line.strip()
    }
    state = {
        'originalIme': original_ime,
        'wasEnabled': _adb_keyboard_component in enabled_imes,
        'enabledByRunner': False,
    }
    try:
        if not state['wasEnabled']:
            enable_result = adb_shell(
                device_id,
                ['ime', 'enable', _adb_keyboard_component],
                check=False,
            )
            if enable_result.returncode != 0:
                enable_error = adb_command_error(enable_result) or '启用 ADB Keyboard 失败'
                if is_ime_command_security_error(enable_error, 'enable'):
                    current_ime = get_current_input_method(device_id)
                    if current_ime == _adb_keyboard_component:
                        print(
                            f'[{device_id}] 设备禁止通过 ADB 启用输入法，但当前已是 ADB Keyboard，继续执行'
                        )
                    else:
                        state['skipRestoreOnPrepareError'] = True
                        raise_adb_keyboard_security_error('enable', enable_error)
                else:
                    raise RuntimeError(enable_error)
            else:
                state['enabledByRunner'] = True
        set_result = adb_shell(
            device_id,
            ['ime', 'set', _adb_keyboard_component],
            check=False,
        )
        if set_result.returncode != 0:
            set_error = adb_command_error(set_result) or '切换到 ADB Keyboard 失败'
            if is_ime_set_security_error(set_error):
                current_ime = get_current_input_method(device_id)
                if current_ime == _adb_keyboard_component:
                    print(
                        f'[{device_id}] 设备禁止通过 ADB 切换输入法，但当前已是 ADB Keyboard，继续执行'
                    )
                else:
                    state['skipRestoreOnPrepareError'] = True
                    cleanup_adb_keyboard_enablement(device_id, state)
                    raise_adb_keyboard_security_error('set', set_error)
            else:
                raise RuntimeError(set_error)
    except Exception:
        if not bool(state.get('skipRestoreOnPrepareError', False)):
            restore_adb_keyboard(device_id, state)
        raise

    print(f'[{device_id}] 已临时切换到 ADB Keyboard')
    return state


def restore_adb_keyboard(device_id, state):
    state = state or {}
    original_ime = (state.get('originalIme', '') or '').strip()
    if original_ime and original_ime != _adb_keyboard_component:
        restore_result = adb_shell(
            device_id,
            ['ime', 'set', original_ime],
            check=False,
        )
        if restore_result.returncode != 0:
            restore_error = adb_command_error(restore_result) or original_ime
            if is_ime_set_security_error(restore_error):
                print(
                    f'[{device_id}] 恢复原输入法失败: 设备禁止通过 ADB 切换输入法，'
                    f'请手动切回原输入法。原始错误: {restore_error}'
                )
            else:
                print(
                    f'[{device_id}] 恢复原输入法失败: {restore_error}'
                )
        else:
            print(f'[{device_id}] 已恢复原输入法: {original_ime}')
    cleanup_adb_keyboard_enablement(device_id, state)


def send_adb_keyboard_broadcast(device_id, action, message=None):
    args = ['am', 'broadcast', '-a', action]
    if message is not None:
        args.extend(['--es', 'msg', message])
    result = adb_shell(device_id, args, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            adb_command_error(result) or f'ADB Keyboard 广播执行失败: {action}'
        )


def run_paste_text_step(device_id, step, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    label = step_label(step, '粘贴文字')
    if bool(step.get('useParentLoopText', False)):
        if 'currentLoopText' not in runtime_context:
            raise RuntimeError(
                '粘贴文字步骤设置为使用上层文本，但当前没有可用的文本循环内容'
            )
        text = str(runtime_context.get('currentLoopText', ''))
        source_text = '上层文本循环'
    else:
        text = str(step.get('textContent', '') or '')
        source_text = '固定文字'

    send_adb_keyboard_broadcast(device_id, 'ADB_CLEAR_TEXT')
    if text:
        encoded = base64.b64encode(text.encode('utf-8')).decode('ascii')
        send_adb_keyboard_broadcast(device_id, 'ADB_INPUT_B64', encoded)
    print(
        f'[{device_id}] [{label}] 已清空输入框并输入{source_text}，字符数: {len(text)}'
    )


def split_text_lines(text):
    return [
        line.strip()
        for line in str(text or '').splitlines()
        if line.strip()
    ]


def find_template(screen, template_path, confidence):
    template = load_template(template_path)
    result = cv2.matchTemplate(screen, template, cv2.TM_CCOEFF_NORMED)
    _, max_val, _, max_loc = cv2.minMaxLoc(result)
    if max_val < confidence:
        return None
    h, w = template.shape[:2]
    return max_loc[0] + w // 2, max_loc[1] + h // 2, max_val


def get_ocr_engine():
    global _ocr_engine
    if _ocr_engine is not None:
        return _ocr_engine
    with _ocr_engine_lock:
        if _ocr_engine is not None:
            return _ocr_engine
        try:
            from rapidocr import RapidOCR
        except Exception as error:
            raise RuntimeError(
                '未安装 RapidOCR。请先执行: python -m pip install rapidocr onnxruntime'
            ) from error
        _ocr_engine = RapidOCR()
        return _ocr_engine


def read_result_field(result, field_name):
    if result is None:
        return None
    if isinstance(result, dict):
        return result.get(field_name)
    return getattr(result, field_name, None)


def normalize_ocr_output(result):
    boxes = read_result_field(result, 'boxes')
    txts = read_result_field(result, 'txts')
    scores = read_result_field(result, 'scores')
    if boxes is not None and txts is not None:
        return [
            {'box': box, 'text': text, 'score': scores[index] if scores is not None and index < len(scores) else None}
            for index, (box, text) in enumerate(zip(boxes, txts))
        ]

    if not isinstance(result, (list, tuple)):
        return []
    first_item = result[0] if result else None
    first_item_is_entry = isinstance(first_item, dict) or (
        isinstance(first_item, (list, tuple))
        and len(first_item) >= 2
        and (
            isinstance(first_item[1], str)
            or (
                isinstance(first_item[1], (list, tuple))
                and len(first_item[1]) > 0
                and isinstance(first_item[1][0], str)
            )
        )
    )
    if len(result) == 3 and not first_item_is_entry:
        boxes, txts, scores = result
        return [
            {'box': box, 'text': text, 'score': scores[index] if scores is not None and index < len(scores) else None}
            for index, (box, text) in enumerate(zip(boxes or [], txts or []))
        ]

    entries = []
    for item in result:
        if isinstance(item, dict):
            entries.append({
                'box': item.get('box') or item.get('points') or item.get('dt_box'),
                'text': item.get('text') or item.get('txt') or item.get('rec_text') or '',
                'score': item.get('score') or item.get('confidence') or item.get('rec_score'),
            })
            continue
        if not isinstance(item, (list, tuple)) or len(item) < 2:
            continue
        box = item[0]
        text = ''
        score = None
        if len(item) >= 3:
            text = item[1]
            score = item[2]
        elif isinstance(item[1], (list, tuple)) and item[1]:
            text = item[1][0]
            score = item[1][1] if len(item[1]) > 1 else None
        entries.append({'box': box, 'text': text, 'score': score})
    return entries


def ocr_box_center(box):
    try:
        points = np.asarray(box, dtype=float).reshape(-1, 2)
    except Exception:
        return None
    if points.size == 0:
        return None
    return int(round(float(points[:, 0].mean()))), int(round(float(points[:, 1].mean())))


def normalize_text_for_ocr_match(value):
    return re.sub(r'\\s+', '', str(value or '')).lower()


def ocr_text_matches(text, target_text, match_mode):
    if match_mode == 'regex':
        return re.search(target_text, str(text or '')) is not None
    normalized_text = normalize_text_for_ocr_match(text)
    normalized_target = normalize_text_for_ocr_match(target_text)
    if match_mode == 'exact':
        return normalized_text == normalized_target
    return normalized_target in normalized_text


def crop_ocr_region(screen, step):
    height, width = screen.shape[:2]
    def read_region_value(key):
        value = step.get(key, -1)
        if value is None or value == '':
            return -1
        return int(value)
    left = read_region_value('ocrRegionLeft')
    top = read_region_value('ocrRegionTop')
    right = read_region_value('ocrRegionRight')
    bottom = read_region_value('ocrRegionBottom')
    if left < 0 or top < 0 or right <= left or bottom <= top:
        return screen, 0, 0, '全屏'
    clamped_left = min(max(left, 0), width)
    clamped_top = min(max(top, 0), height)
    clamped_right = min(max(right, 0), width)
    clamped_bottom = min(max(bottom, 0), height)
    if clamped_right <= clamped_left or clamped_bottom <= clamped_top:
        raise RuntimeError(
            f'OCR 识别区域超出屏幕或无效: ({left}, {top})-({right}, {bottom})'
        )
    return (
        screen[clamped_top:clamped_bottom, clamped_left:clamped_right],
        clamped_left,
        clamped_top,
        f'({clamped_left}, {clamped_top})-({clamped_right}, {clamped_bottom})',
    )


def find_ocr_matches(screen, step):
    target_text = str(step.get('ocrTargetText', '') or '').strip()
    if not target_text:
        raise RuntimeError('识图文字识别模式缺少目标文字')
    match_mode = step.get('ocrMatchMode', 'contains')
    if match_mode not in ('contains', 'exact', 'regex'):
        match_mode = 'contains'
    confidence = float(step.get('confidence', 0.50))
    ocr_image, offset_x, offset_y, region_text = crop_ocr_region(screen, step)
    engine = get_ocr_engine()
    with _ocr_engine_lock:
        result = engine(ocr_image)
    matches = []
    for entry in normalize_ocr_output(result):
        text = str(entry.get('text', '') or '')
        raw_score = entry.get('score', None)
        score = 1.0 if raw_score is None else float(raw_score)
        if score < confidence:
            continue
        center = ocr_box_center(entry.get('box'))
        if center is None:
            continue
        try:
            matched = ocr_text_matches(text, target_text, match_mode)
        except re.error as error:
            raise RuntimeError(f'OCR 正则表达式不正确: {target_text}, {error}') from error
        if not matched:
            continue
        matches.append({
            'x': center[0] + offset_x,
            'y': center[1] + offset_y,
            'text': text,
            'score': score,
            'region': region_text,
        })
    matches.sort(key=lambda item: (item['y'], item['x']))
    return matches


def position_branch_case_matches(branch_case, center_x, center_y):
    x_min = branch_case.get('centerXMin', None)
    x_max = branch_case.get('centerXMax', None)
    y_min = branch_case.get('centerYMin', None)
    y_max = branch_case.get('centerYMax', None)
    if x_min is not None and float(center_x) < float(x_min):
        return False
    if x_max is not None and float(center_x) > float(x_max):
        return False
    if y_min is not None and float(center_y) < float(y_min):
        return False
    if y_max is not None and float(center_y) > float(y_max):
        return False
    return True


def image_path_for(item, image_paths):
    template_path = image_paths.get(item.get('id', ''))
    if not template_path or not os.path.exists(template_path):
        raise RuntimeError(f"模板图片不存在: {item.get('templateName', '') or template_path}")
    return template_path


def template_images_for_branch_case(branch_case):
    template_images = branch_case.get('templateImages', [])
    if isinstance(template_images, list) and template_images:
        return template_images
    return [branch_case]


def extract_activity_component(raw_text):
    separators = '()[]{}<>,;'
    for token in raw_text.replace('=', ' ').split():
        cleaned = token.strip(separators)
        if '/' not in cleaned:
            continue
        package_name, activity_name = cleaned.split('/', 1)
        if not package_name or not activity_name:
            continue
        if '.' not in package_name:
            continue
        return f'{package_name}/{activity_name}'
    return None


def detect_current_activity(device_id):
    result = subprocess.run(
        ['adb', '-s', device_id, 'shell', 'dumpsys', 'activity'],
        check=True,
        capture_output=True,
        text=True,
    )
    stdout = result.stdout or ''
    candidate_line = None
    for keyword in ['mFocusedApp', 'topResumedActivity', 'mResumedActivity', 'ResumedActivity']:
        for line in stdout.splitlines():
            if keyword in line:
                candidate_line = line.strip()
                break
        if candidate_line:
            break
    component = extract_activity_component(candidate_line or stdout)
    if not component:
        raise RuntimeError('未能从 dumpsys activity 中解析出 Activity 组件名')
    print(f'[{device_id}] 当前 Activity: {component}')
    return component


def package_name_from_component(component):
    return (component or '').split('/', 1)[0].strip()


def cold_start_package(device_id, package_name):
    package_name = (package_name or '').strip()
    if not package_name:
        raise RuntimeError('缺少包名，无法冷启动应用')
    subprocess.run(
        ['adb', '-s', device_id, 'shell', 'am', 'force-stop', package_name],
        check=False,
        capture_output=True,
        text=True,
    )
    result = subprocess.run(
        [
            'adb',
            '-s',
            device_id,
            'shell',
            'monkey',
            '-p',
            package_name,
            '-c',
            'android.intent.category.LAUNCHER',
            '1',
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    stdout = (result.stdout or '').strip()
    stderr = (result.stderr or '').strip()
    success = result.returncode == 0 and 'Events injected: 1' in stdout
    if not success:
        details = '\\n'.join(part for part in [stdout, stderr] if part)
        if details:
            raise RuntimeError(f'冷启动应用失败: {package_name}\\n{details}')
        raise RuntimeError(f'冷启动应用失败: {package_name}')
    print(f'[{device_id}] 已回退为冷启动应用: {package_name}')
    if stdout:
        print(stdout)
    if stderr:
        print(stderr)


def restart_activity(device_id, component):
    component = (component or '').strip()
    if '/' not in component:
        raise RuntimeError(f'Activity 组件名格式不正确: {component}')
    package_name = package_name_from_component(component)
    try:
        result = subprocess.run(
            ['adb', '-s', device_id, 'shell', 'am', 'start', '-W', '-S', '-n', component],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as error:
        stdout = (error.stdout or '').strip()
        stderr = (error.stderr or '').strip()
        details = '\\n'.join(part for part in [stdout, stderr] if part)
        lowered = details.lower()
        if 'not exported' in lowered or 'permission denial' in lowered:
            print(
                f'[{device_id}] Activity 不允许被 adb 直接启动，回退为冷启动应用: {package_name}'
            )
            cold_start_package(device_id, package_name)
            return
        if details:
            raise RuntimeError(
                f'重启 Activity 失败: {component}\\n{details}'
            ) from error
        raise RuntimeError(f'重启 Activity 失败: {component}') from error
    stdout = (result.stdout or '').strip()
    stderr = (result.stderr or '').strip()
    print(f'[{device_id}] 重启 Activity: {component}')
    if stdout:
        print(stdout)
    if stderr:
        print(stderr)


def schedule_desktop_shutdown(delay_seconds):
    delay_seconds = max(int(float(delay_seconds or 0)), 0)
    if sys.platform.startswith('win'):
        result = subprocess.run(
            ['shutdown', '/s', '/t', str(delay_seconds)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            details = '\\n'.join(
                part for part in [(result.stdout or '').strip(), (result.stderr or '').strip()] if part
            )
            raise RuntimeError(details or 'Windows 关机任务创建失败')
        return f'Windows 已设置 {delay_seconds} 秒后关机'
    if sys.platform == 'darwin':
        try:
            if os.path.exists(_mac_shutdown_pid_file):
                with open(_mac_shutdown_pid_file, 'r', encoding='utf-8') as file:
                    existing_pid = int((file.read() or '').strip())
                if existing_pid > 0:
                    try:
                        os.killpg(existing_pid, signal.SIGTERM)
                    except OSError:
                        pass
                os.remove(_mac_shutdown_pid_file)
        except Exception:
            pass
        shell_command = (
            f"sleep {delay_seconds}; "
            "osascript -e 'tell application "
            '"System Events"'
            " to shut down'; "
            f"rm -f '{_mac_shutdown_pid_file}'"
        )
        process = subprocess.Popen(
            ['/bin/sh', '-c', shell_command],
            start_new_session=True,
        )
        with open(_mac_shutdown_pid_file, 'w', encoding='utf-8') as file:
            file.write(str(process.pid))
        return f'macOS 已设置 {delay_seconds} 秒后关机'
    raise RuntimeError('当前平台不支持桌面关机')


def run_shutdown_step(device_id, step):
    global _shutdown_scheduled
    label = step_label(step, '关机操作')
    delay_seconds = max(float(step.get('shutdownDelaySeconds', 60) or 0), 0.0)
    with _shutdown_schedule_lock:
        if _shutdown_scheduled:
            print(f'[{device_id}] [{label}] 已有桌面关机任务，本次跳过重复设置')
            return
        message = schedule_desktop_shutdown(delay_seconds)
        _shutdown_scheduled = True
    print(f'[{device_id}] [{label}] {message}')


def run_image_tap(device_id, step, image_paths, screenshot_path):
    if step.get('recognitionMode', 'image') == 'text':
        run_ocr_tap(device_id, step, screenshot_path)
        return
    template_path = image_path_for(step, image_paths)
    template_name = image_display_name(step, template_path)
    label = step_label(step, '识图点击')
    max_attempts = max(int(step.get('maxAttempts', 1)), 1)
    retry_interval_seconds = get_step_seconds(step, 'retryIntervalSeconds', 'retryIntervalMs')
    confidence = float(step.get('confidence', 0.68))
    random_offset = max(int(step.get('randomOffsetPx', 0)), 0)
    continue_on_failure = bool(step.get('continueOnFailure', False))
    for attempt in range(1, max_attempts + 1):
        print(
            f'[{device_id}] [{label}] 第 {attempt}/{max_attempts} 次识图: {template_name}, '
            f'阈值 {confidence:.2f}, 重试间隔 {format_seconds(retry_interval_seconds)}s'
        )
        screen = adb_screenshot(device_id, screenshot_path)
        found = find_template(screen, template_path, confidence)
        if found is not None:
            raw_x, raw_y, score = found
            x, y = raw_x, raw_y
            if random_offset > 0:
                x += random.randint(-random_offset, random_offset)
                y += random.randint(-random_offset, random_offset)
                print(
                    f'[{device_id}] [{label}] 识图成功: {template_name}, 置信度 {score:.3f}, '
                    f'原始坐标 ({raw_x}, {raw_y}), 随机偏移后点击 ({x}, {y})'
                )
            else:
                print(
                    f'[{device_id}] [{label}] 识图成功: {template_name}, 置信度 {score:.3f}, '
                    f'点击坐标 ({x}, {y})'
                )
            tap(device_id, x, y)
            post_wait_min_seconds = get_step_seconds(step, 'postWaitMinSeconds', 'postWaitMinMs')
            post_wait_max_seconds = get_step_seconds(step, 'postWaitMaxSeconds', 'postWaitMaxMs')
            post_wait_seconds = choose_wait_seconds(post_wait_min_seconds, post_wait_max_seconds)
            print(
                f'[{device_id}] [{label}] 点击完成，开始等待 '
                f'{format_seconds(post_wait_min_seconds)}-{format_seconds(post_wait_max_seconds)}s，'
                f'本次 {format_seconds(post_wait_seconds)}s'
            )
            sleep_with_countdown(
                device_id,
                label,
                post_wait_seconds,
            )
            return
        if attempt < max_attempts and retry_interval_seconds > 0:
            print(
                f'[{device_id}] [{label}] 未命中图片: {template_name}，'
                f'{format_seconds(retry_interval_seconds)}s 后重试'
            )
            time.sleep(retry_interval_seconds)
    if continue_on_failure:
        print(f'[{device_id}] [{label}] 未命中图片，继续后续步骤: {template_name}')
        return
    raise RuntimeError(f'步骤执行失败，未找到图片: {template_name}')


def run_ocr_tap(device_id, step, screenshot_path):
    label = step_label(step, '识图点击（文字识别）')
    target_text = str(step.get('ocrTargetText', '') or '').strip()
    if not target_text:
        raise RuntimeError('识图文字识别模式缺少目标文字')
    max_attempts = max(int(step.get('maxAttempts', 1)), 1)
    retry_interval_seconds = get_step_seconds(step, 'retryIntervalSeconds', 'retryIntervalMs')
    random_offset = max(int(step.get('randomOffsetPx', 0)), 0)
    continue_on_failure = bool(step.get('continueOnFailure', False))
    match_index = max(int(step.get('ocrMatchIndex', 1) or 1), 1)
    click_offset_x = int(step.get('ocrClickOffsetX', 0) or 0)
    click_offset_y = int(step.get('ocrClickOffsetY', 0) or 0)
    confidence = float(step.get('confidence', 0.50))
    match_mode = step.get('ocrMatchMode', 'contains')

    for attempt in range(1, max_attempts + 1):
        print(
            f'[{device_id}] [{label}] 第 {attempt}/{max_attempts} 次文字识别: '
            f'目标“{target_text}”，模式 {match_mode}, 阈值 {confidence:.2f}, '
            f'点击第 {match_index} 个命中'
        )
        screen = adb_screenshot(device_id, screenshot_path)
        matches = find_ocr_matches(screen, step)
        if len(matches) >= match_index:
            match = matches[match_index - 1]
            raw_x = int(match['x']) + click_offset_x
            raw_y = int(match['y']) + click_offset_y
            x, y = raw_x, raw_y
            if random_offset > 0:
                x += random.randint(-random_offset, random_offset)
                y += random.randint(-random_offset, random_offset)
            print(
                f'[{device_id}] [{label}] 文字识别成功: “{match["text"]}”, '
                f'置信度 {match["score"]:.3f}, 区域 {match["region"]}, '
                f'基础坐标 ({raw_x}, {raw_y}), 点击坐标 ({x}, {y})'
            )
            tap(device_id, x, y)
            post_wait_min_seconds = get_step_seconds(step, 'postWaitMinSeconds', 'postWaitMinMs')
            post_wait_max_seconds = get_step_seconds(step, 'postWaitMaxSeconds', 'postWaitMaxMs')
            post_wait_seconds = choose_wait_seconds(post_wait_min_seconds, post_wait_max_seconds)
            print(
                f'[{device_id}] [{label}] 点击完成，开始等待 '
                f'{format_seconds(post_wait_min_seconds)}-{format_seconds(post_wait_max_seconds)}s，'
                f'本次 {format_seconds(post_wait_seconds)}s'
            )
            sleep_with_countdown(
                device_id,
                label,
                post_wait_seconds,
            )
            return
        print(
            f'[{device_id}] [{label}] 未命中文字“{target_text}”，'
            f'当前命中数 {len(matches)}，需要第 {match_index} 个'
        )
        if attempt < max_attempts and retry_interval_seconds > 0:
            print(
                f'[{device_id}] [{label}] {format_seconds(retry_interval_seconds)}s 后重试'
            )
            time.sleep(retry_interval_seconds)
    if continue_on_failure:
        print(f'[{device_id}] [{label}] 未命中文字，继续后续步骤: {target_text}')
        return
    raise RuntimeError(f'步骤执行失败，未找到文字: {target_text}')


def run_wait_ocr_state(device_id, step, screenshot_path):
    label = step_label(step, '文字识别等待')
    target_text = str(step.get('ocrTargetText', '') or '').strip()
    if not target_text:
        raise RuntimeError('文字识别等待缺少目标文字')
    timeout_seconds = get_step_seconds(step, 'timeoutSeconds', 'timeoutMs')
    poll_interval_seconds = get_step_seconds(step, 'pollIntervalSeconds', 'pollIntervalMs')
    wait_target_state = step.get('waitTargetState', 'appear')
    continue_on_failure = bool(step.get('continueOnFailure', False))
    start_time = time.time()
    target_state_text = '出现' if wait_target_state == 'appear' else '消失'
    print(
        f'[{device_id}] [{label}] 开始等待文字{target_state_text}: {target_text}, '
        f'轮询间隔 {format_seconds(poll_interval_seconds)}s, '
        f'超时 {("无限" if timeout_seconds <= 0 else f"{format_seconds(timeout_seconds)}s")}'
    )
    while True:
        screen = adb_screenshot(device_id, screenshot_path)
        matches = find_ocr_matches(screen, step)
        found = bool(matches)
        matched = found if wait_target_state == 'appear' else not found
        elapsed_seconds = time.time() - start_time
        print(
            f'[{device_id}] [{label}] 判断结果: 文字当前{"已出现" if found else "未出现"}, '
            f'目标为{target_state_text}, 本次{"命中" if matched else "未命中"}, '
            f'已等待 {format_seconds(elapsed_seconds)}s'
        )
        if matched:
            print(f'[{device_id}] [{label}] 文字识别等待完成: {target_text}, 条件 {wait_target_state}')
            return
        if timeout_seconds > 0 and (time.time() - start_time) >= timeout_seconds:
            if continue_on_failure:
                print(f'[{device_id}] [{label}] 文字识别等待超时，继续后续步骤: {target_text}')
                return
            raise RuntimeError(f'文字识别等待超时: {target_text}')
        if poll_interval_seconds > 0:
            time.sleep(poll_interval_seconds)


def run_wait_image_state(device_id, step, image_paths, screenshot_path):
    if step.get('recognitionMode', 'image') == 'text':
        run_wait_ocr_state(device_id, step, screenshot_path)
        return
    template_path = image_path_for(step, image_paths)
    template_name = image_display_name(step, template_path)
    label = step_label(step, '识图等待')
    confidence = float(step.get('confidence', 0.68))
    timeout_seconds = get_step_seconds(step, 'timeoutSeconds', 'timeoutMs')
    poll_interval_seconds = get_step_seconds(step, 'pollIntervalSeconds', 'pollIntervalMs')
    wait_target_state = step.get('waitTargetState', 'appear')
    continue_on_failure = bool(step.get('continueOnFailure', False))
    start_time = time.time()
    target_text = '出现' if wait_target_state == 'appear' else '消失'
    print(
        f'[{device_id}] [{label}] 开始等待图片{target_text}: {template_name}, '
        f'阈值 {confidence:.2f}, 轮询间隔 {format_seconds(poll_interval_seconds)}s, '
        f'超时 {("无限" if timeout_seconds <= 0 else f"{format_seconds(timeout_seconds)}s")}'
    )
    while True:
        screen = adb_screenshot(device_id, screenshot_path)
        found = find_template(screen, template_path, confidence) is not None
        matched = found if wait_target_state == 'appear' else not found
        elapsed_seconds = time.time() - start_time
        print(
            f'[{device_id}] [{label}] 判断结果: 图片当前{"已出现" if found else "未出现"}，'
            f'目标为{target_text}，本次{"命中" if matched else "未命中"}，'
            f'已等待 {format_seconds(elapsed_seconds)}s'
        )
        if matched:
            print(f'[{device_id}] [{label}] 识图等待完成: {template_name}, 条件 {wait_target_state}')
            return
        if timeout_seconds > 0 and (time.time() - start_time) >= timeout_seconds:
            if continue_on_failure:
                print(f'[{device_id}] [{label}] 识图等待超时，继续后续步骤: {template_name}')
                return
            raise RuntimeError(f'识图等待超时: {template_name}')
        if poll_interval_seconds > 0:
            time.sleep(poll_interval_seconds)


def run_image_position_branch(
    device_id,
    step,
    image_paths,
    screenshot_path,
    work_dir,
    runtime_context=None,
):
    runtime_context = dict(runtime_context or {})
    reuse_parent_branch_screenshot = bool(
        step.get('reuseParentBranchScreenshot', False)
    )
    branch_screenshot_path = get_branch_screenshot_path(runtime_context)
    if step.get('recognitionMode', 'image') == 'text':
        label = step_label(step, '文字识别坐标分支')
        if reuse_parent_branch_screenshot and branch_screenshot_path:
            screen = load_image_file(branch_screenshot_path)
            if screen is None:
                raise RuntimeError(
                    f'无法读取可复用的分支截图: {branch_screenshot_path}'
                )
        else:
            screen = adb_screenshot(device_id, screenshot_path)
            branch_screenshot_path = persist_branch_screenshot(screenshot_path)
        branch_context = build_branch_child_context(
            runtime_context,
            branch_screenshot_path,
        )
        match_index = max(int(step.get('ocrMatchIndex', 1) or 1), 1)
        matches = find_ocr_matches(screen, step)
        if len(matches) < match_index:
            print(f'[{device_id}] [{label}] 未命中文字，执行默认分支: {step.get("ocrTargetText", "")}')
            execute_steps(
                device_id,
                step.get('fallbackChildren', []),
                image_paths,
                work_dir,
                branch_context,
            )
            return
        match = matches[match_index - 1]
        center_x = int(match['x'])
        center_y = int(match['y'])
        score = float(match['score'])
        matched_name = str(match.get('text', '') or step.get('ocrTargetText', ''))
        print(
            f'[{device_id}] [{label}] 文字识别成功: {matched_name}, '
            f'置信度 {score:.3f}, 中心点 ({center_x}, {center_y})'
        )
        matched = False
        branch_cases = step.get('branchCases', [])
        for index, branch_case in enumerate(branch_cases, start=1):
            branch_label = step_label(branch_case, f'分支{index}')
            condition_result = position_branch_case_matches(branch_case, center_x, center_y)
            print(
                f'[{device_id}] [{label}] 判断条件 {index}: {branch_label}, '
                f'结果 {"命中" if condition_result else "未命中"}'
            )
            if condition_result:
                matched = True
                print(f'[{device_id}] [{label}] 执行分支: {branch_label}')
                child_context = build_branch_child_context(
                    branch_context,
                    branch_screenshot_path,
                )
                child_context['matchedPositionCenter'] = {
                    'x': int(center_x),
                    'y': int(center_y),
                    'score': float(score),
                    'templateName': matched_name,
                }
                execute_steps(
                    device_id,
                    branch_case.get('steps', []),
                    image_paths,
                    work_dir,
                    child_context,
                )
                break
        if not matched:
            print(f'[{device_id}] [{label}] 坐标条件均未命中，执行默认分支')
            execute_steps(
                device_id,
                step.get('fallbackChildren', []),
                image_paths,
                work_dir,
                branch_context,
            )
        return
    template_path = image_path_for(step, image_paths)
    template_name = image_display_name(step, template_path)
    label = step_label(step, '识图坐标分支')
    confidence = float(step.get('confidence', 0.68))
    if reuse_parent_branch_screenshot and branch_screenshot_path:
        screen = load_image_file(branch_screenshot_path)
        if screen is None:
            raise RuntimeError(f'无法读取可复用的分支截图: {branch_screenshot_path}')
    else:
        screen = adb_screenshot(device_id, screenshot_path)
        branch_screenshot_path = persist_branch_screenshot(screenshot_path)
    branch_context = build_branch_child_context(
        runtime_context,
        branch_screenshot_path,
    )
    found = find_template(screen, template_path, confidence)
    if found is None:
        print(f'[{device_id}] [{label}] 未命中图片，执行默认分支: {template_name}')
        execute_steps(
            device_id,
            step.get('fallbackChildren', []),
            image_paths,
            work_dir,
            branch_context,
        )
        return
    center_x, center_y, score = found
    print(
        f'[{device_id}] [{label}] 识图成功: {template_name}, '
        f'置信度 {score:.3f}, 中心点 ({center_x}, {center_y})'
    )
    matched = False
    branch_cases = step.get('branchCases', [])
    for index, branch_case in enumerate(branch_cases, start=1):
        branch_label = step_label(branch_case, f'分支{index}')
        condition_result = position_branch_case_matches(branch_case, center_x, center_y)
        print(
            f'[{device_id}] [{label}] 判断条件 {index}: {branch_label}, '
            f'结果 {"命中" if condition_result else "未命中"}'
        )
        if condition_result:
            matched = True
            print(f'[{device_id}] [{label}] 执行分支: {branch_label}')
            child_context = build_branch_child_context(
                branch_context,
                branch_screenshot_path,
            )
            child_context['matchedPositionCenter'] = {
                'x': int(center_x),
                'y': int(center_y),
                'score': float(score),
                'templateName': template_name,
            }
            execute_steps(
                device_id,
                branch_case.get('steps', []),
                image_paths,
                work_dir,
                child_context,
            )
            break
    if not matched:
        print(f'[{device_id}] [{label}] 坐标条件均未命中，执行默认分支')
        execute_steps(
            device_id,
            step.get('fallbackChildren', []),
            image_paths,
            work_dir,
            branch_context,
        )


def should_continue_loop(device_id, step, image_paths, screenshot_path):
    loop_mode = step.get('loopMode', 'fixedCount')
    if loop_mode != 'imageCondition':
        return None
    if step.get('recognitionMode', 'image') == 'text':
        label = step_label(step, '循环块')
        loop_action = step.get('loopImageAction', 'stopOnMatch')
        screen = adb_screenshot(device_id, screenshot_path)
        matched = bool(find_ocr_matches(screen, step))
        if loop_action == 'continueOnMatch':
            should_continue = matched
        else:
            should_continue = not matched
        action_text = '继续循环' if should_continue else '停止循环'
        print(
            f'[{device_id}] [{label}] 循环条件文字识别结果: {step.get("ocrTargetText", "")}, '
            f'本次{"命中" if matched else "未命中"}, 动作: {action_text}'
        )
        return should_continue
    template_path = image_path_for(step, image_paths)
    template_name = image_display_name(step, template_path)
    label = step_label(step, '循环块')
    confidence = float(step.get('confidence', 0.68))
    loop_action = step.get('loopImageAction', 'stopOnMatch')
    screen = adb_screenshot(device_id, screenshot_path)
    matched = find_template(screen, template_path, confidence) is not None
    if loop_action == 'continueOnMatch':
        should_continue = matched
    else:
        should_continue = not matched
    action_text = '继续循环' if should_continue else '停止循环'
    print(
        f'[{device_id}] [{label}] 循环条件识图结果: {template_name}, '
        f'阈值 {confidence:.2f}, 本次{"命中" if matched else "未命中"}，'
        f'动作: {action_text}'
    )
    return should_continue


def run_image_branch(device_id, step, image_paths, screenshot_path, work_dir, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    label = step_label(step, 'multi image branch')
    matched = False
    branch_cases = step.get('branchCases', [])
    reuse_parent_branch_screenshot = bool(
        step.get('reuseParentBranchScreenshot', False)
    )
    branch_screenshot_path = get_branch_screenshot_path(runtime_context)
    branch_screen = None
    if reuse_parent_branch_screenshot:
        if branch_screenshot_path:
            branch_screen = load_image_file(branch_screenshot_path)
            if branch_screen is None:
                raise RuntimeError(
                    f'无法读取可复用的分支截图: {branch_screenshot_path}'
                )
        else:
            branch_screen = adb_screenshot(device_id, screenshot_path)
            branch_screenshot_path = persist_branch_screenshot(screenshot_path)
    print(f'[{device_id}] [{label}] start image branch, conditions={len(branch_cases)}')
    for index, branch_case in enumerate(branch_cases, start=1):
        screen = branch_screen if reuse_parent_branch_screenshot else adb_screenshot(
            device_id,
            screenshot_path,
        )
        branch_label = step_label(branch_case, f'branch{index}')
        branch_confidence = float(branch_case.get('confidence', 0.68))
        if branch_case.get('recognitionMode', 'image') == 'text':
            matches = find_ocr_matches(screen, branch_case)
            branch_result = bool(matches)
            matched_text = str(matches[0].get('text', '') if matches else '')
            matched_score = float(matches[0].get('score', 0.0) if matches else 0.0)
            matched_center_x = int(matches[0].get('x', 0) if matches else 0)
            matched_center_y = int(matches[0].get('y', 0) if matches else 0)
            result_detail = (
                f'matched text={matched_text}, score={matched_score:.3f}'
                if branch_result
                else 'not matched'
            )
            print(
                f'[{device_id}] [{label}] condition {index}: {branch_label}, '
                f'text={branch_case.get("ocrTargetText", "")}, result={result_detail}'
            )
            print_log_separator(device_id, f'{label} condition {index}', result_detail)
            if branch_result:
                matched = True
                print(f'[{device_id}] [{label}] execute branch: {branch_label}')
                if not reuse_parent_branch_screenshot:
                    branch_screenshot_path = persist_branch_screenshot(
                        screenshot_path,
                    )
                child_context = build_branch_child_context(
                    runtime_context,
                    branch_screenshot_path,
                )
                child_context['matchedPositionCenter'] = {
                    'x': int(matched_center_x),
                    'y': int(matched_center_y),
                    'score': float(matched_score),
                    'templateName': matched_text,
                }
                execute_steps(
                    device_id,
                    branch_case.get('steps', []),
                    image_paths,
                    work_dir,
                    child_context,
                )
                break
            continue
        branch_images = template_images_for_branch_case(branch_case)
        print(
            f'[{device_id}] [{label}] condition {index}: {branch_label}, '
            f'images={len(branch_images)}, threshold={branch_confidence:.2f}'
        )
        branch_result = False
        matched_template_name = ''
        matched_score = 0.0
        matched_center_x = 0
        matched_center_y = 0
        for image_index, branch_image in enumerate(branch_images, start=1):
            template_path = image_path_for(branch_image, image_paths)
            branch_template_name = image_display_name(branch_image, template_path)
            found = find_template(screen, template_path, branch_confidence)
            print(
                f'[{device_id}] [{label}] condition {index} image '
                f'{image_index}/{len(branch_images)}: {branch_template_name}, '
                f'result={"matched" if found is not None else "not matched"}'
            )
            if found is not None:
                branch_result = True
                matched_template_name = branch_template_name
                matched_center_x = int(found[0])
                matched_center_y = int(found[1])
                matched_score = float(found[2])
                break
        result_detail = (
            f'matched image={matched_template_name}, score={matched_score:.3f}'
            if branch_result
            else 'not matched'
        )
        print(f'[{device_id}] [{label}] condition {index} result: {result_detail}')
        print_log_separator(device_id, f'{label} condition {index}', result_detail)
        if branch_result:
            matched = True
            print(f'[{device_id}] [{label}] execute branch: {branch_label}')
            if not reuse_parent_branch_screenshot:
                branch_screenshot_path = persist_branch_screenshot(screenshot_path)
            child_context = build_branch_child_context(
                runtime_context,
                branch_screenshot_path,
            )
            child_context['matchedPositionCenter'] = {
                'x': int(matched_center_x),
                'y': int(matched_center_y),
                'score': float(matched_score),
                'templateName': matched_template_name,
            }
            execute_steps(
                device_id,
                branch_case.get('steps', []),
                image_paths,
                work_dir,
                child_context,
            )
            break
    if not matched:
        if branch_cases and not reuse_parent_branch_screenshot:
            branch_screenshot_path = persist_branch_screenshot(screenshot_path)
        print(f'[{device_id}] [{label}] no conditions matched, execute fallback branch')
        fallback_context = build_branch_child_context(
            runtime_context,
            branch_screenshot_path,
        )
        execute_steps(
            device_id,
            step.get('fallbackChildren', []),
            image_paths,
            work_dir,
            fallback_context,
        )
    print_log_separator(device_id, label)


def step_target_device_ids(step, runtime_context):
    device_ids = runtime_context.get('deviceIds', [])
    if not isinstance(device_ids, list):
        device_ids = []
    device_ids = [str(item).strip() for item in device_ids if str(item).strip()]
    scope = str(step.get('deviceScope', 'all') or 'all').strip()
    if scope == 'first':
        return device_ids[:1]
    if scope == 'others':
        return device_ids[1:]
    return device_ids


def step_applies_to_device(step, device_id, runtime_context):
    return device_id in step_target_device_ids(step, runtime_context)


def run_game_mode_step(device_id, step, work_dir, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    label = step_label(step, '执行痒痒鼠模式')
    step_id = str(step.get('id', 'game_mode_step'))
    config_json = (step.get('gameModeConfigJson', '') or '').strip()
    if not config_json:
        raise RuntimeError('痒痒鼠模式步骤缺少参数配置')
    config = json.loads(config_json)
    if not isinstance(config, dict):
        raise RuntimeError('痒痒鼠模式步骤参数格式不正确')
    mode_name = (step.get('gameModeName', '') or config.get('mode', '') or '').strip()
    if not mode_name:
        raise RuntimeError('痒痒鼠模式步骤未选择模式')

    resolved_device_ids = step_target_device_ids(step, runtime_context)
    if not resolved_device_ids:
        raise RuntimeError('痒痒鼠模式步骤没有可执行的目标设备')

    step_errors = runtime_context.get('stepErrors')
    primary_device_id = resolved_device_ids[0] if resolved_device_ids else device_id
    if device_id == primary_device_id:
        main_mode_script_path = (runtime_context.get('mainModeScriptPath', '') or '').strip()
        if not main_mode_script_path:
            raise RuntimeError('缺少主模式脚本路径，无法执行痒痒鼠模式步骤')
        python_executable = (
            runtime_context.get('pythonExecutable', '')
            or ('python' if sys.platform.startswith('win') else 'python3')
        )
        command = [
            python_executable,
            main_mode_script_path,
            mode_name,
            str(config.get('battleTime', '0') or '0'),
            str(config.get('bottom', '-1') or '-1'),
            str(config.get('right', '-1') or '-1'),
            str(config.get('runTimes', '0') or '0'),
            ','.join(resolved_device_ids),
            str(config.get('battleTimeAdd', '0') or '0'),
            str(config.get('picCtrl', '0.68') or '0.68'),
            '0' if bool(config.get('isDebug', False)) else '1',
            '0' if bool(config.get('isKuaQuSwitchOn', False)) else '1',
            '0' if bool(config.get('isLoopToTupoSwitchOn', False)) else '1',
            '0' if bool(config.get('isLoopToTupoSwitchOn1', True)) else '1',
            '0' if bool(config.get('isLoopToTupoSwitchOn2', True)) else '1',
            '0' if bool(config.get('isLoopToTupoSwitchOn3', True)) else '1',
            str(config.get('tupoOutTime', '4') or '4'),
            '0' if bool(config.get('isTestUser', False)) else '1',
            '0' if bool(config.get('isLoopToTupoSwitchOn4', True)) else '1',
            '0' if bool(config.get('isFirstDoneTupo', False)) else '1',
            '0' if bool(config.get('isKun1SwitchOn', False)) else '1',
            '0' if bool(config.get('needCheck', False)) else '1',
        ]
        print(
            f'[{device_id}] [{label}] 开始执行痒痒鼠模式: {mode_name}, '
            f'目标设备 {", ".join(resolved_device_ids)}'
        )
        try:
            subprocess.run(command, check=True, cwd=work_dir)
            print(f'[{device_id}] [{label}] 痒痒鼠模式执行完成: {mode_name}')
        except Exception as error:
            message = f'痒痒鼠模式执行失败: {mode_name}, {error}'
            if isinstance(step_errors, dict):
                step_errors[step_id] = message
            else:
                raise RuntimeError(message) from error
    else:
        print(f'[{device_id}] [{label}] 等待主设备执行痒痒鼠模式')

    if isinstance(step_errors, dict):
        message = step_errors.get(step_id)
        if message:
            raise RuntimeError(str(message))


def ensure_sendevent_ready(device_id, touch_device_path):
    if not touch_device_path:
        raise RuntimeError('录制流程缺少触摸设备节点，无法使用 sendevent 回放')
    root_result = subprocess.run(
        ['adb', '-s', device_id, 'root'],
        check=False,
        capture_output=True,
        text=True,
    )
    root_output = '\\n'.join(
        part.strip()
        for part in [root_result.stdout or '', root_result.stderr or '']
        if part.strip()
    )
    if root_output:
        print(f'[{device_id}] [录制流程] adb root: {root_output}')
    check_result = subprocess.run(
        ['adb', '-s', device_id, 'shell', 'ls', touch_device_path],
        check=False,
        capture_output=True,
        text=True,
    )
    if check_result.returncode != 0:
        raise RuntimeError(
            f'无法访问触摸设备节点 {touch_device_path}: '
            f'{(check_result.stderr or check_result.stdout or "").strip()}'
        )


def write_sendevent_command(shell, command):
    shell.stdin.write(f'{command}\\n')
    shell.stdin.flush()


def send_pointer_reset(shell, touch_device_path):
    write_sendevent_command(shell, f'sendevent {touch_device_path} 1 330 0')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 1 325 0')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 57 4294967295')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 0 0 0')


def play_recorded_action_with_sendevent(shell, touch_device_path, action, source_size, target_size):
    action_type = action.get('type', 'tap')
    duration_ms = max(int(action.get('durationMs', 120) or 0), 0)
    hold_before_move_ms = max(int(action.get('holdBeforeMoveMs', 0) or 0), 0)
    hold_ms = 0
    if action_type == 'longPress':
        hold_ms = max(duration_ms, 350)
    elif action_type == 'longPressSwipe':
        hold_ms = max(hold_before_move_ms, 350)

    if action_type in ('tap', 'longPress'):
        move_duration_ms = 0
    elif action_type == 'longPressSwipe':
        move_duration_ms = max(duration_ms - hold_before_move_ms, 60)
    else:
        move_duration_ms = max(duration_ms, 60)

    raw_start_x = int(action.get('startX', 0) or 0)
    raw_start_y = int(action.get('startY', 0) or 0)
    raw_end_x = int(action.get('endX', 0) or 0)
    raw_end_y = int(action.get('endY', 0) or 0)
    _, _, start_x, start_y = scale_recorded_point(
        raw_start_x,
        raw_start_y,
        source_size,
        target_size,
    )
    _, _, end_x, end_y = scale_recorded_point(
        raw_end_x,
        raw_end_y,
        source_size,
        target_size,
    )

    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 47 {_pointer_slot}')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 57 {_tracking_id}')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 1 325 1')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 1 330 1')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 53 {start_x}')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 54 {start_y}')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 0 0 0')

    if hold_ms > 0:
        time.sleep(hold_ms / 1000.0)

    needs_move = start_x != end_x or start_y != end_y
    if needs_move:
        drag_path = action.get('dragPath', [])
        if isinstance(drag_path, list) and drag_path:
            for point in drag_path:
                delay_ms = max(int(point.get('delayMs', 0) or 0), 0)
                if delay_ms > 0:
                    time.sleep(delay_ms / 1000.0)
                raw_move_x = int(point.get('x', start_x) or start_x)
                raw_move_y = int(point.get('y', start_y) or start_y)
                _, _, move_x, move_y = scale_recorded_point(
                    raw_move_x,
                    raw_move_y,
                    source_size,
                    target_size,
                )
                write_sendevent_command(shell, f'sendevent {touch_device_path} 3 53 {move_x}')
                write_sendevent_command(shell, f'sendevent {touch_device_path} 3 54 {move_y}')
                write_sendevent_command(shell, f'sendevent {touch_device_path} 0 0 0')
        else:
            steps = 12
            step_delay_ms = max(int(round(move_duration_ms / steps)), 8)
            for index in range(1, steps + 1):
                progress = index / steps
                move_x = start_x + round((end_x - start_x) * progress)
                move_y = start_y + round((end_y - start_y) * progress)
                write_sendevent_command(shell, f'sendevent {touch_device_path} 3 53 {move_x}')
                write_sendevent_command(shell, f'sendevent {touch_device_path} 3 54 {move_y}')
                write_sendevent_command(shell, f'sendevent {touch_device_path} 0 0 0')
                time.sleep(step_delay_ms / 1000.0)

    send_pointer_reset(shell, touch_device_path)


def run_recorded_flow_step(device_id, step, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    label = step_label(step, '执行录制手势流程')
    flow_name = (step.get('recordedFlowName', '') or '').strip()
    if not flow_name:
        raise RuntimeError('录制手势步骤未选择任何录制流程')
    recorded_flows = runtime_context.get('recordedFlows', {})
    if not isinstance(recorded_flows, dict):
        recorded_flows = {}
    flow = recorded_flows.get(flow_name)
    if not isinstance(flow, dict):
        raise RuntimeError(f'未找到录制流程数据: {flow_name}')

    touch_device_path = (flow.get('touchDevicePath', '') or '').strip()
    actions = flow.get('actions', [])
    if not isinstance(actions, list):
        actions = []
    loop_count = int(step.get('recordedFlowLoopCount', 1) or 0)
    ensure_sendevent_ready(device_id, touch_device_path)
    source_size = recorded_flow_screen_size(flow)
    target_size = get_device_screen_size(device_id)
    if source_size and target_size and source_size != target_size:
        print(
            f'[{device_id}] [{label}] recorded resolution '
            f'{source_size[0]}x{source_size[1]}, target resolution '
            f'{target_size[0]}x{target_size[1]}; scaling replay coordinates'
        )
    current_loop = 0
    while loop_count <= 0 or current_loop < loop_count:
        current_loop += 1
        print(
            f'[{device_id}] [{label}] 开始回放第 {current_loop} 轮，'
            f'流程 {flow_name}，动作数 {len(actions)}'
        )
        shell = subprocess.Popen(
            ['adb', '-s', device_id, 'shell'],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        try:
            send_pointer_reset(shell, touch_device_path)
            for action in actions:
                delay_ms = max(int(action.get('delayMs', 0) or 0), 0)
                if delay_ms > 0:
                    time.sleep(delay_ms / 1000.0)
                play_recorded_action_with_sendevent(
                    shell,
                    touch_device_path,
                    action,
                    source_size,
                    target_size,
                )
            send_pointer_reset(shell, touch_device_path)
            if shell.stdin:
                shell.stdin.flush()
                shell.stdin.close()
            shell.wait(timeout=3)
        finally:
            if shell.poll() is None:
                shell.kill()
        print(f'[{device_id}] [{label}] 第 {current_loop} 轮录制流程回放完成')


def execute_steps(device_id, steps, image_paths, work_dir, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    coordinator = runtime_context.get('serialCoordinator')
    if coordinator is None:
        return execute_steps_uncoordinated(
            device_id,
            steps,
            image_paths,
            work_dir,
            runtime_context,
        )

    if coordinator.is_owner(device_id):
        return coordinator.run_nested(
            device_id,
            lambda: execute_steps(
                device_id,
                steps,
                image_paths,
                work_dir,
                runtime_context,
            ),
        )

    for step in steps:
        step_type = step.get('type', 'step') if isinstance(step, dict) else 'step'
        label = step_label(step, step_type)
        coordinator.run_turn(
            device_id,
            lambda current_step=step: execute_steps_uncoordinated(
                device_id,
                [current_step],
                image_paths,
                work_dir,
                runtime_context,
            ),
            label=label,
        )


def execute_steps_uncoordinated(device_id, steps, image_paths, work_dir, runtime_context=None):
    screenshot_path = os.path.join(work_dir, f'{device_id}_custom_flow_screen.png')
    runtime_context = dict(runtime_context or {})
    for step in steps:
        if not step_applies_to_device(step, device_id, runtime_context):
            label = step_label(step, step.get('type', 'step'))
            print(
                f'[{device_id}] [{label}] 按模拟器对象范围跳过 '
                f'（{step.get("deviceScope", "all")}）'
            )
            continue
        step_type = step['type']
        if step_type == 'wait':
            label = step_label(step, '等待')
            wait_min_seconds = get_step_seconds(step, 'waitMinSeconds', 'waitMinMs')
            wait_max_seconds = get_step_seconds(step, 'waitMaxSeconds', 'waitMaxMs')
            wait_seconds = choose_wait_seconds(wait_min_seconds, wait_max_seconds)
            print(
                f'[{device_id}] [{label}] 开始固定等待 '
                f'{format_seconds(wait_min_seconds)}-{format_seconds(wait_max_seconds)}s，'
                f'本次 {format_seconds(wait_seconds)}s'
            )
            sleep_with_countdown(
                device_id,
                label,
                wait_seconds,
            )
            print_log_separator(device_id, label)
        elif step_type == 'imageTap':
            run_image_tap(device_id, step, image_paths, screenshot_path)
            print_log_separator(device_id, step_label(step, '识图点击'))
        elif step_type == 'ocrTap':
            run_ocr_tap(device_id, step, screenshot_path)
            print_log_separator(device_id, step_label(step, '识图点击（文字识别）'))
        elif step_type == 'coordinateTap':
            label = step_label(step, '固定坐标点击')
            use_branch_detected_position = bool(
                step.get('useBranchDetectedPosition', False)
            )
            if use_branch_detected_position:
                matched_position = runtime_context.get('matchedPositionCenter', None)
                if not isinstance(matched_position, dict):
                    raise RuntimeError(
                        '当前固定坐标点击被设置为使用识图坐标分支中心点，但上层没有可用的识图位置'
                    )
                base_x = int(matched_position.get('x', 0))
                base_y = int(matched_position.get('y', 0))
                offset_x = int(step.get('branchPositionOffsetX', 0))
                offset_y = int(step.get('branchPositionOffsetY', 0))
                x = base_x + offset_x
                y = base_y + offset_y
                raw_x, raw_y = x, y
                print(
                    f'[{device_id}] [{label}] 使用识图中心点 ({base_x}, {base_y})，'
                    f'偏移 ({offset_x}, {offset_y})，基础点击坐标 ({raw_x}, {raw_y})'
                )
            else:
                x = int(step.get('x', 0))
                y = int(step.get('y', 0))
                raw_x, raw_y = x, y
            random_offset = max(int(step.get('randomOffsetPx', 0)), 0)
            if random_offset > 0:
                x += random.randint(-random_offset, random_offset)
                y += random.randint(-random_offset, random_offset)
                print(
                    f'[{device_id}] [{label}] 固定坐标点击: 基础坐标 ({raw_x}, {raw_y}), '
                    f'随机偏移后点击 ({x}, {y})'
                )
            else:
                print(f'[{device_id}] [{label}] 固定坐标点击: 点击位置 ({x}, {y})')
            tap(device_id, x, y)
            post_wait_min_seconds = get_step_seconds(step, 'postWaitMinSeconds', 'postWaitMinMs')
            post_wait_max_seconds = get_step_seconds(step, 'postWaitMaxSeconds', 'postWaitMaxMs')
            post_wait_seconds = choose_wait_seconds(post_wait_min_seconds, post_wait_max_seconds)
            print(
                f'[{device_id}] [{label}] 点击完成，开始等待 '
                f'{format_seconds(post_wait_min_seconds)}-{format_seconds(post_wait_max_seconds)}s，'
                f'本次 {format_seconds(post_wait_seconds)}s'
            )
            sleep_with_countdown(
                device_id,
                label,
                post_wait_seconds,
            )
            print_log_separator(device_id, label)
        elif step_type == 'pasteText':
            run_paste_text_step(device_id, step, runtime_context)
            print_log_separator(device_id, step_label(step, '粘贴文字'))
        elif step_type == 'waitImageState':
            run_wait_image_state(device_id, step, image_paths, screenshot_path)
            print_log_separator(device_id, step_label(step, '识图等待'))
        elif step_type == 'loopBlock':
            label = step_label(step, '循环块')
            loop_count = int(step.get('loopCount', 1))
            loop_mode = step.get('loopMode', 'fixedCount')
            if loop_mode == 'textLines':
                text_lines = split_text_lines(step.get('loopTextContent', ''))
                if not text_lines:
                    raise RuntimeError('按文本逐行循环至少需要一行有效文字')
                total = len(text_lines)
                for current, current_text in enumerate(text_lines, start=1):
                    print(
                        f'[{device_id}] [{label}] 开始第 {current}/{total} 次文本循环，'
                        f'当前文字字符数: {len(current_text)}'
                    )
                    child_context = dict(runtime_context)
                    child_context['currentLoopText'] = current_text
                    execute_steps(
                        device_id,
                        step.get('children', []),
                        image_paths,
                        work_dir,
                        child_context,
                    )
                    print(f'[{device_id}] [{label}] 第 {current}/{total} 次文本循环完成')
                    print_log_separator(
                        device_id,
                        label,
                        f'第 {current}/{total} 次文本循环',
                    )
                continue
            current = 0
            while True:
                if loop_mode == 'fixedCount' and loop_count > 0 and current >= loop_count:
                    break
                current += 1
                remaining = (
                    '按识图条件判断'
                    if loop_mode == 'imageCondition'
                    else ('无限' if loop_count <= 0 else str(max(loop_count - current, 0)))
                )
                total = '识图条件' if loop_mode == 'imageCondition' else ('无限' if loop_count <= 0 else str(loop_count))
                print(
                    f'[{device_id}] [{label}] 开始第 {current}/{total} 次循环，'
                    f'剩余 {remaining} 次'
                )
                execute_steps(
                    device_id,
                    step.get('children', []),
                    image_paths,
                    work_dir,
                    runtime_context,
                )
                print(f'[{device_id}] [{label}] 第 {current} 次循环完成')
                print_log_separator(device_id, label, f'第 {current} 次循环')
                if loop_mode == 'imageCondition':
                    if not should_continue_loop(device_id, step, image_paths, screenshot_path):
                        print(f'[{device_id}] [{label}] 达到识图循环停止条件，结束循环')
                        break
        elif step_type == 'flowGroup':
            label = step_label(step, '流程组')
            print(f'[{device_id}] [{label}] 开始执行流程组，子步骤 {len(step.get("children", []))} 个')
            execute_steps(
                device_id,
                step.get('children', []),
                image_paths,
                work_dir,
                runtime_context,
            )
            print_log_separator(device_id, label)
        elif step_type == 'gameMode':
            run_game_mode_step(device_id, step, work_dir, runtime_context)
            print_log_separator(device_id, step_label(step, '执行痒痒鼠模式'))
        elif step_type == 'recordedFlow':
            run_recorded_flow_step(device_id, step, runtime_context)
            print_log_separator(device_id, step_label(step, '执行录制手势流程'))
        elif step_type == 'imageBranch':
            run_image_branch(device_id, step, image_paths, screenshot_path, work_dir, runtime_context)
            continue
        elif step_type == 'imagePositionBranch':
            run_image_position_branch(
                device_id,
                step,
                image_paths,
                screenshot_path,
                work_dir,
                runtime_context,
            )
            print_log_separator(device_id, step_label(step, '识图坐标分支'))
        elif step_type == 'restartActivity':
            label = step_label(step, '重启当前Activity')
            component = (step.get('activityComponent', '') or '').strip()
            if not component:
                component = detect_current_activity(device_id)
            restart_activity(device_id, component)
            print_log_separator(device_id, label)
        elif step_type == 'shutdownComputer':
            run_shutdown_step(device_id, step)
            print_log_separator(device_id, step_label(step, '关机操作'))
        else:
            raise RuntimeError(f'不支持的步骤类型: {step_type}')


def run_device(device_id, steps, image_paths, loop_count, work_dir, runtime_context=None):
    runtime_context = dict(runtime_context or {})
    coordinator = runtime_context.get('serialCoordinator')
    adb_keyboard_state = None
    try:
        if flow_contains_paste_text_for_device(steps, device_id, runtime_context):
            if coordinator is None:
                adb_keyboard_state = prepare_adb_keyboard(device_id)
            else:
                adb_keyboard_state = coordinator.run_turn(
                    device_id,
                    lambda: prepare_adb_keyboard(device_id),
                    label='准备 ADB Keyboard',
                )
        current_loop = 0
        while loop_count <= 0 or current_loop < loop_count:
            current_loop += 1
            print(f'[{device_id}] 开始执行第 {current_loop} 轮')
            execute_steps(device_id, steps, image_paths, work_dir, runtime_context)
            print(f'[{device_id}] 第 {current_loop} 轮执行完成')
    finally:
        if adb_keyboard_state is not None:
            if coordinator is None:
                restore_adb_keyboard(device_id, adb_keyboard_state)
            else:
                coordinator.run_turn(
                    device_id,
                    lambda: restore_adb_keyboard(device_id, adb_keyboard_state),
                    label='恢复 ADB Keyboard',
                )
        if coordinator is not None:
            coordinator.finish(device_id)


def main():
    if len(sys.argv) < 2:
        raise RuntimeError('缺少配置文件路径')
    config_path = sys.argv[1]
    with open(config_path, 'r', encoding='utf-8') as file:
        config = json.load(file)
    global _mac_shutdown_pid_file
    _mac_shutdown_pid_file = config.get('shutdownPidFilePath', _mac_shutdown_pid_file)
    device_ids = config.get('deviceIds', [])
    if not device_ids:
        raise RuntimeError('缺少执行设备')
    loop_count = int(config.get('loopCount', 1))
    steps = config.get('steps', [])
    image_paths = config.get('imagePaths', {})
    recorded_flows = config.get('recordedFlows', {})
    main_mode_script_path = config.get('mainModeScriptPath', '')
    python_executable = config.get(
        'pythonExecutable',
        'python' if sys.platform.startswith('win') else 'python3',
    )
    work_dir = os.path.dirname(config_path)
    runtime_context = {
        'deviceIds': device_ids,
        'deviceCount': len(device_ids),
        'recordedFlows': recorded_flows,
        'mainModeScriptPath': main_mode_script_path,
        'pythonExecutable': python_executable,
        'stepErrors': {},
    }
    parallel_devices = bool(config.get('parallelDevices', False))
    if not parallel_devices:
        runtime_context['serialCoordinator'] = SerialDeviceCoordinator(device_ids)
    with ThreadPoolExecutor(max_workers=max(1, len(device_ids))) as executor:
        futures = [
            executor.submit(
                run_device,
                device_id,
                steps,
                image_paths,
                loop_count,
                work_dir,
                runtime_context,
            )
            for device_id in device_ids
        ]
        for future in futures:
            future.result()


if __name__ == '__main__':
    main()
''';
  }

  String _buildRecordedFlowPlaybackRunnerScript() {
    return r'''
import json
import os
import re
import subprocess
import sys
import time
import traceback

_pointer_slot = 0
_tracking_id = 100
_device_screen_size_cache = {}


def log(message):
    print(message, flush=True)


def parse_screen_size(output):
    for pattern in (r'Override size:\s*(\d+)x(\d+)', r'Physical size:\s*(\d+)x(\d+)'):
        match = re.search(pattern, output or '', re.IGNORECASE)
        if match:
            return int(match.group(1)), int(match.group(2))
    return None


def get_device_screen_size(device_id):
    cached = _device_screen_size_cache.get(device_id)
    if cached:
        return cached
    result = subprocess.run(
        ['adb', '-s', device_id, 'shell', 'wm', 'size'],
        check=False,
        capture_output=True,
        text=True,
    )
    screen_size = parse_screen_size(f'{result.stdout}\n{result.stderr}')
    if not screen_size:
        raise RuntimeError(f'Cannot read device screen size: {device_id}')
    _device_screen_size_cache[device_id] = screen_size
    return screen_size


def recorded_flow_screen_size(flow):
    width = int(flow.get('screenWidth', 0) or 0)
    height = int(flow.get('screenHeight', 0) or 0)
    if width > 0 and height > 0:
        return width, height
    return None


def clamp_tap_point(x, y, screen_size=None):
    raw_x = int(x)
    raw_y = int(y)
    if screen_size and screen_size[0] > 0 and screen_size[1] > 0:
        max_x = max(int(screen_size[0]) - 2, 0)
        max_y = max(int(screen_size[1]) - 2, 0)
        min_x = 4 if max_x >= 4 else 0
        min_y = 4 if max_y >= 4 else 0
    else:
        max_x = 1598
        max_y = 898
        min_x = 4
        min_y = 4
    clamped_x = min(max(raw_x, min_x), max_x)
    clamped_y = min(max(raw_y, min_y), max_y)
    return raw_x, raw_y, clamped_x, clamped_y


def scale_recorded_point(x, y, source_size, target_size):
    raw_x = int(x)
    raw_y = int(y)
    if (
        source_size
        and target_size
        and source_size[0] > 0
        and source_size[1] > 0
        and target_size[0] > 0
        and target_size[1] > 0
    ):
        raw_x = round(raw_x / source_size[0] * target_size[0])
        raw_y = round(raw_y / source_size[1] * target_size[1])
    return clamp_tap_point(raw_x, raw_y, target_size)


def ensure_sendevent_ready(device_id, touch_device_path):
    if not touch_device_path:
        raise RuntimeError('Recorded flow has no touch device path; cannot replay with sendevent.')
    root_result = subprocess.run(
        ['adb', '-s', device_id, 'root'],
        check=False,
        capture_output=True,
        text=True,
    )
    root_output = '\n'.join(
        part.strip()
        for part in [root_result.stdout or '', root_result.stderr or '']
        if part.strip()
    )
    if root_output:
        log(f'[{device_id}] [recorded flow] adb root: {root_output}')
    check_result = subprocess.run(
        ['adb', '-s', device_id, 'shell', 'ls', touch_device_path],
        check=False,
        capture_output=True,
        text=True,
    )
    if check_result.returncode != 0:
        raise RuntimeError(
            f'Cannot access touch device {touch_device_path}: '
            f'{(check_result.stderr or check_result.stdout or "").strip()}'
        )
    log(f'[{device_id}] sendevent replay is ready, touch device: {touch_device_path}')


def write_sendevent_command(shell, command):
    if shell.poll() is not None:
        raise RuntimeError('adb shell exited while replaying the recorded flow.')
    shell.stdin.write(f'{command}\n')
    shell.stdin.flush()


def send_pointer_reset(shell, touch_device_path):
    write_sendevent_command(shell, f'sendevent {touch_device_path} 1 330 0')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 1 325 0')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 57 4294967295')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 0 0 0')


def play_recorded_action_with_sendevent(
    shell,
    touch_device_path,
    action,
    action_index,
    action_count,
    source_size,
    target_size,
):
    action_type = action.get('type', 'tap')
    duration_ms = max(int(action.get('durationMs', 120) or 0), 0)
    hold_before_move_ms = max(int(action.get('holdBeforeMoveMs', 0) or 0), 0)
    hold_ms = 0
    if action_type == 'longPress':
        hold_ms = max(duration_ms, 350)
    elif action_type == 'longPressSwipe':
        hold_ms = max(hold_before_move_ms, 350)

    if action_type in ('tap', 'longPress'):
        move_duration_ms = 0
    elif action_type == 'longPressSwipe':
        move_duration_ms = max(duration_ms - hold_before_move_ms, 60)
    else:
        move_duration_ms = max(duration_ms, 60)

    raw_start_x = int(action.get('startX', 0) or 0)
    raw_start_y = int(action.get('startY', 0) or 0)
    raw_end_x = int(action.get('endX', 0) or 0)
    raw_end_y = int(action.get('endY', 0) or 0)
    _, _, start_x, start_y = scale_recorded_point(
        raw_start_x,
        raw_start_y,
        source_size,
        target_size,
    )
    _, _, end_x, end_y = scale_recorded_point(
        raw_end_x,
        raw_end_y,
        source_size,
        target_size,
    )
    drag_path = action.get('dragPath', [])
    drag_point_count = len(drag_path) if isinstance(drag_path, list) else 0
    log(
        f'  action {action_index}/{action_count}: type={action_type}, '
        f'delay={int(action.get("delayMs", 0) or 0)}ms, '
        f'from=({start_x},{start_y}), to=({end_x},{end_y}), '
        f'duration={duration_ms}ms, dragPoints={drag_point_count}'
    )

    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 47 {_pointer_slot}')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 57 {_tracking_id}')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 1 325 1')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 1 330 1')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 53 {start_x}')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 3 54 {start_y}')
    write_sendevent_command(shell, f'sendevent {touch_device_path} 0 0 0')

    if hold_ms > 0:
        time.sleep(hold_ms / 1000.0)

    needs_move = start_x != end_x or start_y != end_y
    if needs_move:
        if drag_point_count > 0:
            for point in drag_path:
                delay_ms = max(int(point.get('delayMs', 0) or 0), 0)
                if delay_ms > 0:
                    time.sleep(delay_ms / 1000.0)
                raw_move_x = int(point.get('x', start_x) or start_x)
                raw_move_y = int(point.get('y', start_y) or start_y)
                _, _, move_x, move_y = scale_recorded_point(
                    raw_move_x,
                    raw_move_y,
                    source_size,
                    target_size,
                )
                write_sendevent_command(shell, f'sendevent {touch_device_path} 3 53 {move_x}')
                write_sendevent_command(shell, f'sendevent {touch_device_path} 3 54 {move_y}')
                write_sendevent_command(shell, f'sendevent {touch_device_path} 0 0 0')
        else:
            steps = 12
            step_delay_ms = max(int(round(move_duration_ms / steps)), 8)
            for index in range(1, steps + 1):
                progress = index / steps
                move_x = start_x + round((end_x - start_x) * progress)
                move_y = start_y + round((end_y - start_y) * progress)
                write_sendevent_command(shell, f'sendevent {touch_device_path} 3 53 {move_x}')
                write_sendevent_command(shell, f'sendevent {touch_device_path} 3 54 {move_y}')
                write_sendevent_command(shell, f'sendevent {touch_device_path} 0 0 0')
                time.sleep(step_delay_ms / 1000.0)

    send_pointer_reset(shell, touch_device_path)


def play_flow(device_id, flow, flow_index, flow_count):
    flow_name = (flow.get('name', '') or f'flow_{flow_index}').strip()
    touch_device_path = (flow.get('touchDevicePath', '') or '').strip()
    actions = flow.get('actions', [])
    if not isinstance(actions, list):
        actions = []
    log(f'[{device_id}] flow {flow_index}/{flow_count}: {flow_name}, actions={len(actions)}')
    ensure_sendevent_ready(device_id, touch_device_path)
    source_size = recorded_flow_screen_size(flow)
    target_size = get_device_screen_size(device_id)
    if source_size and target_size and source_size != target_size:
        log(
            f'[{device_id}] recorded resolution {source_size[0]}x{source_size[1]}, '
            f'target resolution {target_size[0]}x{target_size[1]}; scaling replay coordinates'
        )
    shell = subprocess.Popen(
        ['adb', '-s', device_id, 'shell'],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    try:
        send_pointer_reset(shell, touch_device_path)
        for action_index, action in enumerate(actions, start=1):
            delay_ms = max(int(action.get('delayMs', 0) or 0), 0)
            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)
            play_recorded_action_with_sendevent(
                shell,
                touch_device_path,
                action,
                action_index,
                len(actions),
                source_size,
                target_size,
            )
        send_pointer_reset(shell, touch_device_path)
        if shell.stdin:
            shell.stdin.flush()
            shell.stdin.close()
        shell.wait(timeout=3)
    finally:
        if shell.poll() is None:
            shell.kill()
    log(f'[{device_id}] flow completed: {flow_name}')


def main():
    if len(sys.argv) < 2:
        raise RuntimeError('Missing config file path.')
    config_path = sys.argv[1]
    with open(config_path, 'r', encoding='utf-8') as file:
        config = json.load(file)
    device_id = (config.get('deviceId', '') or '').strip()
    if not device_id:
        raise RuntimeError('Missing target device.')
    loop_count = int(config.get('loopCount', 1) or 0)
    flows = config.get('flows', [])
    if not isinstance(flows, list) or not flows:
        raise RuntimeError('No recorded flows to replay.')

    log(f'[{device_id}] recorded flow playback started')
    log(f'[{device_id}] flow count={len(flows)}, loop count={"infinite" if loop_count <= 0 else loop_count}')
    current_loop = 0
    while loop_count <= 0 or current_loop < loop_count:
        current_loop += 1
        log(f'[{device_id}] queue loop {current_loop} started')
        for flow_index, flow in enumerate(flows, start=1):
            play_flow(device_id, flow, flow_index, len(flows))
        log(f'[{device_id}] queue loop {current_loop} completed')
    log(f'[{device_id}] recorded flow playback completed')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        log('Playback cancelled by terminal close or keyboard interrupt.')
        raise
    except Exception:
        traceback.print_exc()
        raise
''';
  }

  String _quoteWindowsBatchArg(String value) {
    return '"${value.replaceAll('"', '""')}"';
  }

  Future<String> _createWindowsLauncherScript({
    required Directory workDir,
    required String fileName,
    required List<String> commandArgs,
    String completionMessage = 'Execution finished. Press any key to exit...',
  }) async {
    final launcherFile = File(p.join(workDir.path, fileName));
    final commandLine = commandArgs.map(_quoteWindowsBatchArg).join(' ');
    await launcherFile.writeAsString(
      '@echo off\r\n'
      'cd /d ${_quoteWindowsBatchArg(Directory.current.path)}\r\n'
      '$commandLine\r\n'
      'echo.\r\n'
      'echo $completionMessage\r\n'
      'pause >nul\r\n',
      encoding: systemEncoding,
    );
    return launcherFile.path;
  }

  String _mainModeScriptAssetPath() {
    return !_isDebug
        ? 'scripts/phone_click_simulator_more_enc.py'
        : 'scripts/phone_click_simulator_more.py';
  }

  /// 编辑期的按步骤提示（规则见 lib/custom_flow_lint.dart，与运行器对齐）。
  CustomFlowLintContext get _customFlowLintContext => CustomFlowLintContext(
    windowsClientMode: _isWindowsClientMode,
    availableRecordedFlows: _savedFlows.toSet(),
    fileExists: (String path) => File(path).existsSync(),
  );

  /// 顶层第 index 个步骤（含嵌套）自己的问题。
  List<CustomFlowIssue> _customFlowIssuesForStep(int index) {
    if (index < 0 || index >= _customFlowSteps.length) {
      return const <CustomFlowIssue>[];
    }
    return lintCustomFlowStep(
      _customFlowSteps[index],
      _customFlowLintContext,
      location: '第 ${index + 1} 步',
    );
  }

  int _customFlowProblemCount() {
    int count = 0;
    for (int index = 0; index < _customFlowSteps.length; index++) {
      count += _customFlowIssuesForStep(index).length;
    }
    return count;
  }

  String get _customFlowIssueSummary => describeCustomFlowIssues(
    lintCustomFlowSteps(_customFlowSteps, _customFlowLintContext),
  );

  /// 写运行器要读的配置（执行与「流程自检」共用，避免两份字段定义漂移）。
  Future<Map<String, dynamic>> _buildCustomFlowConfigMap({
    required List<String> deviceIds,
    required int loopCount,
    required Directory workDir,
    required String pythonExecutable,
    required String mainModeScriptPath,
    required String shutdownPidFilePath,
  }) async {
    final imagePaths = await _exportCustomFlowTemplates(
      workDir,
      _customFlowSteps,
    );
    final recordedFlows = await _exportRecordedFlowsForCustomFlow(
      _customFlowSteps,
    );
    return {
      'deviceIds': deviceIds,
      'loopCount': loopCount,
      'parallelDevices': _customFlowParallelExecution,
      'steps': _customFlowSteps.map((item) => item.toJson()).toList(),
      'imagePaths': imagePaths,
      'recordedFlows': recordedFlows,
      'mainModeScriptPath': mainModeScriptPath,
      'shutdownPidFilePath': shutdownPidFilePath,
      'pythonExecutable': pythonExecutable,
    };
  }

  /// 时空客户端：只校验流程文件，不连窗口、不点游戏。
  ///
  /// 等价于在命令行跑 `flow_runner_win.py <config> --dry-run`：
  /// 在真点游戏之前先把"模板图丢了 / 引用了不存在的录制流程 / 用了不支持的步骤"
  /// 这类问题挡下来。
  Future<void> _selfCheckCustomFlow() async {
    if (_customFlowSteps.isEmpty) {
      setState(() {
        _output += '请先添加至少一个自定义流程步骤，再自检。\n';
        _scrollToBottom();
      });
      return;
    }
    if (_customFlowContainsGameMode(_customFlowSteps)) {
      await _showFlowInterruptionDialog(
        title: '流程自检不通过',
        message: '流程里包含「痒痒鼠模式」步骤，时空客户端版本不支持，请先删除该步骤。',
      );
      return;
    }
    late final String pythonExecutable;
    late final WinWorkspace workspace;
    try {
      pythonExecutable = await _resolvePythonExecutable();
      workspace = await _resolveWindowsWorkspace();
      if (!workspace.isAvailable) {
        throw Exception(workspace.missingHint);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      await _showFlowInterruptionDialog(
        title: '无法自检流程',
        message: _readableError(e),
      );
      return;
    }
    setState(() {
      _output += '开始自检流程文件（不会连接窗口，也不会点击游戏）\n';
      _scrollToBottom();
    });
    try {
      final tempDir = await getTemporaryDirectory();
      final workDir = Directory(
        '${tempDir.path}/custom_flow_check_${DateTime.now().millisecondsSinceEpoch}',
      );
      await workDir.create(recursive: true);
      final Map<String, dynamic> config = await _buildCustomFlowConfigMap(
        deviceIds: _customFlowSelfCheckDeviceIds(),
        loopCount: int.tryParse(_customFlowLoopController.text.trim()) ?? 1,
        workDir: workDir,
        pythonExecutable: pythonExecutable,
        mainModeScriptPath: '',
        shutdownPidFilePath: await _customFlowMacShutdownPidFilePath(),
      );
      final FlowSelfCheckResult result = await WinFlowSelfCheck(
        pythonExecutable: pythonExecutable,
        scriptPath: workspace.flowRunnerScript,
        workingDirectory: workspace.root,
      ).check(config: config, workDir: workDir);
      await _showSelfCheckResult(title: '流程自检', result: result);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '流程自检出错：${_readableError(e)}\n';
        _scrollToBottom();
      });
    }
  }

  /// 自检结果的统一展示：输出原文进输出区，不通过时弹窗提醒。
  Future<void> _showSelfCheckResult({
    required String title,
    required FlowSelfCheckResult result,
  }) async {
    if (!mounted) {
      return;
    }
    setState(() {
      final String text = result.output;
      if (text.trim().isNotEmpty) {
        _output += text.endsWith('\n') ? text : '$text\n';
      }
      _output += result.ok
          ? '$title通过，可以执行。\n'
          : '$title未通过，请按上面的提示修改后重试。\n';
      _scrollToBottom();
    });
    if (result.ok) {
      return;
    }
    final String detail = result.problems.isEmpty
        ? '详细原因见下方输出区。'
        : result.problems.take(3).join('\n');
    await _showFlowInterruptionDialog(
      title: '$title未通过',
      message: '配置文件本身有问题，执行到对应步骤一定会失败：\n$detail',
    );
  }

  /// 时空客户端：录制流程回放前先离线自检一遍。
  Future<void> _selfCheckRecordedFlows() async {
    final List<String> playbackQueue = _selectedPlaybackFlows.isNotEmpty
        ? List<String>.from(_selectedPlaybackFlows)
        : (_selectedFlowName.isEmpty ? <String>[] : <String>[_selectedFlowName]);
    if (playbackQueue.isEmpty) {
      setState(() {
        _output += '请先把录制流程添加到回放列表，再自检。\n';
        _scrollToBottom();
      });
      return;
    }
    late final String pythonExecutable;
    late final WinWorkspace workspace;
    try {
      pythonExecutable = await _resolvePythonExecutable();
      workspace = await _resolveWindowsWorkspace();
      if (!workspace.isAvailable) {
        throw Exception(workspace.missingHint);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      await _showFlowInterruptionDialog(
        title: '无法自检录制流程',
        message: _readableError(e),
      );
      return;
    }
    setState(() {
      _output += '开始自检录制流程（不会连接窗口，也不会回放）\n';
      _scrollToBottom();
    });
    try {
      final List<RecordedFlow> flows = <RecordedFlow>[];
      for (final String flowName in playbackQueue) {
        final RecordedFlow? flow = await _touchRecorderService.loadFlow(
          flowName,
        );
        if (flow == null) {
          setState(() {
            _output += '流程不存在：$flowName，请先刷新流程列表。\n';
            _scrollToBottom();
          });
          return;
        }
        flows.add(flow);
      }
      // 先在本地过一遍（不需要 Python 也能给结论），再让运行器自检一次
      final List<RecordedFlowIssue> localIssues = lintRecordedFlows(flows);
      setState(() {
        if (localIssues.isEmpty) {
          _output += '本地检查：${flows.length} 条录制流程没有发现问题。\n';
        } else {
          _output += '本地检查：${describeRecordedFlowIssues(localIssues)}\n';
          for (final issue in localIssues) {
            _output += '  ${issue.isError ? '⚠' : '提醒'} '
                '${issue.flowName} ${issue.location}：${issue.message}\n';
          }
        }
        _scrollToBottom();
      });
      final tempDir = await getTemporaryDirectory();
      final workDir = Directory(
        '${tempDir.path}/recorded_flow_check_${DateTime.now().millisecondsSinceEpoch}',
      );
      await workDir.create(recursive: true);
      final FlowSelfCheckResult result = await WinFlowSelfCheck(
        pythonExecutable: pythonExecutable,
        scriptPath: workspace.recordRunnerScript,
        workingDirectory: workspace.root,
      ).check(
        config: _buildRecordedFlowConfigMap(
          deviceId: flows.first.deviceId,
          loopCount: int.tryParse(_flowLoopController.text.trim()) ?? 1,
          flows: flows,
        ),
        workDir: workDir,
        fileName: 'recorded_flow_config.json',
      );
      await _showSelfCheckResult(title: '录制流程自检', result: result);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '录制流程自检出错：${_readableError(e)}\n';
        _scrollToBottom();
      });
    }
  }

  /// 录制流程回放配置（回放与自检共用）。
  Map<String, dynamic> _buildRecordedFlowConfigMap({
    required String deviceId,
    required int loopCount,
    required List<RecordedFlow> flows,
  }) {
    return {
      'deviceId': deviceId,
      'loopCount': loopCount,
      'flows': flows.map((item) => item.toJson()).toList(),
    };
  }

  /// 自检用的设备列表：不连窗口，只写进配置文件让运行器认得出来。
  List<String> _customFlowSelfCheckDeviceIds() {
    if (_connectedDevices.isNotEmpty) {
      return _connectedDevices;
    }
    return const <String>['win:0'];
  }

  Future<void> _runCustomFlow() async {
    final deviceResolution = await _prepareFlowDevices(
      dialogTitle: '无法执行自定义流程',
      operationLabel: '执行自定义流程',
      requirement: FlowDeviceRequirement.multiple,
      requiredDeviceIds: _collectCustomFlowStepDeviceIds(_customFlowSteps),
    );
    if (deviceResolution == null) {
      return;
    }
    final deviceIds = deviceResolution.deviceIds;
    if (_customFlowSteps.isEmpty) {
      setState(() {
        _output += '请先添加至少一个自定义流程步骤。\n';
        _scrollToBottom();
      });
      return;
    }
    final hasSupportedResolution = await _ensureSupportedEmulatorResolution(
      deviceIds: _getCustomFlowResolutionCheckDevices(deviceIds),
      featureName: '执行自定义流程',
    );
    if (!hasSupportedResolution || !mounted) {
      return;
    }
    if (!_isWindowsClientMode && customFlowContainsPasteText(_customFlowSteps)) {
      try {
        final ready = await _ensureAdbKeyboardInstalled(deviceIds);
        if (!ready || !mounted) {
          return;
        }
      } catch (e) {
        if (!mounted) {
          return;
        }
        setState(() {
          _output += '检查或安装 ADB Keyboard 失败：$e\n';
          _scrollToBottom();
        });
        return;
      }
    }
    if (_isWindowsClientMode && _customFlowContainsGameMode(_customFlowSteps)) {
      await _showFlowInterruptionDialog(
        title: '无法执行自定义流程',
        message: '流程里包含「痒痒鼠模式」步骤，时空客户端版本不支持，请先删除该步骤。',
      );
      return;
    }
    late final String pythonExecutable;
    try {
      pythonExecutable = await _resolvePythonExecutable();
      if (_customFlowUsesTextRecognition(_customFlowSteps)) {
        final ready = await _ensureRapidOcrAvailable(pythonExecutable);
        if (!ready || !mounted) {
          setState(() {
            _output += '已取消执行：文字识别模式需要先安装 RapidOCR。\n';
            _scrollToBottom();
          });
          return;
        }
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '检查 Python 或 RapidOCR 依赖失败：$e\n';
        _scrollToBottom();
      });
      return;
    }

    final loopCount = int.tryParse(_customFlowLoopController.text.trim()) ?? 1;
    final executionMode = _customFlowParallelExecution ? '并行' : '串行';
    setState(() {
      _output +=
          '开始执行自定义流程，目标设备：${deviceIds.join(', ')}，循环次数：${loopCount <= 0 ? '无限' : loopCount}，执行模式：$executionMode\n';
      _scrollToBottom();
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final workDir = Directory(
        '${tempDir.path}/custom_flow_${DateTime.now().millisecondsSinceEpoch}',
      );
      await workDir.create(recursive: true);
      final mainModeScriptContent = await rootBundle.loadString(
        _mainModeScriptAssetPath(),
      );
      final mainModeRunnerFile = File('${workDir.path}/main_mode_runner.py');
      await mainModeRunnerFile.writeAsString(
        !_isDebug
            ? EncryptUtil().decrypt(mainModeScriptContent)
            : mainModeScriptContent,
      );
      if (_customFlowContainsGameMode(_customFlowSteps)) {
        await _exportBuiltInImagesForGameModeRunner(workDir);
      }
      final shutdownPidFilePath = await _customFlowMacShutdownPidFilePath();
      final configFile = File('${workDir.path}/custom_flow_config.json');
      await configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(
          await _buildCustomFlowConfigMap(
            deviceIds: deviceIds,
            loopCount: loopCount,
            workDir: workDir,
            pythonExecutable: pythonExecutable,
            mainModeScriptPath: mainModeRunnerFile.path,
            shutdownPidFilePath: shutdownPidFilePath,
          ),
        ),
      );
      final File runnerFile;
      if (_isWindowsClientMode) {
        final workspace = await _resolveWindowsWorkspace();
        runnerFile = File(workspace.flowRunnerScript);
      } else {
        runnerFile = File('${workDir.path}/custom_flow_runner.py');
        await runnerFile.writeAsString(_buildCustomFlowRunnerScript());
      }

      ProcessResult result;
      String terminalCommand;
      List<String> terminalArgs;

      if (Platform.isWindows) {
        final launcherPath = await _createWindowsLauncherScript(
          workDir: workDir,
          fileName: 'run_custom_flow.cmd',
          commandArgs: [pythonExecutable, runnerFile.path, configFile.path],
        );
        terminalCommand = 'cmd.exe';
        terminalArgs = [
          '/c',
          'start',
          '',
          'cmd.exe',
          '/k',
          'call',
          launcherPath,
        ];
      } else if (Platform.isMacOS) {
        final shellScriptPath = '${workDir.path}/run_custom_flow.sh';
        final shellScript = File(shellScriptPath);
        await shellScript.writeAsString('''#!/bin/bash
$pythonExecutable "${runnerFile.path}" "${configFile.path}"
echo "\\n自定义流程执行完成，按回车键退出..."
read -r
''');
        await Process.run('chmod', ['+x', shellScriptPath]);
        terminalCommand = 'open';
        terminalArgs = ['-a', 'Terminal', shellScriptPath];
      } else {
        terminalCommand = 'gnome-terminal';
        terminalArgs = [
          '--',
          pythonExecutable,
          runnerFile.path,
          configFile.path,
        ];
      }

      result = await Process.run(
        terminalCommand,
        terminalArgs,
        runInShell: Platform.isWindows,
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _output += '自定义流程终端已启动，退出码：${result.exitCode}\n';
        if (result.stderr.toString().isNotEmpty) {
          _output += '标准错误: ${result.stderr}\n';
        }
        _scrollToBottom();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      final message = '执行自定义流程失败: ${_readableError(e)}';
      if (_looksLikeDeviceFailure(e)) {
        await _showFlowInterruptionDialog(title: '无法执行自定义流程', message: message);
      } else {
        setState(() {
          _output += '$message\n';
          _scrollToBottom();
        });
      }
    }
  }

  Future<void> _startFlowRecording() async {
    final deviceResolution = await _prepareFlowDevices(
      dialogTitle: '无法开始录制',
      operationLabel: '开始录制',
      requirement: FlowDeviceRequirement.single,
    );
    if (deviceResolution == null) {
      return;
    }
    final deviceId = deviceResolution.deviceIds.single;

    final hasSupportedResolution = await _ensureSupportedEmulatorResolution(
      deviceIds: [deviceId],
      featureName: '手势录制',
    );
    if (!hasSupportedResolution || !mounted) {
      return;
    }

    final dragPathSampleIntervalMs =
        int.tryParse(_flowSampleIntervalController.text.trim()) ?? 100;

    try {
      setState(() {
        _isRecordingFlow = true;
        _activeRecordingDeviceId = deviceId;
        _output +=
            '开始录制流程，目标设备：$deviceId，拖拽采样间隔：${dragPathSampleIntervalMs.clamp(8, 1000)}ms\n';
        _scrollToBottom();
      });
      if (_isWindowsClientMode) {
        final service = await _ensureWindowsDeviceService();
        await _touchRecorderService.startWindowsRecording(
          (int sampleIntervalMs) =>
              service.recordStart(deviceId, sampleIntervalMs: sampleIntervalMs),
          dragPathSampleIntervalMs: dragPathSampleIntervalMs,
        );
      } else {
        await _touchRecorderService.startRecording(
          deviceId,
          dragPathSampleIntervalMs: dragPathSampleIntervalMs,
        );
      }
      setState(() {
        _output += _isWindowsClientMode
            ? '请在客户端窗口上完成点击或拖拽，结束后点击“停止录制”。'
                  '（录制过程中请不要切到别的窗口，否则可能录到其他程序的操作）\n'
            : '请在设备上完成点击或拖拽，结束后点击“停止录制”。\n';
        _scrollToBottom();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      final message = '启动录制失败: ${_readableError(e)}';
      if (_looksLikeDeviceFailure(e)) {
        setState(() {
          _isRecordingFlow = false;
          _activeRecordingDeviceId = null;
        });
        await _showFlowInterruptionDialog(title: '无法开始录制', message: message);
      } else {
        setState(() {
          _isRecordingFlow = false;
          _activeRecordingDeviceId = null;
          _output += '$message\n';
          _scrollToBottom();
        });
      }
    }
  }

  Future<void> _stopFlowRecording() async {
    var deviceId = _activeRecordingDeviceId?.trim();
    if (deviceId == null || deviceId.isEmpty) {
      final deviceResolution = await _prepareFlowDevices(
        dialogTitle: '无法停止录制',
        operationLabel: '停止录制',
        requirement: FlowDeviceRequirement.single,
      );
      if (deviceResolution == null) {
        if (mounted) {
          setState(() {
            _isRecordingFlow = false;
          });
        }
        return;
      }
      deviceId = deviceResolution.deviceIds.single;
    }

    final flowName = _flowNameController.text.trim();
    if (flowName.isEmpty) {
      setState(() {
        _output += '请先填写流程名称，再停止录制保存。\n';
        _scrollToBottom();
      });
      return;
    }

    try {
      late final RecordingSessionResult result;
      if (_isWindowsClientMode) {
        final service = await _ensureWindowsDeviceService();
        result = await _touchRecorderService.stopWindowsRecording(
          flowName: flowName,
          deviceId: deviceId,
          recordStop: service.recordStop,
        );
      } else {
        result = await _touchRecorderService.stopRecording(
          flowName: flowName,
          deviceId: deviceId,
        );
      }
      await _reloadSavedFlows();
      setState(() {
        _isRecordingFlow = false;
        _activeRecordingDeviceId = null;
        _selectedFlowName = result.flow.name;
        _savePreferences();
        _output +=
            '录制完成，已保存流程：${result.flow.name}，动作数：${result.flow.actions.length}\n';
        _output += '保存路径：${result.filePath}\n';
        _scrollToBottom();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      final message = '停止录制失败: ${_readableError(e)}';
      if (_looksLikeDeviceFailure(e)) {
        setState(() {
          _isRecordingFlow = false;
          _activeRecordingDeviceId = null;
        });
        await _showFlowInterruptionDialog(title: '无法停止录制', message: message);
      } else {
        setState(() {
          _isRecordingFlow = false;
          _activeRecordingDeviceId = null;
          _output += '$message\n';
          _scrollToBottom();
        });
      }
    }
  }

  String _playbackDeviceWorkDirTag(String deviceId) {
    final tag = deviceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return tag.isEmpty ? 'device' : tag;
  }

  Future<void> _launchRecordedFlowPlaybackTerminal({
    required String deviceId,
    required int loopCount,
    required List<RecordedFlow> flows,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final workDir = Directory(
      p.join(
        tempDir.path,
        'recorded_flow_${_playbackDeviceWorkDirTag(deviceId)}_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await workDir.create(recursive: true);
    final configFile = File(p.join(workDir.path, 'recorded_flow_config.json'));
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        _buildRecordedFlowConfigMap(
          deviceId: deviceId,
          loopCount: loopCount,
          flows: flows,
        ),
      ),
    );
    final File runnerFile;
    if (_isWindowsClientMode) {
      final workspace = await _resolveWindowsWorkspace();
      runnerFile = File(workspace.recordRunnerScript);
    } else {
      runnerFile = File(p.join(workDir.path, 'recorded_flow_runner.py'));
      await runnerFile.writeAsString(_buildRecordedFlowPlaybackRunnerScript());
    }

    final pythonExecutable = Platform.isWindows ? 'python' : 'python3';
    String terminalCommand;
    List<String> terminalArgs;

    if (Platform.isWindows) {
      final launcherPath = await _createWindowsLauncherScript(
        workDir: workDir,
        fileName: 'run_recorded_flow.cmd',
        commandArgs: [pythonExecutable, runnerFile.path, configFile.path],
        completionMessage:
            'Recorded flow playback finished. Press any key to exit...',
      );
      terminalCommand = 'cmd.exe';
      terminalArgs = ['/c', 'start', '', 'cmd.exe', '/k', 'call', launcherPath];
    } else if (Platform.isMacOS) {
      final shellScriptPath = p.join(workDir.path, 'run_recorded_flow.sh');
      final shellScript = File(shellScriptPath);
      await shellScript.writeAsString('''#!/bin/bash
"$pythonExecutable" "${runnerFile.path}" "${configFile.path}"
echo "\\nRecorded flow playback finished. Press Return to exit..."
read -r
''');
      await Process.run('chmod', ['+x', shellScriptPath]);
      terminalCommand = 'open';
      terminalArgs = ['-a', 'Terminal', shellScriptPath];
    } else {
      terminalCommand = 'gnome-terminal';
      terminalArgs = ['--', pythonExecutable, runnerFile.path, configFile.path];
    }

    final process = await Process.start(
      terminalCommand,
      terminalArgs,
      runInShell: Platform.isWindows,
    );
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(process.exitCode);
  }

  Future<void> _playSelectedFlow() async {
    final playbackQueue = _selectedPlaybackFlows.isNotEmpty
        ? List<String>.from(_selectedPlaybackFlows)
        : (_selectedFlowName.isEmpty ? <String>[] : [_selectedFlowName]);
    if (playbackQueue.isEmpty) {
      setState(() {
        _output += '请先添加至少一个待回放流程。\n';
        _scrollToBottom();
      });
      return;
    }

    final deviceResolution = await _prepareFlowDevices(
      dialogTitle: '无法开始回放',
      operationLabel: '开始回放',
      requirement: FlowDeviceRequirement.multiple,
    );
    if (deviceResolution == null) {
      return;
    }
    final deviceIds = deviceResolution.deviceIds;
    final hasSupportedResolution = await _ensureSupportedEmulatorResolution(
      deviceIds: deviceIds,
      featureName: '手势回放',
    );
    if (!hasSupportedResolution || !mounted) {
      return;
    }

    try {
      final flows = <RecordedFlow>[];
      for (final flowName in playbackQueue) {
        final flow = await _touchRecorderService.loadFlow(flowName);
        if (flow == null) {
          setState(() {
            _output += '流程不存在：$flowName，请先刷新流程列表。\n';
            _scrollToBottom();
          });
          return;
        }
        flows.add(flow);
      }

      if (flows.isEmpty) {
        setState(() {
          _output += '没有可回放的流程。\n';
          _scrollToBottom();
        });
        return;
      }

      final loopCount = int.tryParse(_flowLoopController.text.trim()) ?? 1;
      setState(() {
        _output +=
            '准备启动录制流程回放，目标设备：${deviceIds.join(', ')}，循环次数：${loopCount <= 0 ? '无限' : loopCount}\n';
        _output += '回放顺序：${flows.map((item) => item.name).join(' -> ')}\n';
        _scrollToBottom();
      });

      final launchErrors = <String>[];
      for (final deviceId in deviceIds) {
        try {
          await _launchRecordedFlowPlaybackTerminal(
            deviceId: deviceId,
            loopCount: loopCount,
            flows: flows,
          );
          if (!mounted) {
            return;
          }
          setState(() {
            _output += '[$deviceId] 录制流程回放终端已启动。\n';
            _scrollToBottom();
          });
        } catch (e) {
          launchErrors.add('[$deviceId] ${_readableError(e)}');
        }
      }

      if (!mounted) {
        return;
      }
      if (launchErrors.isEmpty) {
        setState(() {
          _output +=
              '已为 ${deviceIds.length} 个设备启动录制流程回放终端；关闭对应命令行窗口即可停止对应设备回放。\n';
          _scrollToBottom();
        });
      } else {
        await _showFlowInterruptionDialog(
          title: '无法开始回放',
          message: '部分设备回放终端启动失败：\n${launchErrors.join('\n')}',
        );
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      final message = '回放流程失败: ${_readableError(e)}';
      if (_looksLikeDeviceFailure(e)) {
        await _showFlowInterruptionDialog(title: '无法开始回放', message: message);
      } else {
        setState(() {
          _output += '$message\n';
          _scrollToBottom();
        });
      }
    }
  }

  Future<void> _deleteSelectedFlow() async {
    if (_selectedFlowName.isEmpty) {
      setState(() {
        _output += '请先选择一个已保存流程，再执行删除。\n';
        _scrollToBottom();
      });
      return;
    }

    final flowName = _selectedFlowName;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除录制流程'),
        content: Text('确认删除本地流程“$flowName”吗？删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.blue)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      final deleted = await _touchRecorderService.deleteFlow(flowName);
      await _reloadSavedFlows();
      if (!mounted) {
        return;
      }
      setState(() {
        if (deleted) {
          _output += '已删除本地流程：$flowName\n';
        } else {
          _output += '删除失败：未找到流程 $flowName\n';
        }
        _scrollToBottom();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '删除流程失败: $e\n';
        _scrollToBottom();
      });
    }
  }

  Future<void> _exportSelectedRecordedFlow() async {
    if (_selectedFlowName.isEmpty) {
      setState(() {
        _output += '请先选择一个已保存流程，再导出。\n';
        _scrollToBottom();
      });
      return;
    }
    try {
      final flow = await _touchRecorderService.loadFlow(_selectedFlowName);
      if (flow == null) {
        setState(() {
          _output += '未找到录制流程：$_selectedFlowName\n';
          _scrollToBottom();
        });
        return;
      }
      final location = await getSaveLocation(
        suggestedName:
            '${flow.name}.${TouchRecorderService.exportFileExtension}',
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'recorded flow package',
            extensions: [TouchRecorderService.exportFileExtension],
          ),
        ],
      );
      if (location == null) {
        return;
      }
      await _touchRecorderService.exportFlowPackage(
        flow: flow,
        exportPath: location.path,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '已导出录制流程：${flow.name}\n';
        _output += '导出文件：${location.path}\n';
        _scrollToBottom();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '导出录制流程失败: $e\n';
        _scrollToBottom();
      });
    }
  }

  Future<void> _importRecordedFlow() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'recorded flow package',
          extensions: [TouchRecorderService.exportFileExtension, 'json'],
        ),
      ],
    );
    if (file == null) {
      return;
    }
    try {
      final importedFlow = await _touchRecorderService.importFlowPackage(
        file.path,
      );
      await _reloadSavedFlows();
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedFlowName = importedFlow.name;
        _flowNameController.text = importedFlow.name;
        _savePreferences();
        _output += '已导入录制流程：${importedFlow.name}\n';
        _output += '导入来源：${file.path}\n';
        _scrollToBottom();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output += '导入录制流程失败: $e\n';
        _scrollToBottom();
      });
    }
  }

  Future<_RecordedFlowConversionDialogResult?>
  _showRecordedFlowConversionDialog(RecordedFlow recordedFlow) async {
    final formKey = GlobalKey<FormState>();
    final randomOffsetController = TextEditingController(text: '5');
    final waitVariationController = TextEditingController(text: '2');
    var isConverting = false;
    SavedCustomFlowResult? savedResult;
    RecordedFlowConversionResult? conversionResult;
    Object? conversionError;

    try {
      return await showAdaptiveDialog<_RecordedFlowConversionDialogResult>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final hasResult = savedResult != null && conversionResult != null;
            return PopScope(
              canPop: !isConverting,
              child: AlertDialog(
                title: Text(
                  isConverting
                      ? '正在转换录制流程'
                      : hasResult
                      ? '转换成功'
                      : conversionError != null
                      ? '转换失败'
                      : '转换为固定点击流程',
                ),
                content: SizedBox(
                  width: 520,
                  child: isConverting
                      ? const Row(
                          children: [
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                            SizedBox(width: 16),
                            Expanded(child: Text('正在读取点击坐标并生成自定义流程，请稍候...')),
                          ],
                        )
                      : hasResult
                      ? Text(
                          '已生成自定义流程“${savedResult!.flow.name}”。\n'
                          '固定点击：${conversionResult!.convertedTapCount} 个\n'
                          '跳过其他动作：${conversionResult!.skippedActionCount} 个\n'
                          '保存路径：${savedResult!.filePath}',
                        )
                      : conversionError != null
                      ? Text('录制流程转换失败：$conversionError')
                      : Form(
                          key: formKey,
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '来源录制流程：${recordedFlow.name}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '只转换普通点击并原样保留录制坐标；长按、滑动等动作会被跳过，但它们占用的时间会计入相邻点击之间的等待。',
                                  style: TextStyle(color: Colors.blueGrey),
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: randomOffsetController,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: '统一点击随机半径（像素）',
                                  ),
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  validator: (value) {
                                    final parsed = int.tryParse(
                                      value?.trim() ?? '',
                                    );
                                    if (parsed == null || parsed < 0) {
                                      return '请输入大于等于 0 的整数';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: waitVariationController,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: '统一等待随机浮动（秒）',
                                    helperText: '录制间隔 3 秒、浮动 2 秒时，生成 5-7 秒等待',
                                  ),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  validator: (value) {
                                    final parsed = double.tryParse(
                                      value?.trim() ?? '',
                                    );
                                    if (parsed == null ||
                                        parsed.isNaN ||
                                        parsed.isInfinite ||
                                        parsed < 0) {
                                      return '请输入大于等于 0 的数字';
                                    }
                                    return null;
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
                actions: isConverting
                    ? const []
                    : hasResult
                    ? [
                        FilledButton(
                          onPressed: () => Navigator.of(dialogContext).pop(
                            _RecordedFlowConversionDialogResult(
                              savedResult: savedResult!,
                              conversionResult: conversionResult!,
                            ),
                          ),
                          child: const Text('确定'),
                        ),
                      ]
                    : conversionError != null
                    ? [
                        FilledButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('确定'),
                        ),
                      ]
                    : [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text(
                            '取消',
                            style: TextStyle(color: Colors.blue),
                          ),
                        ),
                        FilledButton(
                          onPressed: () async {
                            if (formKey.currentState?.validate() != true) {
                              return;
                            }
                            setDialogState(() {
                              isConverting = true;
                              conversionError = null;
                            });
                            await Future<void>.delayed(
                              const Duration(milliseconds: 120),
                            );
                            try {
                              final converted = _recordedFlowConverter.convert(
                                recordedFlow: recordedFlow,
                                options: RecordedFlowConversionOptions(
                                  randomOffsetPx: int.parse(
                                    randomOffsetController.text.trim(),
                                  ),
                                  waitVariationSeconds: double.parse(
                                    waitVariationController.text.trim(),
                                  ),
                                ),
                              );
                              final saved = await _customFlowStorageService
                                  .saveFlowAsNew(
                                    converted.flow,
                                    duplicateTag: 'converted',
                                  );
                              if (!dialogContext.mounted) {
                                return;
                              }
                              setDialogState(() {
                                conversionResult = converted;
                                savedResult = saved;
                                isConverting = false;
                              });
                            } catch (error) {
                              if (!dialogContext.mounted) {
                                return;
                              }
                              setDialogState(() {
                                conversionError = error;
                                isConverting = false;
                              });
                            }
                          },
                          child: const Text('开始转换'),
                        ),
                      ],
              ),
            );
          },
        ),
      );
    } finally {
      randomOffsetController.dispose();
      waitVariationController.dispose();
    }
  }

  Future<void> _convertSelectedRecordedFlowToCustomFlow() async {
    if (_selectedFlowName.isEmpty) {
      await showAdaptiveDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法转换'),
          content: const Text('请先选择一个已保存的录制流程。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    final recordedFlow = await _touchRecorderService.loadFlow(
      _selectedFlowName,
    );
    if (!mounted) {
      return;
    }
    if (recordedFlow == null) {
      await showAdaptiveDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法转换'),
          content: Text('未找到录制流程：$_selectedFlowName'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }
    if (!recordedFlow.actions.any(
      (action) => action.type == RecordedActionType.tap,
    )) {
      await showAdaptiveDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('没有可转换的点击'),
          content: const Text('所选录制流程中没有普通点击事件，未生成自定义流程。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() {
      _isConvertingRecordedFlow = true;
    });
    _RecordedFlowConversionDialogResult? dialogResult;
    try {
      dialogResult = await _showRecordedFlowConversionDialog(recordedFlow);
    } finally {
      if (mounted) {
        setState(() {
          _isConvertingRecordedFlow = false;
        });
      }
    }

    if (!mounted) {
      return;
    }
    if (dialogResult == null) {
      return;
    }

    await _reloadSavedCustomFlows();
    if (!mounted) {
      return;
    }
    final savedResult = dialogResult.savedResult;
    final conversionResult = dialogResult.conversionResult;
    setState(() {
      _selectedCustomFlowName = savedResult.flow.name;
      _customFlowNameController.text = savedResult.flow.name;
      _customFlowSteps = List<CustomFlowStep>.from(savedResult.flow.steps);
      _selectedCustomFlowStepIds = <String>{};
      _savePreferences();
      _output +=
          '已将录制流程“${recordedFlow.name}”转换为固定点击自定义流程：${savedResult.flow.name}\n';
      _output +=
          '转换点击 ${conversionResult.convertedTapCount} 个，跳过其他动作 ${conversionResult.skippedActionCount} 个。\n';
      _output += '保存路径：${savedResult.filePath}\n';
      _scrollToBottom();
    });
  }

  void _addSelectedFlowToPlaybackQueue() {
    if (_selectedFlowName.isEmpty) {
      setState(() {
        _output += '请先从已保存流程中选择一个流程。\n';
        _scrollToBottom();
      });
      return;
    }
    setState(() {
      _selectedPlaybackFlows.add(_selectedFlowName);
      _savePreferences();
      _output += '已添加到回放列表：$_selectedFlowName\n';
      _scrollToBottom();
    });
  }

  void _removeFlowFromPlaybackQueue(int index) {
    if (index < 0 || index >= _selectedPlaybackFlows.length) {
      return;
    }
    final removed = _selectedPlaybackFlows[index];
    setState(() {
      _selectedPlaybackFlows.removeAt(index);
      _savePreferences();
      _output += '已从回放列表移除：$removed\n';
      _scrollToBottom();
    });
  }

  void _clearPlaybackQueue() {
    if (_selectedPlaybackFlows.isEmpty) {
      return;
    }
    setState(() {
      _selectedPlaybackFlows.clear();
      _savePreferences();
      _output += '已清空回放列表。\n';
      _scrollToBottom();
    });
  }

  void _reorderPlaybackQueue(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final item = _selectedPlaybackFlows.removeAt(oldIndex);
      _selectedPlaybackFlows.insert(newIndex, item);
      _savePreferences();
    });
  }

  void _savePreferences() {
    if (!init) return;
    _prefs.setString('selectedArg', _selectedArg);
    final battleTime = _battleTimeController.text.trim();
    _prefs.setString('battleTime', battleTime);
    _prefs.setString(_battleTimePreferenceKey(), battleTime);
    _prefs.setString('tupoOutTime', _tupoOutTimeController.text.trim());
    _prefs.setString('battleTimeAdd', _battleTimeAddController.text.trim());
    _prefs.setString('bottom', _bottomController.text.trim());
    _prefs.setString('right', _rightController.text.trim());
    _prefs.setString('flowName', _flowNameController.text.trim());
    _prefs.setString('flowLoopCount', _flowLoopController.text.trim());
    _prefs.setString(
      'flowSampleIntervalMs',
      _flowSampleIntervalController.text.trim(),
    );
    _prefs.setString('customFlowName', _customFlowNameController.text.trim());
    _prefs.setString(
      'customFlowLoopCount',
      _customFlowLoopController.text.trim(),
    );
    _prefs.setBool('customFlowParallelExecution', _customFlowParallelExecution);
    _prefs.setString('selectedFlowName', _selectedFlowName);
    _prefs.setString('selectedCustomFlowName', _selectedCustomFlowName);
    _prefs.setStringList('selectedPlaybackFlows', _selectedPlaybackFlows);
  }

  void _killAllProcesses() {
    // 关闭所有正在执行的脚本
    for (var pythonProcess in _runningProcesses) {
      pythonProcess.kill();
    }
    _runningProcesses.clear();
  }

  Future<void> _runScript(String assetPath) async {
    if (_isWindowsClientMode) {
      await _showFlowInterruptionDialog(
        title: '痒痒鼠模式不支持时空客户端',
        message: '时空客户端（Windows）版本不内置阴阳师任务脚本。'
            '请用「自定义流程」里的识图点击、坐标点击、录制流程等步骤组合出需要的操作。',
      );
      return;
    }
    setState(() {
      _output = '正在加载脚本: $assetPath\n';
    });

    try {
      // 检查当前平台是否支持执行系统命令
      if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
        setState(() {
          _output += '错误: 此功能仅支持Windows、macOS和Linux桌面平台\n';
        });
        return;
      }

      // 获取临时目录
      final tempDir = await getTemporaryDirectory();
      final tempScriptPath = '${tempDir.path}/thumb_cache_tmp.py';

      // 从资源中加载脚本内容
      final scriptContent = await rootBundle.loadString(assetPath);
      // 将脚本内容写入临时文件
      final tempFile = File(tempScriptPath);
      await tempFile.writeAsString(
        !_isDebug ? EncryptUtil().decrypt(scriptContent) : scriptContent,
      );

      setState(() {
        // _output += '脚本已保存到临时目录: $tempScriptPath\n';
        _output += '正在打开系统终端执行脚本...\n';
      });

      // 在系统终端中执行脚本
      ProcessResult result;
      String terminalCommand;
      List<String> terminalArgs;

      if (assetPath.endsWith('.py')) {
        final pythonExecutable = Platform.isWindows ? 'python' : 'python3';

        // 传入参数：
        // 1 单局战斗时间
        String battleTime = _battleTimeController.text.trim();
        battleTime = setDefault(battleTime, "0");

        // 2 3自定义点击位置
        String bottom = _bottomController.text.trim();
        bottom = setDefault(bottom, "-1");

        String right = _rightController.text.trim();
        right = setDefault(right, "-1");

        // 4 运行次数
        String runTimes = _runTimesController.text.trim();
        runTimes = setDefault(runTimes, "0");

        // 5 将选中的设备列表作为参数添加
        String devicesArg = _selectedDevices.join(',');
        devicesArg = setDefault(devicesArg, "0");

        // 6 卡顿延时
        String battleTimeAdd = _battleTimeAddController.text.trim();
        battleTimeAdd = setDefault(battleTimeAdd, "0");

        // 7 识图阈值
        String picCtrl = _picCtrlController.text.trim();
        picCtrl = setDefault(picCtrl, "0.68");

        // 8
        String isDebug = _isDebug ? "0" : "1";

        // 9 跨区组队
        String isSwitchOn = _isKuaQuSwitchOn ? "0" : "1";
        // 10 自动结界突破
        String isLoopToTupo = _isLoopToTupoSwitchOn ? "0" : "1";
        // 11
        String isLoopToTupo1 = _isLoopToTupoSwitchOn1 ? "0" : "1";
        // 12
        String isLoopToTupo2 = _isLoopToTupoSwitchOn2 ? "0" : "1";
        // 13
        String isLoopToTupo3 = _isLoopToTupoSwitchOn3 ? "0" : "1";

        // 14 突破打9退4
        String tupoOutTime = _tupoOutTimeController.text.trim();
        tupoOutTime = setDefault(tupoOutTime, "4");

        // 15 测试服
        String isTestUser = _isTestUser ? "0" : "1";
        //16 御魂加的组队3
        String isLoopToTupo4 = _isLoopToTupoSwitchOn4 ? "0" : "1";
        // 17 打完第一轮立马去突破
        String isFirstDoneTupo = _isFirstDoneTupo ? "0" : "1";
        // 18 困1
        String isKun1SwitchOn = _isKun1SwitchOn ? "0" : "1";
        // 19 开启校验
        String needCheck = _needCheck ? "0" : "1";

        final pythonArgs = [
          tempScriptPath,
          _selectedArg,
          battleTime,
          bottom,
          right,
          runTimes,
          devicesArg,
          battleTimeAdd,
          picCtrl,
          isDebug,
          isSwitchOn,
          isLoopToTupo,
          isLoopToTupo1,
          isLoopToTupo2,
          isLoopToTupo3,
          tupoOutTime,
          isTestUser,
          isLoopToTupo4,
          isFirstDoneTupo,
          isKun1SwitchOn,
          needCheck,
        ];
        final args = pythonArgs.skip(1).join(' ');

        // 在_output中展示正在执行任务的设备和任务类型
        setState(() {
          _output += '开始执行任务：${_gameModeLabel(_selectedArg)}\n';
          _output += '参数：battleTime：$battleTime';
          _output += '参数：bottom：$bottom';
          _output += '参数：right：$right';
          _output += '参数：runTimes：$runTimes';
          _output += '参数：devicesArg：$devicesArg';
          _output += '参数：battleTimeAdd：$battleTimeAdd';
          _output += '参数：picCtrl：$picCtrl';
          _output +=
              '执行设备：${_selectedDevices.isNotEmpty ? _selectedDevices.join(', ') : '自动检测'}\n';
          _scrollToBottom();
        });

        if (Platform.isWindows) {
          // Windows: 使用cmd.exe打开终端执行Python脚本
          final launcherPath = await _createWindowsLauncherScript(
            workDir: tempDir,
            fileName: 'run_python_script.cmd',
            commandArgs: [pythonExecutable, ...pythonArgs],
          );
          terminalCommand = 'cmd.exe';
          terminalArgs = [
            '/c',
            'start',
            '',
            'cmd.exe',
            '/k',
            'call',
            launcherPath,
          ];
        } else if (Platform.isMacOS) {
          // macOS: 使用Terminal.app打开终端执行Python脚本
          // 创建一个临时shell脚本，然后用Terminal打开执行
          final shellScriptPath = '${tempDir.path}/run_python_script.sh';
          final shellScript = File(shellScriptPath);
          await shellScript.writeAsString('''#!/bin/bash
# 执行Python脚本
$pythonExecutable "$tempScriptPath" $args

# 等待用户按键后退出
echo "\n脚本执行完成，按回车键退出..."
read -r
''');

          // 确保shell脚本可执行
          await Process.run('chmod', ['+x', shellScriptPath]);

          terminalCommand = 'open';
          terminalArgs = ['-a', 'Terminal', shellScriptPath];
        } else {
          // Linux: 使用xdg-open或gnome-terminal打开终端执行Python脚本
          // 尝试多种终端应用，兼容不同Linux发行版
          try {
            terminalCommand = 'gnome-terminal';
            terminalArgs = [
              '--',
              pythonExecutable,
              tempScriptPath,
              ...args.split(' '),
            ];
            result = await Process.run(terminalCommand, terminalArgs);
          } catch (e) {
            try {
              terminalCommand = 'konsole';
              terminalArgs = [
                '-e',
                pythonExecutable,
                tempScriptPath,
                ...args.split(' '),
              ];
              result = await Process.run(terminalCommand, terminalArgs);
            } catch (e) {
              terminalCommand = 'xdg-open';
              terminalArgs = [tempScriptPath];
              result = await Process.run(terminalCommand, terminalArgs);
            }
          }
        }
      } else if (assetPath.endsWith('.bat')) {
        if (Platform.isWindows) {
          // Windows: 使用cmd.exe打开终端执行批处理脚本
          terminalCommand = 'cmd.exe';
          terminalArgs = ['/c', 'start', 'cmd.exe', '/k', tempScriptPath];
        } else {
          // macOS/Linux: 使用终端执行批处理脚本
          final bashExecutable = '/bin/bash';
          if (Platform.isMacOS) {
            terminalCommand = 'open';
            terminalArgs = ['-a', 'Terminal', bashExecutable, tempScriptPath];
          } else {
            try {
              terminalCommand = 'gnome-terminal';
              terminalArgs = ['--', bashExecutable, tempScriptPath];
            } catch (e) {
              terminalCommand = 'xdg-open';
              terminalArgs = [tempScriptPath];
            }
          }
        }
      } else {
        // 其他脚本类型，尝试直接在终端中执行
        if (Platform.isWindows) {
          terminalCommand = 'cmd.exe';
          terminalArgs = ['/c', 'start', 'cmd.exe', '/k', tempScriptPath];
        } else if (Platform.isMacOS) {
          terminalCommand = 'open';
          terminalArgs = ['-a', 'Terminal', tempScriptPath];
        } else {
          terminalCommand = 'xdg-open';
          terminalArgs = [tempScriptPath];
        }
      }

      // 执行终端命令
      if (Platform.isMacOS ||
          (Platform.isLinux && terminalCommand == 'xdg-open')) {
        result = await Process.run(terminalCommand, terminalArgs);
      } else if (Platform.isWindows) {
        // Windows的start命令需要特殊处理
        result = await Process.run(
          terminalCommand,
          terminalArgs,
          runInShell: true,
        );
      } else {
        // Linux终端命令
        result = await Process.run(terminalCommand, terminalArgs);
      }

      setState(() {
        _output += '系统终端已启动，脚本正在执行中...\n';
        _output += '终端命令执行结果: 退出码 ${result.exitCode}\n';
        if (result.stdout.isNotEmpty) {
          _output += '标准输出: ${result.stdout}\n';
        }
        if (result.stderr.isNotEmpty) {
          _output += '标准错误: ${result.stderr}\n';
        }
      });
    } catch (e) {
      setState(() {
        _output += '异常: $e\n';
      });
    }
  }

  String setDefault(String bottom, String value) {
    if (bottom.isEmpty) {
      bottom = value;
    }
    return bottom;
  }

  Future<void> _executeCommand() async {
    setState(() {
      _output += '触发';
    });
    try {
      String originalFilePath = "scripts/phone_click_simulator_more.py";
      String encryptedFilePath = "phone_click_simulator_more_enc.py";
      final scriptContent = await rootBundle.loadString(originalFilePath);

      // final appDocDir = await getApplicationDocumentsDirectory();
      final scriptsDir = Directory(
        "C:/flutter/py_auto/build/windows/x64/runner/Release/data/flutter_assets/scripts",
      );
      // final targetDir = Directory("${appDocDir.path}/scripts");
      if (!await scriptsDir.exists()) {
        await scriptsDir.create(recursive: true); // 递归创建目录
        print("创建可写目录：${scriptsDir.path}");
      }
      encryptedFilePath = "${scriptsDir.path}/$encryptedFilePath";
      EncryptUtil().encryptFile(scriptContent, encryptedFilePath);
      await FileUtils().deleteTargetFile();
      setState(() {
        _output += '执行成功$encryptedFilePath';
      });
    } catch (e) {
      setState(() {
        _output += '执行失败';
      });
    }
  }

  Future<void> _executeAdbCommand(String adbCommand) async {
    setState(() {
      _output += '\n\$ $adbCommand\n';
      _output += '正在执行ADB命令...\n';
    });

    try {
      // 检查当前平台是否支持执行系统命令
      if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
        setState(() {
          _output += '错误: 此功能仅支持Windows、macOS和Linux桌面平台\n';
        });
        return;
      }

      ProcessResult result;
      String terminalCommand;
      List<String> terminalArgs;

      if (Platform.isWindows) {
        // Windows: 使用cmd.exe打开终端执行ADB命令
        terminalCommand = 'cmd.exe';
        terminalArgs = ['/c', 'start', 'cmd.exe', '/k', adbCommand];
      } else if (Platform.isMacOS) {
        // macOS: 使用Terminal.app打开终端执行ADB命令
        // 创建一个临时shell脚本，然后用Terminal打开执行
        final tempDir = await getTemporaryDirectory();
        final shellScriptPath = '${tempDir.path}/run_adb_command.sh';
        final shellScript = File(shellScriptPath);
        await shellScript.writeAsString('''#!/bin/bash
# 执行ADB命令
$adbCommand

# 等待用户按键后退出
echo "\nADB命令执行完成，按回车键退出..."
read -r
''');

        // 确保shell脚本可执行
        await Process.run('chmod', ['+x', shellScriptPath]);

        terminalCommand = 'open';
        terminalArgs = ['-a', 'Terminal', shellScriptPath];
      } else {
        // Linux: 使用终端应用执行ADB命令
        // 尝试多种终端应用，兼容不同Linux发行版
        try {
          terminalCommand = 'gnome-terminal';
          terminalArgs = [
            '--',
            'bash',
            '-c',
            '$adbCommand; read -p "按回车键退出..."',
          ];
          result = await Process.run(terminalCommand, terminalArgs);
        } catch (e) {
          try {
            terminalCommand = 'konsole';
            terminalArgs = [
              '-e',
              'bash',
              '-c',
              '$adbCommand; read -p "按回车键退出..."',
            ];
            result = await Process.run(terminalCommand, terminalArgs);
          } catch (e) {
            // 尝试使用xterm
            terminalCommand = 'xterm';
            terminalArgs = [
              '-e',
              'bash',
              '-c',
              '$adbCommand; read -p "按回车键退出..."',
            ];
            result = await Process.run(terminalCommand, terminalArgs);
          }
        }
      }

      // 执行终端命令
      if (Platform.isMacOS) {
        result = await Process.run(terminalCommand, terminalArgs);
      } else if (Platform.isWindows) {
        // Windows的start命令需要特殊处理
        result = await Process.run(
          terminalCommand,
          terminalArgs,
          runInShell: true,
        );
      } else {
        // Linux终端命令
        result = await Process.run(terminalCommand, terminalArgs);
      }

      setState(() {
        _output += '系统终端已启动，ADB命令正在执行中...\n';
        _output += '终端命令执行结果: 退出码 ${result.exitCode}\n';
        if (result.stdout.isNotEmpty) {
          _output += '标准输出: ${result.stdout}\n';
        }
        if (result.stderr.isNotEmpty) {
          _output += '标准错误: ${result.stderr}\n';
        }
      });
    } catch (e) {
      setState(() {
        _output += '异常: $e\n';
      });
    }
  }

  Future<void> _handleRestartAdb() async {
    final now = DateTime.now();
    final lastRestartAt = _lastAdbRestartAt;
    final isRepeatedClick =
        lastRestartAt != null &&
        now.difference(lastRestartAt) <= const Duration(seconds: 20);

    if (isRepeatedClick) {
      setState(() {
        _output += '20 秒内重复点击重启ADB，改为执行检测命令。\n';
      });
      await _executeAdbCommand('adb devices');
      return;
    }

    _lastAdbRestartAt = now;
    await _executeAdbCommand('adb kill-server && adb start-server');
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  ButtonStyle _dangerButtonStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFFF2D2C7),
      foregroundColor: LinglongTheme.vermilionDeep,
      side: const BorderSide(color: Color(0xC6A5462C)),
    );
  }

  InputDecoration _solidDropdownDecoration(String labelText) {
    return InputDecoration(
      border: const OutlineInputBorder(),
      labelText: labelText,
      filled: true,
      fillColor: LinglongTheme.dropdownSurface,
    );
  }

  Widget _buildFrostedField({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x7AFFFFFF),
            borderRadius: BorderRadius.circular(8),
          ),

          // child: child,
          child: Padding(padding: const EdgeInsets.only(top: 6), child: child),
        ),
      ),
    );
  }

  Widget _buildFeatureTabs() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: LinglongTheme.panelDecoration(emphasized: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0x88F7E7C4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xB2756130)),
            ),
            child: TabBar(
              controller: _featureTabController,
              labelColor: LinglongTheme.ink,
              unselectedLabelColor: LinglongTheme.inkSoft,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              indicator: BoxDecoration(
                color: const Color(0xE6E8B56D),
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x3CBA5328),
                    blurRadius: 12,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              tabs: [
                Tab(text: _isWindowsClientMode ? '痒痒鼠（不支持）' : '痒痒鼠'),
                const Tab(text: '手势录制'),
                const Tab(text: '自定义流程'),
              ],
            ),
          ),
          if (_featureTabIndex == 2) ...[
            const SizedBox(height: 12),
            _buildEmulatorPointerTools(),
          ],
          const SizedBox(height: 12),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: KeyedSubtree(
              key: ValueKey(_featureTabIndex),
              child: _featureTabIndex == 0
                  ? _buildGameModeTab()
                  : _featureTabIndex == 1
                  ? _buildRecordingTab()
                  : _buildCustomFlowTab(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '流程录制与回放:',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _flowNameController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '输入要新建的流程的名称',
                  hintText: '例如: 日常领奖',
                ),
                onChanged: (_) => _scheduleSavePreferences(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildFrostedField(
                child: DropdownButtonFormField<String>(
                  initialValue: _savedFlows.contains(_selectedFlowName)
                      ? _selectedFlowName
                      : null,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '已保存流程',
                  ),
                  dropdownColor: LinglongTheme.dropdownSurface,
                  items: _savedFlows
                      .map(
                        (value) => DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedFlowName = value ?? '';
                      _savePreferences();
                    });
                  },
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 180,
              child: TextField(
                controller: _flowLoopController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '回放次数',
                  hintText: '0 为无限循环',
                ),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => _scheduleSavePreferences(),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 180,
              child: TextField(
                controller: _flowSampleIntervalController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '拖拽采样间隔(ms)',
                  hintText: '默认 100，越小越精细',
                ),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => _scheduleSavePreferences(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ElevatedButton(
              onPressed: _isRecordingFlow ? null : () => _reloadSavedFlows(),
              child: const Text('刷新流程列表'),
            ),
            ElevatedButton(
              onPressed: _isRecordingFlow ? null : () => _startFlowRecording(),
              child: const Text('开始录制'),
            ),

            ElevatedButton(
              onPressed: _isRecordingFlow ? () => _stopFlowRecording() : null,
              child: const Text('停止录制并保存'),
            ),
            ElevatedButton(
              onPressed: _isRecordingFlow ? null : () => _importRecordedFlow(),
              child: const Text('导入流程'),
            ),
            ElevatedButton(
              onPressed: _isRecordingFlow
                  ? null
                  : () => _exportSelectedRecordedFlow(),
              child: const Text('导出所选流程'),
            ),
            ElevatedButton(
              onPressed: _isRecordingFlow || _isConvertingRecordedFlow
                  ? null
                  : () => _convertSelectedRecordedFlowToCustomFlow(),
              child: const Text('转为固定点击自定义流程'),
            ),
            ElevatedButton(
              onPressed: _isRecordingFlow || _isConvertingRecordedFlow
                  ? null
                  : () => _deleteSelectedFlow(),
              style: _dangerButtonStyle(),
              child: const Text('删除所选已保存流程'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: LinglongTheme.panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '回放列表操作',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              if (_playbackQueueIssues.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '回放列表里有需要确认的地方：'
                  '${describeRecordedFlowIssues(_playbackQueueIssues)}'
                  '（每条流程的具体原因见下方列表）',
                  style: const TextStyle(
                    fontSize: 13,
                    color: LinglongTheme.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _isRecordingFlow
                        ? null
                        : () => _addSelectedFlowToPlaybackQueue(),
                    child: const Text('添加到回放列表'),
                  ),
                  ElevatedButton(
                    onPressed:
                        _isRecordingFlow || _selectedPlaybackFlows.isEmpty
                        ? null
                        : () => _clearPlaybackQueue(),
                    child: const Text('清空回放列表'),
                  ),
                  if (_isWindowsClientMode)
                    OutlinedButton(
                      onPressed: _isRecordingFlow || _selectedPlaybackFlows.isEmpty
                          ? null
                          : _selfCheckRecordedFlows,
                      child: const Text('录制流程自检（不回放）'),
                    ),
                  ElevatedButton(
                    onPressed: _isRecordingFlow
                        ? null
                        : () => _playSelectedFlow(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: LinglongTheme.vermilion,
                      foregroundColor: Colors.white,
                      shadowColor: const Color(0x55CC5B2D),
                      elevation: 0,
                      side: BorderSide.none,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: const Text(
                        '开始回放',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_selectedPlaybackFlows.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            decoration: LinglongTheme.panelDecoration(),
            child: Center(
              child: const Text(
                '回放列表为空。先从“已保存流程”中选择流程，再点击“添加到回放列表”。',
                style: TextStyle(fontSize: 13, color: LinglongTheme.danger),
              ),
            ),
          )
        else
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 96, maxHeight: 280),
            padding: const EdgeInsets.all(10),
            decoration: LinglongTheme.panelDecoration(),
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: _selectedPlaybackFlows.length,
              onReorder: _reorderPlaybackQueue,
              itemBuilder: (context, index) {
                final flowName = _selectedPlaybackFlows[index];
                final flowIssues =
                    _recordedFlowIssues[flowName] ??
                    const <RecordedFlowIssue>[];
                return Card(
                  key: ValueKey('$flowName-$index'),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_handle),
                    ),
                    title: Text('${index + 1}. $flowName'),
                    subtitle: flowIssues.isEmpty
                        ? null
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final issue in flowIssues)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '${issue.isError ? '⚠' : '提醒'} '
                                    '${issue.location}：${issue.message}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: issue.isError
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: issue.isError
                                          ? LinglongTheme.danger
                                          : const Color(0xFFB26A00),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                    trailing: IconButton(
                      tooltip: '从回放列表移除',
                      onPressed: _isRecordingFlow
                          ? null
                          : () => _removeFlowFromPlaybackQueue(index),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          '说明：录制要求当前只选中一个设备；回放会在独立命令行中执行，关闭对应命令行即可停止。多选设备会为每个设备各开一个窗口，回放使用启动瞬间的列表快照。',
          style: TextStyle(fontSize: 13, color: Colors.blueGrey),
        ),
        const SizedBox(height: 8),
        const Text(
          '转换说明：只提取普通点击坐标，并保留相邻点击之间的录制等待；可统一调整随机点击半径、等待倍率和随机浮动。生成文件自动保存到自定义流程目录，名称追加“_固定点击转换”。',
          style: TextStyle(fontSize: 13, color: Colors.blueGrey),
        ),
        const SizedBox(height: 8),
        Text(
          '导入导出说明：录制流程导出使用 .${TouchRecorderService.exportFileExtension} 专用后缀，包内保存录制动作、分辨率和触摸设备信息。导入时如果与现有流程重名，会自动追加 _import_2、_import_3 这类后缀，不会覆盖原流程；同时兼容旧的 .json 导出包。',
          style: const TextStyle(fontSize: 13, color: Colors.blueGrey),
        ),
      ],
    );
  }

  Widget _buildCustomFlowTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '自定义流程编辑与执行:',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customFlowNameController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '流程名称',
                  hintText: '例如: 每日领奖',
                ),
                onChanged: (_) => _scheduleSavePreferences(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildFrostedField(
                child: DropdownButtonFormField<String>(
                  initialValue:
                      _savedCustomFlows.contains(_selectedCustomFlowName)
                      ? _selectedCustomFlowName
                      : null,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '已保存自定义流程',
                  ),
                  dropdownColor: LinglongTheme.dropdownSurface,
                  items: _savedCustomFlows
                      .map(
                        (value) => DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedCustomFlowName = value ?? '';
                      _savePreferences();
                    });
                  },
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 180,
              child: TextField(
                controller: _customFlowLoopController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '执行轮数',
                  hintText: '0 为无限循环',
                ),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => _scheduleSavePreferences(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Card(
          margin: EdgeInsets.zero,
          child: SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: Text(
              _customFlowParallelExecution ? '模拟器并行执行' : '模拟器串行执行',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text('并行模式下各模拟器独立执行，互不等待，也不共享流程步骤的等待时间。'),
            value: _customFlowParallelExecution,
            onChanged: (value) {
              setState(() {
                _customFlowParallelExecution = value;
                _savePreferences();
              });
            },
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: LinglongTheme.panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '流程操作',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              if (_customFlowIssueSummary.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '流程里有需要修正的地方：$_customFlowIssueSummary'
                  '（每一步的具体原因见步骤列表）',
                  style: const TextStyle(
                    fontSize: 13,
                    color: LinglongTheme.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _reloadSavedCustomFlows,
                    child: const Text('刷新自定义流程列表'),
                  ),
                  ElevatedButton(
                    onPressed: _loadSelectedCustomFlow,
                    child: const Text('加载所选流程'),
                  ),
                  ElevatedButton(
                    onPressed: _appendSelectedCustomFlowToCurrent,
                    child: const Text('追加到当前流程末尾'),
                  ),
                  ElevatedButton(
                    onPressed: _saveCurrentCustomFlow,
                    child: const Text('保存当前流程'),
                  ),
                  ElevatedButton(
                    onPressed: _importCustomFlow,
                    child: const Text('导入流程'),
                  ),
                  ElevatedButton(
                    onPressed: _exportCurrentCustomFlow,
                    child: const Text('导出当前流程'),
                  ),
                  ElevatedButton(
                    onPressed: _deleteSelectedCustomFlow,
                    style: _dangerButtonStyle(),
                    child: const Text('删除所选已保存流程'),
                  ),
                  if (_isWindowsClientMode)
                    OutlinedButton(
                      onPressed: _customFlowSteps.isEmpty
                          ? null
                          : _selfCheckCustomFlow,
                      child: Text(
                        _customFlowIssueSummary.isEmpty
                            ? '流程自检（不连游戏）'
                            : '流程自检（不连游戏，'
                                  '${_customFlowProblemCount()} 处待修）',
                      ),
                    ),
                  ElevatedButton(
                    onPressed: _customFlowSteps.isEmpty ? null : _runCustomFlow,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: LinglongTheme.vermilion,
                      foregroundColor: Colors.white,
                      shadowColor: const Color(0x55CC5B2D),
                      elevation: 0,
                      side: BorderSide.none,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: const Text(
                        '执行自定义流程',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: LinglongTheme.panelDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '编辑操作',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  ElevatedButton(
                    onPressed: _addWaitStep,
                    child: const Text('添加等待'),
                  ),
                  ElevatedButton(
                    onPressed: _addImageTapStep,
                    child: const Text('添加识图点击'),
                  ),
                  ElevatedButton(
                    onPressed: _addCoordinateTapStep,
                    child: const Text('添加固定坐标点击'),
                  ),
                  ElevatedButton(
                    onPressed: _addPasteTextStep,
                    child: const Text('添加粘贴文字'),
                  ),
                  ElevatedButton(
                    onPressed: _addWaitImageStateStep,
                    child: const Text('添加识图等待'),
                  ),
                  ElevatedButton(
                    onPressed: _addImageBranchStep,
                    child: const Text('添加多图条件分支'),
                  ),
                  ElevatedButton(
                    onPressed: _addImagePositionBranchStep,
                    child: const Text('添加识图坐标分支'),
                  ),
                  ElevatedButton(
                    onPressed: _addLoopBlockStep,
                    child: const Text('添加循环块'),
                  ),
                  ElevatedButton(
                    onPressed: _addGameModeStep,
                    child: const Text('添加痒痒鼠模式'),
                  ),
                  ElevatedButton(
                    onPressed: _addRecordedFlowStep,
                    child: const Text('添加录制手势'),
                  ),
                  ElevatedButton(
                    onPressed: _addRestartActivityStep,
                    child: const Text('添加重启Activity（可以用来重启游戏）'),
                  ),
                  ElevatedButton(
                    onPressed: _addShutdownComputerStep,
                    child: const Text('添加关机操作'),
                  ),
                  ElevatedButton(
                    onPressed: _selectedCustomFlowStepIds.isEmpty
                        ? null
                        : () => _saveSelectedCustomFlowStepsAsFlow(
                            _customFlowSteps,
                            _selectedCustomFlowStepIds,
                          ),
                    child: Text(
                      _selectedCustomFlowStepIds.isEmpty
                          ? '保存选中为流程'
                          : '保存选中为流程（${_selectedCustomFlowStepIds.length}）',
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _selectedCustomFlowStepIds.isEmpty
                        ? null
                        : _copySelectedCustomFlowSteps,
                    child: Text(
                      _selectedCustomFlowStepIds.isEmpty
                          ? '复制选中节点'
                          : '复制选中节点（${_selectedCustomFlowStepIds.length}）',
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _selectedCustomFlowStepIds.isEmpty
                        ? null
                        : _deleteSelectedCustomFlowSteps,
                    style: _dangerButtonStyle(),
                    child: Text(
                      _selectedCustomFlowStepIds.isEmpty
                          ? '删除选中节点'
                          : '删除选中节点（${_selectedCustomFlowStepIds.length}）',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _selectedCustomFlowStepIds.isEmpty
                        ? null
                        : _clearCustomFlowStepSelection,
                    child: const Text('取消选中'),
                  ),
                  ElevatedButton(
                    onPressed: _customFlowSteps.isEmpty
                        ? null
                        : () async {
                            final confirmed = await _confirmClearStepList(
                              title: '清空流程步骤',
                              content: '确认清空当前自定义流程中的所有步骤吗？',
                            );
                            if (!confirmed) {
                              return;
                            }
                            setState(() {
                              _customFlowSteps = [];
                              _selectedCustomFlowStepIds = <String>{};
                            });
                          },
                    style: _dangerButtonStyle(),
                    child: const Text('清空列表'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_customFlowSteps.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _selectedCustomFlowStepIds.isEmpty
                  ? '提示：点击流程节点可选中，支持多选后一次复制多个节点。'
                  : '已选中 ${_selectedCustomFlowStepIds.length} 个节点，复制后会插入到最后一个选中节点后面。',
              style: const TextStyle(fontSize: 13, color: Colors.blueGrey),
            ),
          ),
        if (_customFlowSteps.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.blueGrey.shade100),
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey.shade50,
            ),
            child: const Center(
              child: Text(
                '流程还没有步骤。现在支持等待、识图点击（图片/文字识别）、固定坐标点击、粘贴文字、识图等待、多图条件分支、识图坐标分支、循环块、执行痒痒鼠模式、执行录制手势流程、重启当前Activity、关机操作。',
                style: TextStyle(fontSize: 13, color: LinglongTheme.danger),
              ),
            ),
          )
        else
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 96, maxHeight: 280),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.blueGrey.shade100),
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey.shade50,
            ),
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: _customFlowSteps.length,
              onReorder: _reorderCustomFlowSteps,
              itemBuilder: (context, index) {
                final step = _customFlowSteps[index];
                final isSelected = _selectedCustomFlowStepIds.contains(step.id);
                final stepIssues = _customFlowIssuesForStep(index);
                final stepForegroundColor = isSelected
                    ? LinglongTheme.ink
                    : null;
                final stepSubtleColor = isSelected
                    ? LinglongTheme.inkSoft
                    : null;
                return Card(
                  key: ValueKey('custom-flow-step-${step.id}-$index'),
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  color: isSelected ? const Color(0xFFFFF6E3) : null,
                  shape: RoundedRectangleBorder(
                    borderRadius: LinglongTheme.panelRadius,
                    side: BorderSide(
                      color: isSelected
                          ? LinglongTheme.mountainBlue
                          : const Color(0xA07A6234),
                      width: isSelected ? 1.4 : 1,
                    ),
                  ),
                  child: ListTile(
                    selected: isSelected,
                    selectedColor: LinglongTheme.ink,
                    iconColor: stepForegroundColor,
                    textColor: stepForegroundColor,
                    onTap: () => _toggleCustomFlowStepSelection(step.id),
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: isSelected,
                          checkColor: Colors.white,
                          fillColor: WidgetStateProperty.resolveWith((states) {
                            return states.contains(WidgetState.selected)
                                ? LinglongTheme.mountainBlue
                                : null;
                          }),
                          side: BorderSide(
                            color: isSelected
                                ? LinglongTheme.mountainBlue
                                : LinglongTheme.ink,
                            width: 1.8,
                          ),
                          onChanged: (value) => _toggleCustomFlowStepSelection(
                            step.id,
                            selected: value,
                          ),
                        ),
                        ReorderableDragStartListener(
                          index: index,
                          child: Icon(
                            Icons.drag_handle,
                            color: stepForegroundColor,
                          ),
                        ),
                      ],
                    ),
                    title: Text(
                      _buildStepTitle(step, index),
                      style: TextStyle(
                        color: stepForegroundColor,
                        fontWeight: isSelected ? FontWeight.w700 : null,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _buildStepSubtitle(step),
                          style: TextStyle(color: stepSubtleColor),
                        ),
                        for (final issue in stepIssues)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${issue.isError ? '⚠' : '提醒'} '
                              '${issue.location}：${issue.message}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: issue.isError
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: issue.isError
                                    ? LinglongTheme.danger
                                    : const Color(0xFFB26A00),
                              ),
                            ),
                          ),
                      ],
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        IconButton(
                          tooltip: '上移',
                          color: stepForegroundColor,
                          disabledColor: isSelected
                              ? const Color(0x993F5D65)
                              : null,
                          onPressed: index == 0
                              ? null
                              : () => _moveCustomFlowStep(index, -1),
                          icon: const Icon(Icons.keyboard_arrow_up),
                        ),
                        IconButton(
                          tooltip: '下移',
                          color: stepForegroundColor,
                          disabledColor: isSelected
                              ? const Color(0x993F5D65)
                              : null,
                          onPressed: index == _customFlowSteps.length - 1
                              ? null
                              : () => _moveCustomFlowStep(index, 1),
                          icon: const Icon(Icons.keyboard_arrow_down),
                        ),
                        IconButton(
                          tooltip: '编辑',
                          color: stepForegroundColor,
                          onPressed: () => _editCustomFlowStep(index),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: '删除',
                          color: stepForegroundColor,
                          onPressed: () => _removeCustomFlowStep(index),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          '说明：自定义流程已支持固定坐标点击、识图点击（图片/文字识别）、粘贴文字、多图条件分支、识图坐标分支、固定次数/识图条件/文本逐行循环、识图等待直到出现/消失、执行痒痒鼠模式、执行录制手势流程、重启当前Activity、关机操作，以及多设备并行执行。粘贴文字依赖 ADB Keyboard，设备未安装时会在执行前弹出 APK 安装向导；识图的文字识别模式依赖 RapidOCR 和 onnxruntime，缺失时会在执行前提示安装命令。',
          style: TextStyle(fontSize: 13, color: Colors.blueGrey),
        ),
        const SizedBox(height: 8),
        Text(
          '导入导出说明：导出文件使用 .${CustomFlowStorageService.exportFileExtension} 专用后缀，包内会同时包含流程 JSON、所引用的本地图片和手势录制数据。导入时会恢复关联资源并自动改写路径或重名引用；如果与现有流程重名，会自动追加 _import_2、_import_3 这类后缀，保留原流程不覆盖。',
          style: const TextStyle(fontSize: 13, color: Colors.blueGrey),
        ),
      ],
    );
  }

  Widget _buildGameModeTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '参数配置与启动:',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ElevatedButton(
                onPressed: () => _runScript(
                  !_isDebug
                      ? 'scripts/phone_click_simulator_more_enc.py'
                      : 'scripts/phone_click_simulator_more.py',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: LinglongTheme.vermilion,
                  foregroundColor: Colors.white,
                  shadowColor: const Color(0x55CC5B2D),
                  elevation: 0,
                  side: BorderSide.none,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: const Text(
                    '启动python程序',
                    style: TextStyle(
                      fontSize: 20,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              if (_selectedArg != 'tu_po')
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _runTimesController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '战斗次数：0为不设置',
                      hintText: '例如: 100',
                    ),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    enabled: true,
                  ),
                ),
              if (_isDebug)
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _picCtrlController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '识图阈值：0.65-0.8',
                      hintText: '默认0.8',
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'^[0-9.]*$')),
                    ],
                    enabled: true,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '选择模式:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildFrostedField(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedArg,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '模式选择：御魂组队、御灵、爬塔等',
                  ),
                  dropdownColor: LinglongTheme.dropdownSurface,
                  items: _availableGameModeNames.map((String value) {
                    return DropdownMenuItem<String>(
                      value: value,
                      child: Text(_gameModeLabel(value)),
                    );
                  }).toList(),
                  onChanged: (String? newValue) {
                    if (newValue == null) {
                      return;
                    }
                    _changeSelectedArg(newValue);
                  },
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _battleTimeController,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: _selectedArg == 'tu_po'
                      ? '单次突破最短时间，如7'
                      : _selectedArg == 'PK_mode'
                      ? '多少秒后自动认输时间'
                      : '单次战斗时间，如13s魂土设13',
                  hintText: '例如: 16',
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^[0-9.]*$')),
                ],
                enabled: _selectedArg != 'bai_gui' && _selectedArg != 'daoguan',
              ),
            ),
            if (_selectedArg == 'tu_po') ...[
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _tupoOutTimeController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '打九退4或3（有的区是3）',
                    hintText: '例如: 4',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*$')),
                  ],
                ),
              ),
            ],
            if (_selectedArg == 'kun28_double' ||
                _selectedArg == 'kun28_single') ...[
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _battleTimeAddController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '设备卡顿时间偏移（不卡设0，卡设为2左右）',
                    hintText: '例如: 2',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^-?[0-9.]*$')),
                  ],
                ),
              ),
            ],
            if (_selectedArg == 'qi_lin_double' ||
                (_selectedArg == 'kun28_double' && _isLoopToTupoSwitchOn)) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("是否跨区"),
                    Switch(
                      value: _isKuaQuSwitchOn,
                      onChanged: (bool newValue) {
                        setState(() {
                          _isKuaQuSwitchOn = newValue;
                          _prefs.setBool("_isKuaQuSwitchOn", _isKuaQuSwitchOn);
                        });
                      },
                      activeColor: Colors.green,
                      activeTrackColor: Colors.green.shade200,
                      inactiveThumbColor: Colors.grey,
                      inactiveTrackColor: Colors.grey.shade200,
                    ),
                  ],
                ),
              ),
            ],
            if (_selectedArg == 'kun28_double' ||
                _selectedArg == 'kun28_single') ...[
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("是否困1"),
                    Switch(
                      value: _isKun1SwitchOn,
                      onChanged: (bool newValue) {
                        setState(() {
                          _isKun1SwitchOn = newValue;
                          _prefs.setBool("_isKun1SwitchOn", _isKun1SwitchOn);
                        });
                      },
                      activeColor: Colors.green,
                      activeTrackColor: Colors.green.shade200,
                      inactiveThumbColor: Colors.grey,
                      inactiveTrackColor: Colors.grey.shade200,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        if (showTupoMenu()) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const SizedBox(width: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("是否自动\n结界突破"),
                  Switch(
                    value: _isLoopToTupoSwitchOn,
                    onChanged: (bool newValue) {
                      setState(() {
                        _isLoopToTupoSwitchOn = newValue;
                        _prefs.setBool(
                          "_isLoopToTupoSwitchOn",
                          _isLoopToTupoSwitchOn,
                        );
                      });
                    },
                    activeColor: Colors.green,
                    activeTrackColor: Colors.green.shade200,
                    inactiveThumbColor: Colors.grey,
                    inactiveTrackColor: Colors.grey.shade200,
                  ),
                ],
              ),
              if (showTupoMenu() && _isLoopToTupoSwitchOn) ...[
                if (_selectedArg == 'kun28_double' ||
                    _selectedArg == 'double_mode') ...[
                  const SizedBox(width: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("队长\n自动"),
                      Switch(
                        value: _isLoopToTupoSwitchOn1,
                        onChanged: (bool newValue) {
                          setState(() {
                            _isLoopToTupoSwitchOn1 = newValue;
                            _prefs.setBool(
                              "_isLoopToTupoSwitchOn1",
                              _isLoopToTupoSwitchOn1,
                            );
                          });
                        },
                        activeColor: Colors.green,
                        activeTrackColor: Colors.green.shade200,
                        inactiveThumbColor: Colors.grey,
                        inactiveTrackColor: Colors.grey.shade200,
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("队员1\n自动"),
                      Switch(
                        value: _isLoopToTupoSwitchOn2,
                        onChanged: (bool newValue) {
                          setState(() {
                            _isLoopToTupoSwitchOn2 = newValue;
                            _prefs.setBool(
                              "_isLoopToTupoSwitchOn2",
                              _isLoopToTupoSwitchOn2,
                            );
                          });
                        },
                        activeColor: Colors.green,
                        activeTrackColor: Colors.green.shade200,
                        inactiveThumbColor: Colors.grey,
                        inactiveTrackColor: Colors.grey.shade200,
                      ),
                    ],
                  ),
                  if (_selectedArg == 'double_mode') ...[
                    const SizedBox(width: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text("队员2\n自动"),
                        Switch(
                          value: _isLoopToTupoSwitchOn4,
                          onChanged: (bool newValue) {
                            setState(() {
                              _isLoopToTupoSwitchOn4 = newValue;
                              _prefs.setBool(
                                "_isLoopToTupoSwitchOn4",
                                _isLoopToTupoSwitchOn4,
                              );
                            });
                          },
                          activeColor: Colors.green,
                          activeTrackColor: Colors.green.shade200,
                          inactiveThumbColor: Colors.grey,
                          inactiveTrackColor: Colors.grey.shade200,
                        ),
                      ],
                    ),
                  ],
                ],
                Expanded(child: const SizedBox(width: 0)),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "是否自动切换阵容：（需要关闭式神录幕间皮肤）\n要求结界突破在阵容1第一行，当前模式的放在第二行",
                      textAlign: TextAlign.left,
                    ),
                    Switch(
                      value: _isLoopToTupoSwitchOn3,
                      onChanged: (bool newValue) {
                        setState(() {
                          _isLoopToTupoSwitchOn3 = newValue;
                          _prefs.setBool(
                            "_isLoopToTupoSwitchOn3",
                            _isLoopToTupoSwitchOn3,
                          );
                        });
                      },
                      activeColor: Colors.green,
                      activeTrackColor: Colors.green.shade200,
                      inactiveThumbColor: Colors.grey,
                      inactiveTrackColor: Colors.grey.shade200,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            const Text("是否在测试服"),
            Switch(
              value: _isTestUser,
              onChanged: (bool newValue) {
                setState(() {
                  _isTestUser = newValue;
                  _prefs.setBool("_isTestUser", _isTestUser);
                });
              },
              activeColor: Colors.green,
              activeTrackColor: Colors.green.shade200,
              inactiveThumbColor: Colors.grey,
              inactiveTrackColor: Colors.grey.shade200,
            ),
            const SizedBox(width: 20),
            const Text("是否开启校验（更安全，但更慢，不知道就默认开启）"),
            Switch(
              value: _needCheck,
              onChanged: (bool newValue) {
                setState(() {
                  _needCheck = newValue;
                  _prefs.setBool("_needCheck", _needCheck);
                });
              },
              activeColor: Colors.green,
              activeTrackColor: Colors.green.shade200,
              inactiveThumbColor: Colors.grey,
              inactiveTrackColor: Colors.grey.shade200,
            ),
            Expanded(child: const SizedBox(width: 0)),
            if (showTupoMenu() && _isLoopToTupoSwitchOn) ...[
              const Text("是否打完第一轮立马去突破"),
              Switch(
                value: _isFirstDoneTupo,
                onChanged: (bool newValue) {
                  setState(() {
                    _isFirstDoneTupo = newValue;
                    _prefs.setBool("_isFirstDoneTupo", _isFirstDoneTupo);
                  });
                },
                activeColor: Colors.green,
                activeTrackColor: Colors.green.shade200,
                inactiveThumbColor: Colors.grey,
                inactiveTrackColor: Colors.grey.shade200,
              ),
            ],
          ],
        ),
        if (showPointPanel()) ...[
          const SizedBox(height: 10),
          const Text(
            '自定义点击中心:默认-1为不设置，用于设备对不准的时候',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _bottomController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Bottom',
                    hintText: '例如: -1',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^-?[0-9.]*$')),
                  ],
                  enabled: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _rightController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Right',
                    hintText: '例如: -1',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^-?[0-9.]*$')),
                  ],
                  enabled: true,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _openGuidePage() async {
    final guideUri = Uri.parse('https://docs.qq.com/doc/DUW1CdGpWV09TaHRS');
    final launched = await launchUrl(
      guideUri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      debugPrint('打开图文攻略失败: $guideUri');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: const Color(0xEFFFF8EE),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xC27D6233)),
        ),
        title: GestureDetector(
          onLongPress: () {
            showDialog.value = true;
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Flexible(
                child: Text(
                  '玲珑助手 最后更新日期：2026年07月23日 (图文攻略中有详细的更新说明)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Tooltip(
                message: '打开图文攻略',
                child: IconButton(
                  onPressed: _openGuidePage,
                  icon: const Icon(Icons.article_outlined),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(gradient: LinglongTheme.appBackground),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListenableBuilder(
                      listenable: dateTime,
                      builder: (context, asyncSnapshot) {
                        return Align(
                          alignment: Alignment.bottomRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '到期时间：${dateTime.value}',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.red,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                onPressed: () {
                                  showDialog.value = true;
                                },
                                icon: const Icon(
                                  Icons.volunteer_activism,
                                  color: Colors.blue,
                                ),
                                label: const Text(''),
                              ),
                            ],
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text(
                          'ADB管理:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              ElevatedButton(
                                onPressed: () => _handleRestartAdb(),
                                child: const Text('重启adb（重新寻找电脑已开启的模拟器）'),
                              ),
                              ElevatedButton(
                                onPressed: () =>
                                    _executeAdbCommand('adb devices'),
                                child: const Text('检查（获取新检测到的设备列表）'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 15),
                    const Text(
                      '设备管理:',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: () => _getConnectedDevices(),
                          child: const Text('刷新设备列表'),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildFrostedField(
                            child: DropdownButtonFormField<String>(
                              initialValue: _selectedDeviceId.isEmpty
                                  ? null
                                  : _selectedDeviceId,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: '选择设备',
                              ),
                              dropdownColor: LinglongTheme.dropdownSurface,
                              items: _connectedDevices
                                  .map(
                                    (String value) => DropdownMenuItem<String>(
                                      value: value,
                                      child: Text(value),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (String? newValue) {
                                _selectedDeviceId = newValue ?? '';
                                _addDeviceToList();
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: () => _addDeviceToList(),
                          child: const Text('添加设备'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      '已选择设备:（默认第一个为队长）',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 5),
                    if (_selectedDevices.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 16,
                        ),
                        decoration: LinglongTheme.panelDecoration(),
                        child: const Center(
                          child: Text(
                            '当前未选择设备，将按全部已连接设备执行任务；',
                            style: TextStyle(
                              fontSize: 13,
                              color: LinglongTheme.danger,
                            ),
                          ),
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8.0,
                        runSpacing: 8.0,
                        children: _selectedDevices
                            .map(
                              (deviceId) => Chip(
                                label: Text(deviceId),
                                onDeleted: () =>
                                    _removeDeviceFromList(deviceId),
                              ),
                            )
                            .toList(),
                      ),
                    const SizedBox(height: 15),

                    const Text(
                      '重要提示和运行时日志输出:',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      width: double.maxFinite,
                      height: 100,
                      padding: const EdgeInsets.all(10),
                      decoration: LinglongTheme.panelDecoration(
                        dark: true,
                        emphasized: true,
                      ),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                style: const TextStyle(
                                  color: LinglongTheme.success,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'Courier',
                                ),
                                children: const [
                                  TextSpan(text: '所有战斗需'),
                                  TextSpan(
                                    text: '【预先运行一次】',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                  TextSpan(text: '，再开始循环。\n'),
                                  TextSpan(text: '使用前，认真阅读安装包内的图文攻略。单个功能建议'),
                                  TextSpan(
                                    text: '【挂机不超过两个小时】',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                  TextSpan(text: '，超时会增加风险；\n'),
                                  TextSpan(text: '部分功能，需要'),
                                  TextSpan(
                                    text: '【关闭】',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                  TextSpan(text: '式神录里的'),
                                  TextSpan(
                                    text: '【幕间皮肤】',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                  TextSpan(text: '、'),
                                  TextSpan(
                                    text: '【战斗主题皮肤】',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                  TextSpan(text: '；\n'),
                                  TextSpan(text: '所有需要自动结界突破的模式，所有队员都要在'),
                                  TextSpan(
                                    text: '【探索界面接受组队】',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                  TextSpan(text: '消息;'),
                                ],
                              ),
                            ),
                            Text(
                              _output.length <= _maxOutputChars
                                  ? _output
                                  : _output.substring(
                                      _output.length - _maxOutputChars,
                                    ),
                              style: const TextStyle(
                                color: LinglongTheme.success,
                                fontFamily: 'Courier',
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildFeatureTabs(),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _commandController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '输入命令或脚本路径',
                              hintText:
                                  '例如: python3 script.py 或 print("Hello")',
                            ),
                            enabled: true,
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onLongPress: () => _executeCommand(),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinglongTheme.primaryButtonGradient,
                              borderRadius: LinglongTheme.pillRadius,
                              boxShadow: LinglongTheme.glowShadow,
                            ),
                            child: const Text(
                              '执行',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: showDialog,
            builder: (context, asyncSnapshot) {
              return Visibility(
                visible: showDialog.value,
                child: const Positioned(child: SimultaneousDialogWidget()),
              );
            },
          ),
        ],
      ),
    );
  }

  bool showTupoMenu() {
    return (_selectedArg == 'double_mode' ||
        _selectedArg == 'ye_huo_yuan' ||
        _selectedArg == 'kun28_double' ||
        _selectedArg == 'kun28_single');
  }

  bool showPointPanel() {
    if (_selectedArg == 'single_mode') {
      return true;
    }
    return false;
  }
}

class SimultaneousDialogWidget extends StatefulWidget {
  const SimultaneousDialogWidget({super.key});

  @override
  State<SimultaneousDialogWidget> createState() =>
      _SimultaneousDialogWidgetState();
}

class _SimultaneousDialogWidgetState extends State<SimultaneousDialogWidget> {
  final TextEditingController _commandController = TextEditingController();

  void _checkLocalUser() async {
    try {
      // 获取当前
      int time = await NetworkTimeUtil.getAliyunNetworkTimestamp();
      var decrypt = EncryptUtil().decrypt(userCheck.value);

      var split = decrypt.split("当前时间");
      decrypt = split.last;
      var decryptUuid = split.first;

      // 验证uuid
      var uuid = await Utils().getDeviceUUID();
      var _prefs = await SharedPreferences.getInstance();
      var tempUUid = _prefs.getString('userCount');
      if (tempUUid == null) {
        // 本地没有uuid
        uuidCount.value = uuid;
        // 更新uuid和用户信息
        _prefs.setString('userCount', EncryptUtil().encrypt(uuid));
        _prefs.setString(
          'userCheck',
          EncryptUtil().encrypt('$uuid当前时间$decrypt'),
        );
      } else {
        var tempUUidDecrypt = EncryptUtil().decrypt(tempUUid);
        if (uuid != tempUUidDecrypt || uuid != decryptUuid) {
          showDialog.value = true;
          userResult.value = "用户信息前后不一致";
          return;
        }
      }

      dateTime.value = DateTime.fromMillisecondsSinceEpoch(
        int.parse(decrypt) * 1000,
      ).toString().substring(0, 19);
      if (int.parse(decrypt) > time) {
        showDialog.value = false;
      } else {
        showDialog.value = true;
      }
    } catch (e) {
      print('==================checkUser error:$e');
      showDialog.value = true;
    }
  }

  void _checkUser() async {
    try {
      // 获取当前
      var time = await NetworkTimeUtil.getAliyunNetworkTimestamp();
      var decrypt = EncryptUtil().decrypt(_commandController.text.trim());
      decrypt = decrypt.replaceAll("当前时间", "");
      // 加密校验
      print("加密校验前：$decrypt");
      if (decrypt.endsWith(rightEntry.value) &&
          decrypt.startsWith(leftEntry.value)) {
        print("加盐校验前：$decrypt");
        decrypt = decrypt.substring(1, decrypt.length - 1);
        print("加盐校验后：$decrypt");
        dateTime.value = DateTime.fromMillisecondsSinceEpoch(
          int.parse(decrypt) * 1000,
        ).toString().substring(0, 19);
        if (int.parse(decrypt) > time) {
          userResult.value = '校验通过';
          var uuid = await Utils().getDeviceUUID();
          var prefs = await SharedPreferences.getInstance();
          // 更新uuid和用户信息
          prefs.setString('userCount', EncryptUtil().encrypt(uuid));
          prefs.setString(
            'userCheck',
            EncryptUtil().encrypt('$uuid当前时间$decrypt'),
          );
          userCheck.value = prefs.getString('userCheck') ?? hint.value;
          showDialog.value = false;
        } else {
          userResult.value = '校验失败,会员码已过期';
          showDialog.value = true;
        }
      } else {
        userResult.value = '校验失败,会员码错误';
        showDialog.value = true;
      }
    } catch (e) {
      userResult.value = '校验异常:$e';
      showDialog.value = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          color: Colors.black38,
          child: BottomCenter(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 828,
                height: 614,
                margin: EdgeInsets.only(bottom: 16),
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.white,
                ),
                child: Column(
                  children: [
                    GestureDetector(
                      onDoubleTap: _checkLocalUser,
                      child: Text(
                        "测试会员若过期，请找开发者拿新的会员码 \n"
                        "加QQ:502578360  或扫码进群私群主",

                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/images/qq_qun.png',
                          // 对应 pubspec.yaml 中注册的图片路径
                          width: 350, // 图片宽度（可选，不设置则显示原始尺寸）
                          height: 350, // 图片高度（可选，不设置则显示原始尺寸）
                          fit: BoxFit.fill,
                        ),
                        Image.asset(
                          'assets/images/member.jpg',
                          // 对应 pubspec.yaml 中注册的图片路径
                          width: 350, // 图片宽度（可选，不设置则显示原始尺寸）
                          height: 350, // 图片高度（可选，不设置则显示原始尺寸）
                          fit: BoxFit.fill,
                        ),
                      ],
                    ),
                    SizedBox(height: 21),
                    ListenableBuilder(
                      listenable: showEncrypt,
                      builder: (context, asyncSnapshot) {
                        return TextField(
                          controller: _commandController,
                          decoration: InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: (showEncrypt.value == "")
                                ? ""
                                : '验证码：${randomEntry.value}=${int.parse(leftEntry.value) + randomEntry.value}${showEncrypt.value}${int.parse(rightEntry.value) + randomEntry.value}',
                            hintText: (showEncrypt.value == "")
                                ? ""
                                : '联系作者获取最新会员码: ${randomEntry.value}=${int.parse(leftEntry.value) + randomEntry.value}${showEncrypt.value}${int.parse(rightEntry.value) + randomEntry.value}',
                          ),
                        );
                      },
                    ),
                    SizedBox(height: 24),
                    SizedBox(
                      width: 230,
                      height: 48,
                      child: GestureDetector(
                        onTap: _checkUser,
                        child: Container(
                          width: 230,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Color.fromRGBO(75, 111, 250, 1),
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Center(
                            child: Text(
                              '验证',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 3),
                    ListenableBuilder(
                      listenable: userResult,
                      builder: (context, _) {
                        return Text(
                          userResult.value,
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: 16,
                            fontWeight: FontWeight.w400,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 614, // 距离顶部的间距
          right: 16, // 距离右侧的间距
          child: GestureDetector(
            onTap: _checkLocalUser, // 绑定关闭事件
            // 关闭按钮样式（可自定义，这里做了一个简洁的圆形关闭按钮）
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(20), // 圆形按钮
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Center(
                child: Text(
                  "X",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class BottomCenter extends Align {
  const BottomCenter({
    super.key,
    super.widthFactor,
    super.heightFactor,
    super.child,
  }) : super(alignment: Alignment.bottomCenter);
}
