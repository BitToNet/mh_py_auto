# 时空客户端 Windows 设备层与流程运行器

面向《梦幻西游：时空》Windows 客户端的窗口控制层与流程执行层。**只做窗口消息级交互**：枚举窗口、截图、
发送鼠标/键盘消息、文本输入、窗口尺寸与客户端启停；不注入进程、不读写游戏内存、不改游戏文件。

```
scripts/win/
├── win_api.py      Win32 ctypes 绑定 + 图像/几何工具（非 Windows 平台 import 安全）
├── win_window.py   窗口枚举、进程识别、截图目标解析、客户端启停
├── win_capture.py  截图后端 + 自动择优 + 缓存 + 设计分辨率归一化
├── win_input.py    鼠标/键盘/文本后端 + 自动降级
├── win_device.py   设备层门面（给流程引擎与 win_helper 用）
├── win_replay.py   录制手势 → 鼠标路径回放
├── flow_runner_win.py     自定义流程执行器（生成物）
├── record_runner_win.py   录制流程回放器（生成物）
└── build_win_runners.py   生成上面两个运行器（见第六节）
```

## 一、快速使用

```python
import win_device

backend = win_device.backend()                     # 自动加载 config/win_backend.json
for device in backend.list_devices():
    print(device["deviceId"], device["clientSize"])

image = backend.screenshot("win:12345")            # BGR ndarray，已归一化到 1600x900
backend.tap("win:12345", 800, 450)                 # 设计坐标点击（自适应缩放+抖动）
backend.input_text("win:12345", "中文文本")
backend.ensure_running("win:12345")                # 没开就拉起启动器，最小化就恢复
```

模块级便捷函数与旧 adb API 对齐，流程引擎迁移时按名替换即可：
`list_connected_device_ids / screenshot / screen_size / tap / swipe / input_text / press_key /
ensure_running / restart_client / health`。

## 二、三个关键设计

### 1. 设备标识用 PID，不用 HWND

`deviceId = "win:<pid>"`。HWND 会随窗口重建变化，PID 在客户端存活期内稳定；每次操作前
`resolve()` 会重新枚举窗口并把 PID 映射到当前 HWND，所以客户端重启后设备对象仍然可用。

### 2. 一切坐标都在「设计分辨率」空间（默认 1600×900）

现有模板图片、自定义流程、录制流程的坐标全是按 1600×900 做的，因此：

- `screenshot()` 默认把画面缩放到 1600×900 再返回 → 模板匹配不用改；
- `tap/swipe/drag/scroll` 接收设计坐标，内部 `设计坐标 →(按比例)→ 真实客户区坐标 →(加偏移)→ 输入窗口坐标`；
- 窗口本身就是 1600×900 时比例为 1:1（最准），`autoResize=true` 会主动把窗口调成这个尺寸。

### 3. 截图目标可能是子窗口

Messiah 引擎的真实画面常常渲染在一个铺满客户区的**子窗口**里，直接截顶层窗口会全黑。
`resolve_capture_target()` 会自动挑面积 ≥ 客户区 60% 的可见子窗口作为截图目标，并记录它相对
顶层客户区左上角的偏移；点击仍然发给顶层窗口，坐标自动加偏移。实测数据回来后可在配置里写死
`capture_hwnd`。

## 三、降级链

| 层 | 顺序 | 说明 |
| --- | --- | --- |
| 截图 | `printwindow_renderfull` → `printwindow_client` → `bitblt_client` → `printwindow_window` → `bitblt_window` | 按顺序实测，取第一个"黑屏率 < 0.995 且颜色数 ≥ 6"的后端并**缓存到该窗口**；缓存后端突然失效会自动重新探测 |
| 鼠标 | `postmessage` → `sendmessage` → `sendinput` | 后台消息优先（不抢前台、可多开并行）；抛异常或返回失败自动换下一个 |
| 文本 | `unicode` → `wm_char` → `clipboard` | 真实键盘事件优先；`clipboard` 最稳但会改写系统剪贴板 |

`probe_capture` 命令可以在实机上把每个后端的黑屏率/颜色数/耗时打出来，用于调顺序或写死后端。

## 四、配置

`config/win_backend.example.json` 是模板，复制成 `config/win_backend.json` 即自动加载。
常用项：

| 键 | 默认 | 作用 |
| --- | --- | --- |
| `designWidth/designHeight` | 1600/900 | 设计分辨率 |
| `captureMethod` | `auto` | 写死截图后端（如 `printwindow_renderfull`） |
| `inputMethod` | `auto` | 写死点击后端 |
| `inputTarget` | `top` | 输入发给谁：`top`=顶层窗口（坐标含渲染子窗口偏移）；`capture`=直接发给截图目标（渲染子窗口），坐标相对该子窗口。实机若发现"截图正常但后台点击无效"，先试 `capture` |
| `textMethod` | `auto` | 写死文本输入方式 |
| `jitterRadius` | 2 | 点击落点随机抖动半径（像素，0=关闭） |
| `activateBeforeInput` | true | `sendinput` 前是否置前台 |
| `autoResize` | false | 接入设备时是否尝试把客户区改成设计分辨率 |
| `launcherPath` / `installDir` | 空 | 客户端启动器路径；留空则从运行中的进程推断 |

