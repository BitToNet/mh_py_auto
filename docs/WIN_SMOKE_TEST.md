# 时空客户端 Windows 版 · 实机验收清单

在 macOS 上只能跑单元测试与静态检查；**所有真实能力必须在 Windows 实机上验证**。
本清单按"先只看不动 → 再动窗口 → 最后跑流程"的顺序排列，每一步都有明确的通过标准。

## 零、最省事的一条命令（推荐先跑这个）

```bat
python tools\win_acceptance.py
```

它把下面三件事串起来跑一遍，并写出一份**可以直接回传**的报告包：

1. 只读探测（不点游戏、不做遮挡测试）；
2. 由探测报告推出后端配置（默认只算不写，加 `--write-config` 才写进
   `config\win_backend.json`）；
3. 只读冒烟（窗口控制层自检）。

产出（默认目录 `acceptance_out\`）：

| 文件 | 内容 |
| --- | --- |
| `acceptance_report.md` | 人读版：环境 / 设备 / 各后端实测 / 推荐配置 / 冒烟结果 / 结论与下一步 |
| `acceptance_report.json` | 同一份结论的结构化版本 |
| `probe\`、`smoke\` | 两步各自的原始报告与截图 |

常用组合：

```bat
python tools\win_acceptance.py --write-config        :: 顺便把推荐配置写进 config\win_backend.json
python tools\win_acceptance.py --with-input          :: 连点击/键盘也测（会真的点一下游戏）
python tools\win_acceptance.py --skip-probe          :: 复用上次的探测报告，只补冒烟
```

退出码：`0` = 结论通过；`1` = 写好了报告但有问题（看"结论"一节）；`2` = 参数或环境不对
（比如不在 Windows 上跑）。

**回传**：把 `acceptance_out\acceptance_report.md` 与 `acceptance_report.json` 一起发回即可；
如果报告里提到某个后端报错，把 `acceptance_out\probe\` 里对应的截图也带上。

（只想要单步结果时，按下面的"零、准备"逐步跑。）

## 零、准备

```bat
:: 1. 建议以管理员身份打开 cmd（否则可能控制不了以管理员启动的游戏窗口）
:: 2. Python 依赖（设备层只用标准库 + numpy/cv2；OCR 才需要 rapidocr）
python -m pip install numpy opencv-python
python -m pip install rapidocr onnxruntime        :: 只有用「文字识别」步骤才需要
:: 3. 启动《梦幻西游：时空》客户端，登录到"点了也没关系"的界面
```

```bat
:: 4. 环境自检（只读，不动游戏）
python tools\win_probe.py               :: 窗口枚举 + 5 种截图后端实测 + 报告
python tools\win_probe.py --resize 1600x900
```

产出：`probe_out\win_probe_report.json`、`probe_out\probe_shots\*.bmp`
（`--resize` 会尝试把客户区改成 1600×900）。

报告里要先看的一处：`meta.deps` —— Python 解释器路径、`numpy`/`opencv`/`rapidocr`
版本（`null` = 没装，截图一定会失败）。装依赖：
`python -m pip install numpy opencv-python`（OCR 再加 `rapidocr onnxruntime`）。

接下来要看的三处：

- `capture[<目标>].methods` / `.best` → 哪种截图后端可用；
- `input[<目标>].recommendation` → 建议用哪种点击方式；
- 若某个测试段自身出错，会记在 `targetErrors` 或对应段的 `error` 里（**其它段仍会照跑**，
  报告一定会写出来）。只要报告里出现 `error`，把那段一起发回即可。

```bat
:: 5. 把实测结果直接变成配置（打印建议；确认无误加 --write 写入）
python tools\win_recommend.py
python tools\win_recommend.py --write        :: 生成 config\win_backend.json
```

推荐工具用的是**和运行时完全相同**的可用性标准（不是另一种口径），
所以它排在前面的后端就是运行时会真正选的那个。它会打印每条结论的依据，
以及诸如"只能靠 BitBlt 截图：被遮挡时可能失效"这类风险提示。
不想让它覆盖手改过的配置：默认不写文件，且已存在 `config\win_backend.json`
时必须加 `--force` 才会覆盖。

## 一、设备层（不动游戏）

| 步骤 | 命令 | 通过标准 |
| --- | --- | --- |
| 1. 枚举命令 | `python tools\win_helper.py --list` | 列出全部命令，无异常（该命令在任何平台都能跑） |
| 2. 健康检查 | `python tools\win_helper.py --health` | `isWindows=true`、`deviceCount≥1`、首个设备截图自检通过 |
| 3. 冒烟（只读） | `python tools\smoke_win.py` | 报告里 `env/device/capture` 全部 PASS，截图非纯黑 |
| 4. 后端择优 | `python tools\smoke_win.py --yes` | 报告里给出可用的 `captureMethod` |

把第 2/3 步结果记下来：

- 可用截图后端：`__________`
- 是否能用 `printwindow_renderfull`：`是 / 否`
- 客户区尺寸：`__________`（能否固定 1600×900：`是 / 否`）

## 二、输入是否生效（会真实操作游戏）

```bat
python tools\smoke_win.py --input --resize --yes
```

通过标准（逐项在界面上肉眼确认）：

- [ ] 后台点击落到预期位置（`postmessage` 即可，不需要抢前台）
- [ ] 窗口被别的窗口遮住时点击仍然生效（后台消息的关键指标）
- [ ] 文本输入能在游戏输入框里出现文字（中文也要试）
- [ ] `sendinput` 兜底方案可用（把 `inputOrder` 改成 `["sendinput"]` 再试一次）

如果**后台消息点击无效**、只有 `sendinput` 有效，先分清是"发错了窗口"还是"消息被忽略"：

1. 看 `win_probe_report.json` 里是否存在占绝对面积的渲染子窗口（Messiah 引擎很常见）。
   有的话把 `config/win_backend.json` 里加上 `"inputTarget": "capture"`
   （输入直接发给渲染子窗口，坐标改成相对子窗口），再跑一次 `smoke_win.py --input`；
2. 如果两种目标都无效、只有 `sendinput` 生效，才需要在前台输入（占键鼠）
   与驱动级方案（风险更高）之间做选择，并把结论告诉我。

## 三、界面（Flutter）

```bat
flutter run -d windows
```

- [ ] 设备列表能列出客户端窗口，形如 `win:12345`，多开时列出多个
- [ ] 「时空客户端工具」四个按钮可用：刷新窗口 / 确保客户端运行 / 重启客户端 / 窗口对齐
- [ ] 「截图后端自检」能返回每个后端的实测结果
- [ ] 「痒痒鼠」标签标注"（不支持）"，点击给出明确说明
- [ ] 关闭程序后 `python.exe`（常驻服务）也随之退出

## 四、自定义流程（核心）

准备一个最小流程：**固定坐标点击**（点一个安全位置）→ **等待 1 秒**。

先做**离线自检**：运行器带 `--dry-run`，只读配置文件、不连窗口、不点游戏，
把步骤数、模板图、录制流程引用都核一遍。界面上跑之前先验一次，能省掉
"跑起来才发现模板丢了"的来回：

```bat
:: 配置文件在界面执行时生成，也可以手动喂给运行器自检
python scripts\win\flow_runner_win.py <custom_flow_config.json> --dry-run
python scripts\win\record_runner_win.py <recorded_flow_config.json> --dry-run
```

通过时返回 0 并打印 `自检通过`；有问题返回 1，并指出是第几个步骤、
缺哪张模板图、引用了不存在的录制流程，或者用了时空版不支持的「痒痒鼠模式」步骤。

界面上也有同样的入口（只在时空模式下出现）：

- [ ] 「自定义流程」页点「流程自检（不连游戏）」，输出区出现自检结果；
      故意删掉一张模板图后再自检，会弹窗指出是第几个步骤缺图
- [ ] 流程为空时「流程自检（不连游戏）」是灰的（点了不该没有任何反应）

- [ ] 点「执行自定义流程」后弹出终端窗口，日志里出现 `截图开始/截图完成`
- [ ] 日志里点击坐标为设计坐标（0-1598 / 0-898），窗口非 1600×900 时点击位置依然正确
- [ ] 加一个「识图点击」步骤（用 1600×900 下的截图做模板），能命中并点击
- [ ] 加一个「粘贴文字」步骤，文字能进入游戏输入框（重复执行时会先清空）
- [ ] 「重启当前 Activity」步骤能重启客户端，重启后**后续步骤继续可用**（PID 变了也要能跟上）
- [ ] 多开两个客户端，选两台设备并行执行，两个窗口都能被点（互不干扰）
- [ ] 循环块 / 识图分支 / 流程组按预期工作
- [ ] 编辑期提示：把某个「识图点击」步骤的模板图删掉，步骤卡片上立刻出现红字
      （`第 N 步：…没有选择模板图片…`），「流程操作」下方出现汇总

## 五、手势录制与回放

```bat
:: 命令行自检：录 10 秒后把动作 JSON 打到控制台
python scripts\win\win_record.py 10
```

- [ ] 录到了点击（`type: tap`）、长按（`longPress`）、滑动（`swipe`）
- [ ] 滑动动作带 `dragPath` 采样点，`delayMs` 与操作节奏一致
- [ ] 界面上「手势录制」开始/停止后能保存流程，动作数与界面显示一致
- [ ] 回放该流程能复现同样的操作
- [ ] 把流程加进回放列表后点「录制流程自检（不回放）」，输出区能列出动作数；
      回放列表为空时该按钮是灰的
- [ ] 录制期间切到别的窗口操作**不会**被录进来（多开时不会串台）
- [ ] 编辑期提示：手工把录制文件里的坐标改成超出分辨率的值（或回放一条旧安卓录制的
      流程），回放列表里该条下面出现「坐标…超出录制分辨率…」；
      原始指针事件（down/move/up/cancel）显示为红字问题

**注意**：低级鼠标钩子只能看到同等或更低完整性级别的输入。
若游戏以管理员运行而常驻服务没有，会表现为"一个动作都录不到"——此时用管理员重开。

## 六、常见问题定位

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| 截图全黑 | 客户端用 GPU 渲染且禁用了 `PrintWindow` | `config/win_backend.json` 里换 `captureOrder`；用 `--probe_capture` 找可用后端 |
| 点击无效但截图正常 | 发错了窗口（渲染子窗口）或后台消息被引擎忽略 | 先试 `"inputTarget": "capture"`；再改 `inputOrder` 为 `["sendinput"]`；最后才考虑前台 |
| 报"未找到时空客户端控制脚本" | 脚本目录不在预期位置 | 从工程根目录运行，或用含资源的完整安装包 |
| 控制服务启动即退出 | Python 不可用/依赖缺失/不在 Windows | `python --version`；安装 `numpy opencv-python`；非 Windows 平台会直接提示并退出（退出码 2） |
| 录不到动作 | 权限不够（UIPI） | 常驻服务与游戏同为管理员权限 |
| 重启后点击没反应 | 没等到新窗口 | 日志里应有"设备已重新绑定到 win:新的PID"；没有则检查启动器是否需人工登录 |

## 七、验收记录（请回填）

```
日期：__________
客户端版本：__________（安装包 MYM-x.y.z.exe）
截图后端：__________  输入后端：__________  文本后端：__________
客户区尺寸：__________
后台点击是否生效：__________
多开数量：__________
其他异常：__________
```
