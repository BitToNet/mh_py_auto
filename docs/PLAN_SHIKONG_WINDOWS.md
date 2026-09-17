# 时空客户端（Windows）自动化版本 · 实施计划

> 分支：`shikong_windows`（从 `ai` 切出，独立版本，不再兼容 adb/模拟器主路径）
> 目标产品：《梦幻西游：时空》Windows 客户端（官方电脑端，`MyGame_x64r.exe`）
> 范围（用户确认）：只做「自定义流程 + 录制流程」在时空客户端上的可用化，含其必需的 Windows 控制层。
> 明确不做：内置梦幻西游日常任务脚本、五开编队协同、内存/协议级自动化。

---

## 1. 现状分析

### 1.1 现有架构

| 层 | 文件 | 职责 |
| --- | --- | --- |
| Flutter 桌面壳 | `lib/main.dart`（14859 行） | 任务参数、设备管理、执行日志、内嵌两段 Python 运行器 |
| Flutter 流程设计器 | `lib/custom_flow.dart`（1986 行） | 自定义流程步骤模型 / 导入导出 / 模板图片管理 |
| Flutter 录制器 | `lib/recording_flow.dart`（1392 行） | 录制（`adb getevent`）+ 回放（`sendevent`） |
| 设备校验 | `lib/flow_device_guard.dart` | 解析 `adb devices`、流程与设备的匹配校验 |
| Python 主引擎 | `scripts/phone_click_simulator_more.py`（2025 行） | 阴阳师任务脚本（困28/御魂/突破/道馆…） |
| Python 流程运行器 | `lib/main.dart:9012` 内嵌字符串 | 自定义流程解释执行（截图→匹配→点击→分支/循环/OCR） |
| Python 回放运行器 | `lib/main.dart:11148` 内嵌字符串 | 录制流程回放（sendevent） |

### 1.2 adb 耦合点（需要全部替换）

| 位置 | 数量 | 用途 |
| --- | --- | --- |
| `scripts/phone_click_simulator_more.py` | 164 处 | 截图、点击、屏幕信息、连设备 |
| 内嵌自定义流程运行器 | 71 处 | 截图、点击、shell、IME 文本、Activity 检测/冷启动 |
| `lib/main.dart` | 8 个调用点 | 设备列表、截图、屏幕尺寸、应用启停、IME 安装 |
| `lib/recording_flow.dart` | 6 个调用点 | 录制 getevent、回放 sendevent、触摸设备查询、分辨率 |
| 内嵌录制回放运行器 | 6 处 | sendevent 回放 |

### 1.3 现有硬约束（必须一起改）

1. **设计分辨率写死 1600×900**：`_ensureSupportedEmulatorResolution` 强制校验，所有模板图片与硬编码坐标都基于该分辨率。
2. **文本输入依赖 ADB Keyboard**：`_ensureAdbKeyboardInstalled` + 广播粘贴，Windows 下完全不适用。
3. **"应用"概念 = Android 包名/Activity**：`detect_current_activity`、`cold_start_package`、`restart_activity` 需要重写为"时空客户端进程/窗口"语义。
4. **录制依赖触屏节点**：`sendevent` 回放触摸轨迹，Windows 下要改成窗口消息/真实输入回放。
5. **`gameMode` 步骤**：会回调阴阳师主引擎脚本，时空版本需移除或替换。

### 1.4 时空客户端已知事实（上一轮逆向结论，可直接用）

- 原生 64 位 Windows 客户端（PE32+ x64），基于网易自研 **Messiah 引擎**（二进制命名空间 `Messiah`）。
- 目录结构：`MyPCLauncher_x64r.exe`（启动器）→ `MyPreloader_x64r.exe` → `Engine/Binaries/Win64/MyGame_x64r.exe`（主程序，约 38 MB）。
- 资源在 `HashRes/`（`.wpk/.idx`、`.thx/.thi`），以产品号 `g18` 的 RC4 系密钥加密。
- 依赖 `D3DX9_43.dll`、`ES2/PVR/libEGL|libGLESv2`；带 WinLicense/SecureEngine 壳、`libenvsdk.dll`/`ECCfunctions64.dll` 反外挂。
- 窗口为**窗口化**运行（非独占全屏），支持多开；主程序进程名固定，可作为窗口筛选依据。
- 关键未知项：**窗口类名/标题、是否响应后台消息点击、能否被后台截图（非前台/被遮挡时）、是否允许 SetWindowPos 改窗口尺寸** —— 由阶段一探测工具实测确定。

---

## 2. 总体方案

### 2.1 分层架构（目标态）

```
┌──────────────────────────────────────────────┐
│ Flutter UI：窗口列表 / 流程设计器 / 录制器 / 日志  │
└───────────────┬──────────────────────────────┘
                │ JSON-Lines over stdin/stdout（常驻）
┌───────────────▼──────────────────────────────┐
│ win_helper.py（常驻服务）                      │
│  list_windows / capture / click / type / hook  │
└───────────────┬──────────────────────────────┘
                │
        ┌───────▼────────┐        ┌──────────────────────┐
        │ win_window.py  │        │ win_capture.py       │
        │ 枚举/尺寸/DPI   │        │ PrintWindow/BitBlt    │
        ├────────────────┤        ├──────────────────────┤
        │ win_input.py   │        │ 截图后端自动降级       │
        │ 消息/真实输入    │        └──────────────────────┘
        └────────────────┘
                ▲
                │ 直接 import（同进程，无 IPC 开销）
┌───────────────┴──────────────────────────────┐
│ flow_runner_win.py：自定义流程 + 录制回放解释器  │
└──────────────────────────────────────────────┘
```

