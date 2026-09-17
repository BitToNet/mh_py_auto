# Python 单元测试（Windows 控制层）

这些测试用**假 Win32 后端**（`fake_win_api.py`）在 macOS/Linux 上验证 Windows 设备层的逻辑，
不需要游戏、不需要 Windows、不需要装额外依赖（有 numpy/cv2 时会多跑几项）。

```bash
# 在仓库根目录执行
python3 -m unittest discover -s tests/python -t tests/python          # 全部
python3 -m unittest discover -s tests/python -t tests/python -v       # 带用例名
python3 -m unittest discover -s tests/python -t tests/python -p "test_win_device.py"
```

| 文件 | 覆盖内容 |
| --- | --- |
| `fake_win_api.py` | 假 Win32 后端：窗口树、屏幕坐标、截图内容、消息与 SendInput 记录、点击后画面变化 |
| `test_win_api.py` | 坐标打包、图像分析/差异、BGRA→BGR、BMP 读写、缩放与边界钳制、API 注入 |
| `test_win_window.py` | 进程/窗口分类、多开排序、子窗口渲染目标识别与偏移、等待窗口、启停守卫 |
| `test_win_capture.py` | 各截图后端、探测报告、自动择优与缓存、缓存失效重探、全黑兜底、归一化到设计分辨率 |
| `test_win_device.py` | 多开设备枚举与同进程去重、设计↔真实坐标换算、点击消息顺序与多开隔离、输入降级、抖动、文本/按键、截图归一化、窗口尺寸、启停与健康检查 |
| `test_win_helper.py` | JSON-Lines 协议：各命令、错误提升、未知命令、非法 JSON、服务不崩 |
| `test_smoke_win.py` | 把 `tools/smoke_win.py` 用假后端完整跑一遍（只读、点击、尺寸、文本、无设备场景） |

真实 Windows 环境的验收不靠这些测试，而是：

```bat
python tools\win_probe.py --out probe_out --click-x 800 --click-y 450 --resize 1600x900 --interactive
python tools\smoke_win.py --input --resize --yes
```
