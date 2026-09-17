# 时空客户端 Windows 版 · Python 依赖

设备层与流程运行器**只用标准库 + numpy/opencv**；OCR 步骤才需要 rapidocr。
建议为流程运行单独建一个虚拟环境，避免和界面里的其它 Python 环境互相影响。

## 一、必须

```bat
python -m pip install numpy opencv-python
```

| 包 | 用途 | 不用会怎样 |
| --- | --- | --- |
| `numpy` | 截图数组、模板匹配 | 设备层与流程运行器都无法启动 |
| `opencv-python` | 模板匹配、图像编解码 | 识图点击/识图等待步骤报错 |

## 二、按需

```bat
python -m pip install rapidocr onnxruntime
```

| 包 | 用途 | 不用会怎样 |
| --- | --- | --- |
| `rapidocr` + `onnxruntime` | 文字识别（`ocrTap` / 文字条件） | 只有纯识图/坐标流程不受影响 |

## 三、常驻服务与控制层

`tools/win_helper.py` 只依赖 `numpy` + `opencv-python`（`capture` 命令可选返回 PNG base64）。
没有第三方包时枚举窗口、点击、文本输入依然可用，只有截图会失败。

## 四、版本建议

```
python >= 3.9（开发/验证使用 3.14）
numpy >= 1.24
opencv-python >= 4.8
```

## 五、环境画像（排障第一手信息）

两条命令的报告里都带上了环境画像，出问题时**先看这一段**：

| 位置 | 字段 | 含义 |
| --- | --- | --- |
| `win_probe_report.json` | `meta.deps` | 解释器路径 + `numpy`/`opencv`/`rapidocr` 版本（`null`=没装） |
| `smoke_report.json` | `health.environment` | 上面这些 + 脚本位置、是否发布版解包运行时、配置文件路径与是否存在、**真正生效的截图/输入顺序**、`inputTarget` |

`health.environment` 里最有用的两条：

- `configFound` 为 `false` → 你写的 `config/win_backend.json` 根本没被读到，界面/脚本还在用内置默认值；
- `captureOrder`/`inputOrder` → 脚本"实际在用"的顺序（含配置覆盖），不是你记忆里的默认顺序。

### 得到实测结果后：让工具自己写配置

不用手工翻译报告 —— `tools/win_recommend.py` 读报告、按运行时的同一套标准挑后端，
直接生成 `config/win_backend.json`：

```bat
python tools\win_recommend.py            :: 只打印建议和依据
python tools\win_recommend.py --write    :: 写入 config\win_backend.json
python tools\win_recommend.py --smoke smoke_out\smoke_report.json --write
```

它会给出 `captureOrder`/`captureOrderChild`/`inputMethod`/`inputTarget`/
`autoResize`/`textMethod`，并对风险给出提示（例如"只能靠 BitBlt 截图，
被遮挡时会失效"、"三种点击都不生效，建议改 `inputTarget: capture` 后重测"）。
已存在配置文件时必须加 `--force`，不会悄悄覆盖你手改过的东西。

## 六、自检

界面侧（Flutter）测试里有两类会**真的拉起 Python 进程**的用例
（`test/windows_helper_client_test.dart` 的协议桩、以及
`test/windows_helper_service_integration_test.dart` 跑的真实 `tools/win_helper.py`），
所以跑 `flutter test` 的机器也需要 PATH 里有 `python3`/`python`。

```bat
python -c "import numpy, cv2; print(numpy.__version__, cv2.__version__)"
python tools\win_helper.py --health
python scripts\win\flow_runner_win.py --help 2>nul || echo 运行器需要配置文件参数，见 docs/WIN_SMOKE_TEST.md
```

## 七、发布包（打包时）

发布版把 Python 侧脚本作为 Flutter assets 打进安装包：

- `pubspec.yaml` 里声明了 `scripts/win/`、`tools/win_helper.py`、`config/win_backend.example.json`；
- 程序启动时若找不到工程目录，会把它们解包到
  `%APPDATA%\..\应用支持目录\win_runtime\` 再使用（见 `lib/win_workspace.dart`）；
- 因此**发布机器只需要 Python + 上面两个包**，不需要安装整个工程目录。

解包目录里可以直接放用户自己的 `config/win_backend.json` 覆盖后端顺序；
工程目录运行时则会读取 `<工程根>/config/win_backend.json`。