要点：**Python 侧共用一个设备层模块**；Flutter 侧高频操作（录制的实时预览、窗口列表刷新）走常驻 `win_helper.py`，低频操作（跑流程）走子进程直接 import 设备层。

### 2.2 关键设计决策

| 决策点 | 方案 | 理由 |
| --- | --- | --- |
| 设备标识 | `win:<pid>`（如 `win:12345`），内部映射 HWND | PID 在客户端运行期稳定，HWND 会因重开窗口变化；多开时 PID 唯一 |
| 分辨率归一化 | 启动流程前把目标窗口客户区 **SetWindowPos 到 1600×900**，失败则降级为按比例缩放坐标 | 复用现有全部模板与流程资产，成本最低；时空同为 16:9 |
| 截图 | 探测后按优先级自动降级：`PrintWindow(PW_RENDERFULLCONTENT)` → `PrintWindow(PW_CLIENTONLY)` → 子窗口 PrintWindow → `BitBlt` → （必要时）Windows Graphics Capture | 时空是 GLES/D3D 混合渲染，必须先实测哪种能拿到真实画面 |
| 点击 | 探测后按优先级：`PostMessage`（后台，不抢焦点）→ `SendMessage` → `SendInput`（前台真实输入） | 后台消息可在窗口被遮挡时工作，前台方案简单但会独占鼠标 |
| 文本输入 | 优先 `WM_CHAR`/`WM_KEYDOWN` 直接投递到窗口；失败则退化为真实按键序列；再失败则"点开输入框→系统剪贴板+Ctrl+V" | 时空自带聊天输入，Android 的 IME 广播方案无效 |
| 录制 | 全局低级钩子（`WH_MOUSE_LL`/`WH_KEYBOARD_LL`）只采集落在目标窗口矩形内的事件，转成窗口相对坐标 + 时间戳（沿用现有 JSON 结构） | 保持与现有录制流程格式兼容，回放侧才能复用 |
| 回放 | 窗口相对坐标 × 目标/源分辨率比例 → 逐事件投递（带原始延时，支持拖拽轨迹） | 与现有 `RecordedFlow` 数据结构一致 |
| 客户端启停 | 启动 = `subprocess` 拉起 `MyPCLauncher_x64r.exe`；重启 = `taskkill` + 等待窗口出现；"冷启动/Activity"步骤语义改为"确保客户端在运行" | 替换 Android 的包名/Activity 语义 |
| 多窗口 | 流程步骤的 `设备范围`（全部/首个/其余）映射为"窗口范围"，逐个窗口串行/并行执行 | 复用现有 `CustomFlowDeviceScope` 与串行协调器 |

### 2.3 合规与风险（必须写进 README）

- 只使用**窗口消息级**交互（截图 + 投递鼠标键盘消息），**不注入进程、不读写游戏内存、不修改客户端文件**。
- 时空客户端带 `libenvsdk.dll` / `ECCfunctions64.dll` 反外挂与 WinLicense 壳；即便如此，**自动化仍可能违反用户协议并导致封号**，风险由使用者承担。
- 默认打开"拟人化"参数：点击随机偏移、动作间隔随机化、拒绝极限频率；提供全局急停（热键）。

---

## 3. 阶段计划

### P0 · 方案与骨架（本分支，已完成 ✅）
- [x] 逆向确认时空客户端形态（引擎、进程名、目录、保护方式）
- [x] 摸清本项目 adb 耦合点与硬约束
- [x] 用户决策：新分支独立版 / 只做自定义流程与录制 / 先探测再定型
- [x] 建立分支 `shikong_windows`、本计划文档
- 验收：文档评审通过

### P1 · Windows 探测工具（当前阶段）
- 交付：`tools/win_probe.py`（纯 ctypes，无第三方依赖）+ `tools/README_win_probe.md`
- 采集项：
  1. 窗口清单：HWND / 标题 / 类名 / PID / 进程路径 / 客户区尺寸 / 是否最小化 / 子窗口树
  2. 截图后端逐项实测：`PrintWindow(PW_RENDERFULLCONTENT)`、`PrintWindow(0)`、子窗口、`BitBlt`，输出黑屏率、色彩数、耗时
  3. 遮挡/最小化场景下截图是否仍可用
  4. 点击后端逐项实测：`PostMessage` / `SendMessage` / `SendInput`，用"点击前后画面差异"判定是否生效
  5. 键盘文本注入实测：`WM_CHAR` 序列 / 扫描码 `SendInput`
  6. 窗口尺寸实测：能否把客户区改成 1600×900 且画面正确重排
  7. 多开实例枚举与隔离性、DPI 感知、后台是否会继续刷新
- 交付物：`win_probe_report.json` + `probe_shots/*.bmp` + 控制台摘要
- 验收：报告能明确回答"用哪种截图 + 哪种点击"，并给出可直接作为模板素材的截图

### P2 · Windows 设备层
- 交付：`scripts/win/win_window.py`、`win_capture.py`、`win_input.py`、`win_device.py`
- 对外函数面对齐现有调用（同名替换）：`screenshot / tap / swipe / screen_size / text_input / list_devices / ensure_running / restart_client / foreground`
- 交付：`tools/win_helper.py`（常驻 JSON-Lines 服务：`list_windows`、`capture`、`click`、`type`、`start_record`、`stop_record`）
- 验收：macOS 上以 mock 后端跑通单测；Windows 上 `tools/smoke_win.py` 全绿