## 五、冒烟与测试

```bat
:: Windows 实机验收（走设备层真实代码路径）
python tools\smoke_win.py                       :: 只读：环境 + 枚举 + 截图
python tools\smoke_win.py --input --resize --yes  :: 追加点击生效性 + 尺寸归一化
```

```bash
# macOS/Linux 上跑单元测试（用假后端）
python3 -m unittest discover -s tests/python -t tests/python
```

## 六、流程运行器（复用自定义流程 / 录制流程）

旧版的"自定义流程执行器"是内嵌在 `lib/main.dart` 字符串里的 Python 脚本，只认 adb。
Windows 版把这两个脚本抽成仓库里的真实文件，底层换成上面的设备层：

| 文件 | 作用 |
| --- | --- |
| `flow_runner_win.py` | 自定义流程执行器（步骤/分支/循环/识图/OCR/录制流程），与旧版流程语义一致 |
| `record_runner_win.py` | 只回放录制手势队列（"回放录制流程"功能） |
| `win_replay.py` | 录制动作 → 鼠标路径的翻译（tap / longPress / 滑动 / dragPath） |
| `build_win_runners.py` | 生成器：从 `lib/main.dart` 内嵌脚本抽取并替换成 Windows 版 |

```bat
:: 手工跑一个流程（配置文件由 Flutter 侧写出，格式与旧版一致）
python scripts\win\flow_runner_win.py  %TEMP%\flow_config.json
python scripts\win\record_runner_win.py %TEMP%\record_config.json

:: 校验生成物是否与 lib/main.dart 同步（改过内嵌脚本后必须重新生成）
python scripts\win\build_win_runners.py --check
```

改动约定：**不要直接改 `flow_runner_win.py` / `record_runner_win.py`**，
它们由生成器产出；需要调整行为时改生成器里的替换片段，然后重新执行：

```bash
python3 scripts/win/build_win_runners.py
```

与旧版的行为差异（都是 Android 语义在 Windows 上不存在的东西）：

| 旧版（Android/adb） | Windows 版 |
| --- | --- |
| `adb shell screencap` 截图 | 设备层窗口截图（自动归一化到 1600x900） |
| `adb shell wm size` 分辨率 | 固定设计分辨率 1600x900 |
| `adb shell input tap` 点击 | 窗口消息点击（自动缩放 + 子窗口偏移） |
| ADB Keyboard 广播输入文字 | 设备层文本输入（unicode/wm_char/clipboard） |
| `am start/force-stop` 重启 Activity | 重启时空客户端，并自动把设备重绑到新 PID |
| `sendevent` 触屏回放 | 鼠标按下-移动-抬起回放（保留原始时间与轨迹采样点） |
| `gameMode`（阴阳师内置脚本） | 不支持，直接报错（本分支不内置游戏任务脚本） |

## 七、手势录制（全局钩子）

Windows 版没有 `adb shell getevent`，录制改用系统低级鼠标钩子：

```bat
:: 命令行自检：录 10 秒，把动作 JSON 打到控制台
python scripts\win\win_record.py 10
```

界面里的「手势录制」走常驻服务：`record_start` → `record_poll`（可选）→ `record_stop`。
`scripts/win/win_record.py` 里的 `GestureBuilder` 是纯逻辑，负责把事件流聚合成
`tap / longPress / swipe / longPressSwipe`，并保留按住时长、移动轨迹采样点与动作间隔；
钩子线程只负责把屏幕坐标换算成设计坐标后喂给它。

行为约定：

- 只在目标窗口上的按下才开始录制一段动作，多开不会串台；
- 坐标链：屏幕 → 目标窗口客户区 → 减截图目标偏移 → 缩放到 1600×900，
  与回放共用同一套换算；
- 录制期间不要切到其它程序操作（全局钩子会看到），也不要关闭常驻服务；
- **需要与游戏窗口同等或更高的权限**：游戏若以管理员运行，常驻服务也要管理员，
  否则钩子收不到事件（表现为录不到动作）。

## 八、风险与边界

## 六、风险与边界

- 时空客户端带反外挂（`libenvsdk`、`ECCfunctions64`、`CrashHunter`）与 WinLicense 壳。
  本层只发窗口消息、只用系统截图 API，不注入、不挂钩、不读内存，但**自动化仍可能违反用户协议
  并有封号风险**，请自行评估。
- 输入测试会真实操作游戏，请在"点了也没关系"的界面下进行。
- 建议以**管理员权限**运行（否则可能控制不了以管理员启动的游戏窗口）。
