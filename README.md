# mh_py_auto

《梦幻西游：时空》**Windows 客户端**的窗口级自动化：后台截图 + 后台点击 + 文本输入，
在上面跑「自定义流程」与「手势录制流程」。界面是 Flutter（`lib/`），
执行端是纯 Python 设备层（`scripts/win/`）。

> 本版本**只面向时空 Windows 客户端**，已剔除安卓/模拟器部分（含旧任务脚本
> `phone_click_simulator_more.py` 与 `android/`、`ios/` 等平台目录），只保留 `windows/`。
> 不含内置梦幻西游任务脚本、五开协同，也不做内存/协议级自动化——所有交互都走窗口消息层。

## 能做什么

- 窗口枚举 / 多开寻址（设备 id 形如 `win:<pid>`）
- 后台截图（5 种后端，按实测可用性排序）与后台点击、文本输入
- 自定义流程 14 种步骤：等待、图片点击、文字识别点击、固定坐标点击、粘贴文本、
  等待图片状态、图片分支、位置分支、循环块、流程组、录制流程、重启客户端、关机等
- 手势录制与回放（录制流程可被自定义流程引用）
- 客户端启停；执行前自检与编辑期校验（缺模板图、缺识别文字、坐标越界等直接标红）

## 目录

| 路径 | 说明 |
| --- | --- |
| `lib/` | Flutter 界面：流程编辑、录制、自检、编辑期校验 |
| `scripts/win/` | Python 设备层：窗口/截图/输入/录制/回放/流程运行器 |
| `tools/` | 实机探测、配置推荐、一条命令验收、常驻 helper 服务 |
| `tests/python/`、`test/` | Python 351 项 + Dart 120 项测试 |
| `docs/` | 需求、实机验收清单、helper 协议、开发计划 |
| `config/` | `win_backend.example.json`（真实配置 `win_backend.json` 由实测生成，不入库） |
| `windows/` | Windows 桌面端工程（唯一保留的平台目录） |

## 快速开始（Windows）

```bat
:: 0. 建议以管理员身份打开 cmd；装依赖
python -m pip install numpy opencv-python
python -m pip install rapidocr onnxruntime        :: 只有用文字识别步骤才需要

:: 1. 启动《梦幻西游：时空》客户端，登录到"点了也没关系"的界面

:: 2. 一条命令跑完验收：探测 → 推配置 → 冒烟，并生成可回传的报告包
python tools\win_acceptance.py --write-config
::   产出 acceptance_out\acceptance_report.md / .json

:: 3. 启动界面
flutter run -d windows
```

只想单步跑：

```bat
python tools\win_probe.py --no-input --no-occlusion   :: 只读探测
python tools\win_recommend.py --write                 :: 由报告生成 config\win_backend.json
python tools\smoke_win.py                             :: 只读冒烟
```

执行流程（也可由界面调用）：

```bat
python scripts\win\flow_runner_win.py <config.json> [--dry-run]
python scripts\win\record_runner_win.py <config.json> [--dry-run]
```

## 开发与测试（macOS 也能跑）

```bash
python3 -m unittest discover -s tests/python -t tests/python   # 351 项
flutter test                                                   # 120 项
python3 scripts/win/build_win_runners.py                       # 由 lib/main.dart 生成运行器
python3 scripts/win/build_win_runners.py --check               # 检查是否同步
```

注意：`scripts/win/flow_runner_win.py`、`record_runner_win.py` 是**生成产物**，
不要手改，改 `lib/main.dart` 后用上面的命令重新生成。

## 文档

- `docs/WIN_REQUIREMENTS.md`：需求与边界
- `docs/WIN_SMOKE_TEST.md`：实机验收清单（含一条命令的验收流程）
- `docs/WIN_HELPER_PROTOCOL.md`：Flutter ↔ Python helper 协议
- `docs/PLAN_SHIKONG_WINDOWS.md`：开发计划与各轮进度

## 与旧仓库的关系

代码来自 `py_auto_scrip` 的 `shikong_windows` 分支，只取时空 Windows 相关部分。
`lib/main.dart` 里仍留有旧模拟器/任务模式的入口与对 `phone_click_simulator_more.py`
的路径常量，但本仓库**没有**带这个脚本，那条路径不可用（属于已排除范围）。

## 风险提示

《梦幻西游》有网易反外挂与 WinLicense 保护，任何自动化都存在**封号风险**；
本项目的所有交互虽然只走窗口消息层，但仍需自行判断是否使用。