### P3 · 流程引擎迁移
- 交付：把 `lib/main.dart:9012` 的内嵌运行器抽成真实文件 `scripts/win/flow_runner_win.py`（不再用字符串内嵌，便于维护与测试），并把 `adb_*` 全部换到设备层
- 步骤语义调整：`restartActivity`/冷启动 → 客户端启停；`pasteText` → Windows 文本输入；`gameMode` → 时空版本移除
- 保留：图片匹配、OCR（RapidOCR）、等待/分支/循环/设备范围、串行协调器、日志格式
- 验收：一份自定义流程 JSON 在 Windows 上端到端跑通（截图→匹配→点击→分支）

### P4 · Flutter 侧改造
- `lib/windows_device.dart`：窗口列表（替代 `adb devices`）、窗口选择与命名、启动/重启客户端
- 设备校验 `flow_device_guard.dart`：解析窗口列表
- 分辨率校验：改为"窗口客户区是否为 1600×900，否则提议自动调整"
- 截图来源：预览图、流程模板取图、执行日志截图全部改走 `win_helper`
- 移除 ADB Keyboard 安装/IME 相关流程
- 验收：`flutter analyze` 无新增告警；Windows 端 UI 全流程可点通

### P5 · 录制流程
- 录制：`win_helper` 起全局钩子，按窗口相对坐标记录鼠标移动/按下/抬起/滚轮/键盘，保留拖拽轨迹采样
- 回放：`flow_runner_win.py` 按比例映射 + 原始时序投递；兼容历史 JSON（`touchDevicePath` 字段忽略）
- 验收：录制一段"点开界面→拖动→点击"并在窗口尺寸变化后正确回放

### P6 · 测试、文档、打包
- 单测（macOS 可跑）：坐标映射、窗口匹配、配置解析、录制/回放时序、流程 JSON 兼容性
- Windows 冒烟清单 `docs/WIN_SMOKE_TEST.md`
- 打包：`flutter build windows --release` + Python 依赖（`opencv-python`、`numpy`、`rapidocr-onnxruntime`）安装说明，或 PyInstaller 打包 helper
- 验收：在一台干净 Windows 机器上按文档从零装好并跑通示例流程

---

## 4. 需要你配合的事项

1. **Windows 实机跑 P1 探测脚本**（已确认可以），把 `win_probe_report.json` 和 `probe_shots/` 回传给我。
2. 告诉我**客户端常用分辨率/窗口尺寸**（是窗口化 1600×900 还是别的），以及平时**开几个客户端**。
3. 确认**点击方式的可接受风险等级**（后台消息 vs 前台真实输入），P1 报告出来后我会给出建议再定。
4. 若 P1 显示后台消息点击无效，需要你接受"前台真实输入（会占用鼠标键盘）"或"驱动级方案（风险更高）"二选一。

---

## 5. 目标目录结构

```
docs/PLAN_SHIKONG_WINDOWS.md     本计划
tools/win_probe.py               P1 探测工具（独立运行）
tools/win_helper.py              P2 常驻服务（Flutter ↔ Win32）
tools/smoke_win.py               P2 冒烟测试
scripts/win/win_window.py        窗口枚举/尺寸/DPI
scripts/win/win_capture.py       截图后端
scripts/win/win_input.py         输入后端
scripts/win/win_device.py        设备层聚合 API
scripts/win/flow_runner_win.py   P3 流程解释器
lib/win_workspace.dart            P4 定位 Python 侧脚本（开发态/发布态解包）
lib/windows_helper_client.dart   P4 常驻服务客户端 + 设备服务
test/windows_helper_client_test.dart  P4 单测
scripts/win/win_record.py        P5 手势录制（全局鼠标钩子 + 聚合逻辑）
tests/python/test_win_contract.py 跨语言契约测试（Dart ↔ Python）
docs/WIN_SMOKE_TEST.md           实机验收清单
docs/WIN_REQUIREMENTS.md         Python 依赖与发布包说明
```

---

## 6. 进度

| 阶段 | 状态 | 产物 / 证据 |
| --- | --- | --- |
| P0 方案与骨架 | ✅ | 本计划；分支 `shikong_windows`；客户端逆向结论（Messiah 引擎、1.575.0） |
| P1 探测工具 | ✅ 工具就绪，⏳ 等实机数据 | `tools/win_probe.py`（纯 ctypes、无第三方依赖）、`tools/README_win_probe.md` |
| P2 设备层 | ✅ | `scripts/win/{win_api,win_window,win_capture,win_input,win_device}.py`、`tools/win_helper.py`、`tools/smoke_win.py`、`config/win_backend.example.json` |
| P2 单测 | ✅ 118 项全绿 | `tests/python/`（假 Win32 后端，macOS 上可跑） |
| P3 流程引擎迁移 | ✅ | `scripts/win/flow_runner_win.py`、`record_runner_win.py`、`win_replay.py`、生成器 `build_win_runners.py` |
| P3 单测 | ✅ 158 项全绿（含 P3 新增 40 项） | `tests/python/test_win_runner.py` 等 |
| P4 Flutter 改造 | ✅ | `lib/win_workspace.dart`、`lib/windows_helper_client.dart`、`lib/main.dart` 接设备层（设备列表/分辨率/文本输入/流程启动/客户端工具面板） |
| P5 录制流程 | ✅ | `scripts/win/win_record.py`（WH_MOUSE_LL 录制 + 纯逻辑聚合）、helper 的 `record_*` 命令、Dart 录制通路 |
| P6 测试/打包（含收尾） | 🔶 文档/资源/契约测试完成，⏳ 等实机验证 | `docs/WIN_SMOKE_TEST.md`（验收清单）、`docs/WIN_REQUIREMENTS.md`（依赖）、脚本已作为 assets 打进发布版（`lib/win_workspace.dart` 自动解包） |

本机回归基线（每次改动都应保持）：`python3 -m unittest discover -s tests/python -t tests/python`
**351 项全绿**；`flutter test` **120 项全绿**；`pyflakes` 干净；`flutter analyze` 无 error；
`python3 scripts/win/build_win_runners.py --check` 显示"运行器与 lib/main.dart 同步"。

四个入口在不支持的平台上都要给可读提示（不是 traceback）：
`tools/win_probe.py`、`tools/smoke_win.py`、`tools/win_helper.py`、`scripts/win/win_record.py`。

### P2 已定型的关键决策

1. **设备标识 `win:<pid>`**：HWND 会变，PID 稳定；每次操作前重新解析。
2. **统一使用设计分辨率 1600×900 坐标空间**：截图自动归一化、点击自动按比例放大，
   现有模板图片与流程坐标无需修改；窗口恰为 1600×900 时为 1:1。
3. **截图目标自动识别子窗口**（面积 ≥ 客户区 60% 的可见子窗口），并记录偏移；
   点击仍发给顶层窗口。
4. **三级降级链**：截图 5 后端择优缓存；鼠标 `postmessage → sendmessage → sendinput`；
   文本 `unicode → wm_char → clipboard`。
5. **实机数据只用于调默认值**：所有顺序都能在 `config/win_backend.json` 里覆盖，
   不需要改代码。
6. **输入目标可切换**（`inputTarget`）：默认发给顶层窗口、坐标加渲染子窗口偏移；
   设成 `capture` 则直接发给渲染子窗口、坐标相对该子窗口。
   这条是为"截图正常但后台点击对顶层无效"准备的配置级兜底，录制与回放共用同一套换算。

### P3 已定型的关键决策

1. **运行器是仓库里的真文件，不再是 Dart 字符串**：`flow_runner_win.py` /
   `record_runner_win.py` 由 `scripts/win/build_win_runners.py` 从 `lib/main.dart`
   内嵌脚本抽取并替换生成，流程语义（步骤/分支/循环/识图/OCR）逐行保留。
2. **只换底层，不换流程**：`adb_screenshot` / `tap` / `run_paste_text_step` 等函数名
   保留（内部改成设备层调用），因此 2000 多行流程引擎逻辑零改动。
3. **录制流程数据可直接复用**：录制动作结构不变，`sendevent` 回放换成
   鼠标"按下-移动-抬起"回放（保留 `delayMs` / `dragPath` 采样点与时长）。
4. **重启客户端会换 PID**：`restartActivity` 步骤重启后自动 `wait_for_new_device`
   并把逻辑设备 id 重绑到新 PID（别名表 `_DEVICE_ALIASES`），后续步骤继续可用。
5. **设备层补了三个原语**：任意路径拖动 `drag_path`、热键/清空输入框、
   按裸 PID / HWND / `win:<pid>` 三种写法解析设备。
6. **生成物必须与 `lib/main.dart` 同步**：`build_win_runners.py --check` 会比对，
   单测里也跑了这一步，防止上游改动后静默漂移。

### P4/P5 已定型的关键决策

1. **Flutter 侧只多两个文件**：`win_workspace.dart`（定位工程里的 Python 脚本）+
   `windows_helper_client.dart`（JSON-Lines 常驻客户端与设备服务），
   `main.dart` 里所有 Android 专有分支都用 `_isWindowsClientMode` 判定，
   非 Windows 平台（开发时在 macOS 上跑界面）行为完全不变。
2. **设备列表就是窗口列表**：`win:<pid>`，与 adb 设备号在界面上是同一套占位符，
   按设备范围（全部/第一个/其它）选择的逻辑不用改。
3. **不再卡分辨率**：窗口多大都能用（截图归一化 + 坐标换算）；
   Windows 下把"分辨率校验"换成"窗口尽力对齐 1600×900"。
4. **不再需要 ADB Keyboard**：文本输入由设备层直接完成（unicode/wm_char/clipboard）。
5. **流程运行器用仓库里的真文件**：Windows 下直接以
   `scripts/win/flow_runner_win.py` / `record_runner_win.py` 启动，
   不再把脚本写到临时目录；打包时随工程目录一起发布（见 P6）。
6. **痒痒鼠模式显式不支持**：标签页标注"（不支持）"，按钮点击后给出明确说明，
   流程里带 gameMode 步骤会在启动前拦截。
7. **录制用全局低级钩子**（`WH_MOUSE_LL`）：只记录落在目标窗口上的按下，
   坐标换算成 1600×900 设计坐标，输出与旧版录制 JSON 完全同构，可直接复用/回放。

### P6 已定型的关键决策

1. **发布版不要求工程目录**：`scripts/win/*`、`tools/win_helper.py`、
   `config/win_backend.example.json` 都作为 Flutter assets 打进安装包；
   启动时找不到工程目录就解包到应用支持目录的 `win_runtime/` 再用。
2. **依赖最小化**：设备层与流程运行器只需要 `numpy` + `opencv-python`
   （OCR 才需要 `rapidocr/onnxruntime`），见 `docs/WIN_REQUIREMENTS.md`。
3. **实机验收清单化**：`docs/WIN_SMOKE_TEST.md` 按"只读 → 动窗口 → 跑流程 → 录制"
   分阶段列出可执行的命令与通过标准，最后有需要回填的验收记录表。
4. **本机（macOS）能验证的东西**：Python 351 项单测、Dart 120 项测试（含跨进程集成 8 项、时空模式界面 5 项、跨语言流程配置 5 项、流程自检 10 项、编辑期校验 25 项）、`pyflakes`、
   `flutter analyze`、`flutter build macos`；**只有真实截图/输入/钩子必须上 Windows**。

### 已经拿到的本机证据（可复核）

1. **发布包资源完整**：`flutter build macos --debug` 产物里
   `.../flutter_assets/` 下 `bundledFiles` 的 11 个文件全部存在且非空
   （`scripts/win/*.py`、`tools/win_helper.py`、`config/win_backend.example.json`）；
   Dart 侧 `materializeFromAssets` 测试把资源真的解包到临时目录并确认可用，
   说明"没有工程目录也能跑"这条路径成立。
2. **录制→回放闭环**：`RecordToReplayRoundTripTest` 用假 Win32 API 走完整链路——
   屏幕坐标 (500,285) → 设计坐标 (800,450) → 回放点击 → 落回屏幕 (500,285)；
   滑动/长按同样验证起终点与按下抬起序列。
3. **命令行可用性**：两个运行器的 `--help` 打印用法（退出码 0）、缺参数码 2、
   多余参数拒绝；`tools/win_helper.py --list` 列出全部命令。
4. **跨语言契约**：界面调用过的常驻服务命令都有实现，运行器需要的配置字段界面都写。

### 探测工具本机可测化（第 4 轮）

`tools/win_probe.py` 是实机排查的第一步，之前一行都没被测过。现在：

- `tests/python/test_win_probe.py` 覆盖图像分析（黑屏率/颜色数/截断缓冲）、
  候选窗口判定（进程名/标题/Messiah 类名兜底）、`list_windows`（用假 user32 跑真实枚举逻辑，
  验证可见性过滤、`include_all`、resizable/foreground 标记、JSON 可序列化）、
  命令行参数（文档里让用户敲的 `--resize/--no-input/--no-save-shots/--all-windows/--interactive/--yes`
  必须存在）、非 Windows 平台守卫。
- 顺手修掉一个**可能在实机上直接崩掉的真隐患**：回调里 `int(hwnd)`。
  ctypes 回调既可能传 int 也可能传 `c_void_p`，而 `int(c_void_p)` 会
  `ValueError: invalid literal for int()`。`tools/win_probe.py` 与
  `scripts/win/win_api.py` 的窗口枚举回调现在统一走 `hwnd_int()`

### 一条命令跑完实机验收（第 15 轮）

前面 14 轮把本机能做的都做完了，最后卡在"必须有人在 Windows 上跑一遍"。
这一轮把这个门槛压到最低：新增 `tools/win_acceptance.py`，一条命令串起三步

    探测（只读）→ 推配置（默认只算不写）→ 冒烟（只读）

并写出**可直接回传**的报告包：

- `acceptance_out/acceptance_report.md`：环境 / 设备（含 tag、客户区尺寸）/
  截图后端实测 / 输入后端实测 / 文本注入实测 / 推荐配置 / 冒烟结果 / 原始输出 / 结论与下一步；
- `acceptance_out/acceptance_report.json`：同一份结论的结构化版本。

几处刻意的设计：

- **默认不碰游戏**（探测带 `--no-input --no-occlusion`，冒烟不带 `--input`），
  只有 `--with-input` 才会真的点一下；
- **`--write-config` 才写文件**，并且复用 `win_recommend` 的守卫（没有可用截图后端就拒写、
  已存在则要 `--force`）；
- **结论要诚实**：`recommend()` 的 `measured` 只表示"报告里有候选窗口"，不代表有截图实测数据，
  所以验收工具自己按实测结果判定（没有截图数据 / 五种后端全不可用 / 输入后端全不生效 /
  冒烟有未通过项 / 被跳过的步骤），逐条列进 `verdict.problems`；测试里专门盯着这几条。
- 退出码：`0` 通过、`1` 写了报告但有问题、`2` 参数或环境不对。

测试用**注入的假步骤**在本机跑完整流程（本机不是 Windows，真跑子进程只会拿到退出码 2），
报告结构则直接复用 `test_win_recommend.make_report` 那份按真实字段形状写的数据 ——
所以验收工具"读不读得懂真实探测报告"这条契约是被测住的（`capture[tag].methods`、
`input[tag][方法名]`、`client_size`、`targets[].pid/hwnd`）。

### 录制流程也进编辑期校验（第 14 轮）

第 13 轮只覆盖了自定义流程。这一轮把录制流程也接进来（`lib/recorded_flow_lint.dart`），
规则对齐回放侧：

- **原始指针事件**（down/move/up/cancel）是旧安卓录制留下的，时空客户端回放不了 → 红字；
- **坐标超出录制分辨率** → 提醒。这条是新加的：`win_replay.scale_recorded_point`
  最后会 `clamp_point`，越界的点会被**贴到窗口边缘**，点不到想点的地方，
  而运行器不会报任何错。起点、终点（仅滑动类）、拖拽轨迹点都查；
- 没记录分辨率时不做越界判断（回放不做缩放，坐标按设计坐标直接用），只提醒；
- 空流程只提醒（回放等于什么都不做）；滑动起终点相同也只提醒。

同步给运行器的 `--dry-run` 加了同一条越界提醒（两边口径必须一致），
回放列表条目、「回放列表操作」汇总、「录制流程自检」都会显示；
自检还会先给一份**本地结论**（不需要 Python 也能看到问题）。

### 编辑期就标红：不用等自检（第 13 轮）

第 12 轮的自检要用户主动点一下才发现问题。这一轮把同一套规则搬到**编辑器**里：

- 新的 `lib/custom_flow_lint.dart`：纯逻辑（不碰界面、不跑 Python），逐条规则与运行器对齐——
  模板图可用性（本地文件要有路径 / 内置图片要有名字，对应界面 `exportOne` 与运行器
  `template_source_of`）、文字识别要填目标文字（`run_ocr_tap` 会报错）、逐行文本循环
  至少要一行（`run_loop_block` 会报错）、录制流程是否存在、痒痒鼠模式在时空版不支持。
  分 error / warning 两级：像"粘贴文字内容为空"运行器不会报错（只是清空输入框），
  只给提醒，不做成红字。
- 界面上：步骤卡片 subtitle 里直接列出**这一步**（含它嵌套的子步骤）的问题，位置写成
  `第 2 步 › 第 1 步`；「流程操作」标题下给一句汇总；「流程自检」按钮顺带显示待修处数。

写这个测试又踩到两个坑，都记在测试文件里了：

1. widget 测试的假时钟**不会让真实文件 I/O 完成**。加载流程要串好几个 await，
   必须把读文件的交互放进 `tester.runAsync` 里触发，否则界面永远停在"还没读到文件"，
   而断言 `findsNothing` 会**空过**（假绿）。所以测试里加了"步骤卡片数必须等于 N"的
   前置断言。
2. 放行真实 I/O 之后，`TouchRecorderService` 在 macOS 测试环境里抛的
   `MissingPluginException` 就暴露出来了——以前这条异常从没出现过，正因为 I/O 不完成。
   修法是 mock `plugins.flutter.io/path_provider` 通道指向临时目录。

### 自检搬进界面（第 12 轮）

第 11 轮做了命令行自检，但用户不会为了点一下流程去开命令行。这一轮把它接到界面上：

- 「自定义流程」页「执行自定义流程」旁边多一个 **流程自检（不连游戏）**；
  「手势录制」页「开始回放」旁边多一个 **录制流程自检（不回放）**。两个按钮只在
  时空（Windows 客户端）模式下出现——只有 Windows 运行器带 `--dry-run`。
- 自检逻辑抽成 `lib/win_flow_self_check.dart`（`WinFlowSelfCheck` / `FlowSelfCheckResult`）：
  写配置 → 跑运行器 `--dry-run` → 摘出问题行。界面只负责写配置和展示结果。
  **抽出来的原因**：一开始想用界面点按钮堆步骤来测这条链路，结果 tap 落在被裁切的
  区域里、"添加步骤"静默无效——这种测试是假绿。现在按钮的"出现/禁用"由 widget
  测试管，真正跑 Python 的部分由 `test/win_flow_self_check_test.dart`（7 项）直接
  针对这个类测，不碰界面。
- 自检结果会写进输出区；不通过时弹窗列出前 3 条问题（如"第 2 个步骤没有可用的
  模板图片（运行到这一步一定失败）"），不会让用户以为"没反应"。

顺带把两处"配置 map"抽成 `_buildCustomFlowConfigMap()` / `_buildRecordedFlowConfigMap()`，
执行与自检共用一份字段定义——这正是第 11 轮那三个字段错位的根因，别再留第二份。

### "Dart 写的配置，Python 真的读得懂"（第 11 轮）

目标②最后一段没人验证过的链路：界面写配置 JSON → 运行器读配置。两边各自手写字段名，
以前一边改、另一边不知道，**两边单测都绿**，只有用户点「运行」时才炸。

给两个运行器加了 `--dry-run`（只读配置：不连窗口、不点游戏、不需要设备），
再补 `test/windows_flow_config_integration_test.dart`（5 项）：用**真实的 Dart 模型**
（`CustomFlowStep.toJson()` / `RecordedFlow.toJson()`）生成配置，喂给**真实的 Python 运行器**。

这一轮它连着抓出三个"单测全绿却会坑用户"的问题：

1. **动作坐标字段我搞错了**：自检器要求 `x`/`y`，而回放器（`win_replay.build_replay_plan`）
   读的是 `startX/startY/endX/endY` —— Dart 序列化出来的动作**永远没有 x/y**，
   照原样会给每一条录制流程报"缺少 y"。是我自己新写的校验逻辑错了，
   我手写的 Python 测试用例正好跟它一个口径，所以两边一起绿。
2. **模板可用性判定没对齐界面**：界面只导出"本地文件（要有路径）"或
   "内置资源（要有名字）"，我一开始只看模板名 → 对"选了内置资源"的步骤误报。
   现在 `template_source_of()` 逐条对齐 `exportOne`。
3. **旧格式单模板分支的 id 约定**：分支自己带一张模板时，模板 id **就是分支 id**
   （界面 `effectiveTemplateImages` 与运行器 `template_images_for_branch_case` 一致）。
   自检器按这条规则校验，测试里也钉住了这个约定。

另外顺手把参数校验统一了：`-h/--help` 走用法、缺参数/多余参数/未知选项都返回 2
（以前 `flow_runner_win.py --dry-run` 会把 `--dry-run` 当成配置文件路径去 open）。

### 实测数据 → 配置：一步到位（第 10 轮）

之前"探测报告 → 默认配置"这一段是**留给我人工解读**的，这既慢又容易和运行时的
判断口径不一致。新增 `tools/win_recommend.py`：

- 用**和运行时完全相同**的可用性标准挑后端 —— 把 `CaptureStrategy._usable` 里的判定
  抽成 `win_capture.usable_metrics()` 两处共用，杜绝"推荐一个、运行时选另一个"；
- 读探测报告（可选叠加冒烟报告），输出 `captureOrder`/`captureOrderChild`/
  `inputMethod`/`inputTarget`/`autoResize`/`textMethod`，并逐条给出**依据**与**风险**：
  首选不是 renderfull 就提醒"被遮挡可能黑屏"，只能 BitBlt 就警告多开/叠窗会失效，
  三种点击都不生效且存在满屏渲染子窗口时才建议 `inputTarget: "capture"` 并让你重测；
- 默认只打印不写文件；已存在配置时必须 `--force`，不会覆盖手改过的内容；
- `--write` 之后会**回读一次** `win_device.load_config()`，确认写出来的东西
  设备层真的认，并打印真正生效的截图顺序。

`tools/win_probe.py` 跑完会直接提示下一步命令，报告里也加了 `next` 字段。
测试 34 项，其中一项是**跨脚本契约**：用假 Win32 让 `win_probe.main` 真写一份
报告，再整份喂给推荐工具，确保两个脚本手写的字典结构不会错位。

**这个工具第一天就抓到一个真 bug**：探测工具把 CLIENTONLY 后端叫
`printwindow_clientonly`，而运行时（`win_capture.METHODS`）叫
`printwindow_client` —— 同一个东西两个名字。后果不止"报告对不上"：
自动生成的配置里会写进一个运行时不认识的后端名，**用户拿这份配置跑流程会直接抛
"未知截图后端"**。已修：

- 探测工具改名，与运行时一致；
- 加**契约测试**（`ProbeCaptureBackendContractTest`）钉死"探测实测的后端集合
  == 运行时可选的后端集合"，这类错位以后在单测里就会红；
- 推荐工具加第二道防线：报告里出现运行时不认识的名字时**只警告、不写进配置**
  （旧版本报告也吃得住），并顺手修掉 `captureOrderChild` 里混进窗口级后端的问题
  （子窗口没有窗口边框，那两种后端放在那儿没意义）。

### 文档不再靠人盯（第 9 轮）

`test_win_contract.py` 新增 `HelperProtocolDocContractTest`：协议文档的命令表
必须与 `win_helper.COMMANDS` **双向**一致（实现了没写/写了没实现都算错），
文档里写的协议版本必须等于 `ping` 真正返回的 `PROTOCOL_VERSION`。
（当前 25 条命令完全对齐。）

### 界面层的时空模式也测上了（第 9 轮）

`_isWindowsClientMode` 原本直接读 `Platform.isWindows`，macOS 上跑 `flutter test`
永远进不去这条分支。加了 `@visibleForTesting bool debugForceWindowsClientMode`
（默认 false，生产代码不会碰），补 `test/windows_mode_ui_test.dart`（5 项）：

- 时空模式下用「时空客户端工具」面板替换「模拟器坐标显示」，五个按钮齐全，
  文案讲清"窗口消息级控制、不注入、坐标统一 1600×900"；
- 痒痒鼠页签变成「痒痒鼠（不支持）」，手势录制/自定义流程照常；
- 关闭开关后仍是模拟器界面（证明开关真在起作用，而不是恒真）；
- **点「启动python程序」只弹提示不跑脚本**：`不内置阴阳师任务脚本` +
  引导到识图点击/坐标点击/录制流程 —— 这条是"不包含内置任务脚本"的界面级保证；
- 时空模式下自定义流程页签仍能正常渲染。

### 跨进程协议真跑过了（第 8 轮）

`test/windows_helper_service_integration_test.dart`（8 项）不再用手写协议桩，
而是让 Dart 启动一个**真实的 `tools/win_helper.py` 服务进程**
（`test/fixtures/real_helper_service.py`：真 `serve()`/`handle_line()`/`cmd_*`，
只把最底层 Win32 换成假实现），于是"两端真的连起来"这一段被真跑过：

- JSON-Lines 拆包/粘包：**一次 `capture` 的 base64 PNG 是 3.6 MB 的单行 JSON**，
  能完整穿过管道并解回 PNG magic；
- 并发请求各自拿到自己的响应（验证 Dart 侧写队列与 id 匹配）；
- Unicode 双向：响应里带回中文窗口标题，请求里的 `text: '时空测试'`
  由夹具落盘请求行后逐字核对；
- 错误传播（未知命令）、`health.environment` 真进程读取、`stop()` 后进程真退出并能重启。

### 客户端启停 + 环境画像（第 7 轮）

- **录制流程回放器也进测试了**：`record_runner_win.py`（界面里"回放录制流程"直接启动的就是它）
  的 9 项执行测试：单流程、`loopCount` 循环、多流程顺序、按录制分辨率缩放、空流程不崩、
  设备不存在报清楚错误、`skipDeviceCheck` 语义。
- **重启客户端 + 多开寻址**：`restartActivity` 步骤会重启客户端，PID 变了之后
  后续步骤必须自动打到新窗口。测试模拟"旧窗口消失、新窗口出现"，断言
  `设备已重新绑定到 win:2222` 且**后续点击落在新 hwnd 上**；另有一项覆盖
  "重启后等不到新窗口"的报错。
- **环境画像**：`win_device.environment_info()` 进 `health`，冒烟报告里多了
  `health.environment`，探测报告里多了 `meta.deps` —— 解释器路径、numpy/opencv/rapidocr
  版本、脚本来源（是否发布版解包运行时）、**配置文件在哪/有没有被读到**、
  **真正生效的截图与输入顺序**、`inputTarget`。以后拿到实机报告就能直接判断
  "是缺依赖、还是配置没生效、还是后端选错"，不用再来回问一轮。

### 流程执行侧也对账了（第 6 轮）

`tests/python/test_win_runner_flow.py`（16 项）把"配置 JSON → main() → 设备层调用"
整条链路在假 Windows 设备层上跑通：坐标点击（含越界钳制）、等待、循环块（
`children` 嵌套、`loopCount` 轮数）、粘贴文字（固定文字 / 上层文本逐行循环）、
录制流程回放（含按录制分辨率缩放）、设备范围 `all/first/others`、多设备并行、
`win:<pid>` 形态的设备 id、以及"设备不存在时报清楚错误"。

同时抓出的**界面↔运行器契约**（新增 5 项契约测试）：

- 步骤词表必须与 Dart 的 `CustomFlowStepType` 枚举逐字一致（14 个），
  多一个少一个都算错——这正是"界面加了步骤但运行器没实现"的高发点；
- 嵌套步骤字段是 `children`（不是 `steps`），设备范围取值是 `all/first/others`；
- `textContent`/`useParentLoopText` 两侧都要有；运行器独有的
  `textInputMethod`/`clearTextFirst` 必须有缺省值（界面暂时不写）；
- `skipDeviceCheck` 的真实语义：只跳过启动前校验。

### 探测工具"绝不空手而归"（第 5 轮）

主流程测试立刻抓出两个真崩溃点：截图段一出错，后面
`suite["methods"]` / `suite["best"]` 就直接 KeyError，
**整份报告都写不出来**——实机那一趟就白跑了。现在：

- 单个目标整体兜底（`_probe_one_target`），任一段抛异常只记录进
  `report["targetErrors"]` 并继续下一个目标；
- 每个测试段各自容错（`_guarded`），截图段挂了尺寸/输入段照跑；
- 报告统一由 `write_report()` 写出，`--list-only` 与"没有可测目标"也复用同一条路径。

### 探测工具主流程也跑通了（第 5 轮）

`ProbeMainTest`（8 项）用一个够完整的假 Win32（GDI 截图、SendInput、剪贴板、
SetWindowPos）真的调 `win_probe.main()`，把要交给用户的第一条命令整条跑通：

- `--list-only`：报告写出、meta/窗口列表正确、targets 为空；
- 默认路径：5 个截图后端逐个实测、`best` 选出、子窗口树写进报告；
- 后端全失败：报告记 `ok=false` 不崩（并顺手把控制台里的 "最佳后端：None"
  改成可读提示）；
- `--resize 1600x900`：before/after 客户区与 `matched` 正确；
- 输入生效性判定：基线=0，三种点击方式都能判定"生效"并给出推荐后端；
- `--text`：WM_CHAR / Unicode / 剪贴板三条路都写进报告；
- 没有候选窗口：退出码 1 且报告仍完整。

### 本轮（P6 收尾）补的防线

- `tests/python/test_win_contract.py`：跨语言契约测试——界面调用过的常驻服务命令
  必须都实现（反查"新增命令没接线"）；运行器需要的配置字段界面必须都写；
  运行器按 `sys.argv[1]` 读配置这件事被钉住。
- `RunnerCliTest`：两个运行器的 `--help`/缺参数/多余参数都给出用法并返回明确退出码，
  不再甩 traceback（用户在 cmd 里手动排查的第一入口）。
- 非 Windows 平台跑 `tools/win_helper.py` 时给出明确指引（退出码 2），不再抛 ctypes 栈。

### 顺带修掉的既有问题

- 「录制流程转固定点击」里残留的 Android 竖屏旋转映射
  （`x: startY, y: 900 - startX`）已移除，改为原样保留录制坐标：
  时空客户端录到的就是 1600×900 设计坐标，旋转会让 Windows 录制转出来的固定点击全部点偏；
  该修复同时让 `test/recorded_flow_conversion_test.dart` 的 3 项历史失败转绿
  （Dart 测试 66 项全绿）。

### 还没做、且需要你决定的

- 实机探测结果（截图/输入哪个后端可用、能否固定 1600×900）→ 决定 P3/P4 的默认配置。
- 如果后台消息点击无效，需要你在"前台真实输入（占键鼠）"与"驱动级方案（风险更高）"之间选一个。

### 下一步（本机侧已无待办）

本机（macOS）能做的都做完了：窗口控制层、自定义/录制流程执行与编辑期校验、
探测/推荐/验收工具、单元测试与文档。剩下的只有**必须有人在 Windows 上跑**的一步：

```bat
python tools\win_acceptance.py --write-config
```

然后把 `acceptance_out\acceptance_report.md` 与 `.json` 发回，据此：
① 微调 `config\win_backend.json` 的默认值与 `inputTarget`；
② 回填 `docs/WIN_SMOKE_TEST.md` 的验收记录表；
③ 若有后端在实机上不工作，按数据改 `scripts/win/win_capture.py` / `win_input.py` 的实现与顺序。

若想继续做可做的事（无实机数据也能做）：把两边编辑期提示合成一个「流程体检」入口
（一次列出自定义流程 + 录制流程的全部问题），并让自检结果可直接跳转到出问题的步骤。

