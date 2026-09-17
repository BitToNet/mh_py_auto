# 时空客户端控制层探测工具 · 使用说明（P1）

`tools/win_probe.py` 用来在**实机**上确定三件事，后续代码全部按它的结论写：

1. **截图**：哪种方式能截到时空客户端的真实画面（含被别的窗口盖住时）
2. **点击**：后台消息点击到底生不生效（`PostMessage` / `SendMessage` / 前台真实输入）
3. **尺寸**：能不能把客户端窗口客户区改成 `1600x900`（决定能否直接复用现有模板与流程坐标）

## 一、准备

- Windows 10/11，已安装并**能正常进游戏**的《梦幻西游：时空》
- Python 3.8+（**不需要**装任何第三方库，纯 ctypes 实现）
- 建议：客户端**窗口化**运行（不要独占全屏），不要最小化

## 二、先看一眼窗口（不会碰游戏）

```bat
cd /d <仓库路径>
python tools\win_probe.py --list-only
```

正常会看到类似：

```
共枚举到 N 个可见顶层窗口，其中候选 1 个：
  [1] hwnd=0x00123456 pid=12345 类名='...'
      标题='...'
      进程=MyGame_x64r.exe 客户区=1600x900 dpi=96 可调整=True *前台*
```

如果**一个候选都没有**，试这几招：

```bat
:: 看全部窗口，找出属于时空的那个
python tools\win_probe.py --list-only --all-windows

:: 指定关键字（进程名/标题）
python tools\win_probe.py --list-only --exe-keyword mygame --title-keyword 时空

:: 直接指定窗口句柄或进程号（从上面输出里抄）
python tools\win_probe.py --list-only --hwnd 0x00123456
python tools\win_probe.py --list-only --pid 12345
```

> 建议用**管理员权限**的 cmd/PowerShell 运行，否则可能控制不了以管理员身份启动的游戏窗口。

## 三、完整探测

**先做安全准备**：把游戏切到一个"点了也没关系"的界面（例如站在空地场景里），确认没有正在进行的战斗、交易、摆摊。

### 0) 只测截图（完全不碰游戏，最安全，先跑这个）

```bat
python tools\win_probe.py --out probe_out
```

它会枚举窗口 → 对每个候选窗口逐个截图后端实测 → 用置顶空白窗口盖住游戏再截一次。
看结论区的 `截图后端 = xxx` 即可。

### 1) 加上输入测试（会真的点击游戏）

```bat
python tools\win_probe.py --out probe_out --click-x 800 --click-y 450
```

- `--click-x/--click-y` 是**客户区坐标**，不给就点窗口正中心。
  建议给一个游戏里**点一下没有副作用**的位置（比如空地）。
- 输入测试会先量一个"什么都不做时的画面变化基线"，然后分别用三种方式点同一个位置，
  比较"点击前后画面变化"，从而判断哪种方式真的生效。
- 默认需要你输 `yes` 确认；加 `--yes` 可跳过。
- 想更准可以加 `--interactive`：每种方式点完后，工具会问你"界面出现预期变化了吗 (y/n)"，
  你的回答优先于自动判定。

### 2) 键盘输入测试（可选，需先手动点开一个可输入的输入框）

```bat
python tools\win_probe.py --out probe_out --no-input --text "abc123"
```

### 3) 窗口尺寸归一化测试（重要）

```bat
python tools\win_probe.py --out probe_out --no-input --resize 1600x900
```

结果里 `matched=True` 表示可以把客户区改成 1600×900，
那么现有那批 1600×900 的模板图片和流程坐标**可以直接复用**；
`matched=False` 就只能走"坐标按比例缩放"的路线。

### 4) 一次性全测（推荐）

```bat
python tools\win_probe.py --out probe_out --click-x 800 --click-y 450 --resize 1600x900 --interactive
```

多个客户端实例同时开着的话，工具会把**每个实例都测一遍**，可以顺带验证多开是否互相干扰。

## 四、要回传给我的东西

把整个输出目录打包发回（里面有报告 + 截图素材）：

```
probe_out/
├── win_probe_report.json      ← 结论数据（最重要）
└── probe_shots/*.bmp          ← 各方法截图，能直接当模板用
```

如果某一步报错，把**完整控制台输出**一起发我。

## 五、结果怎么解读（我会按这个写代码）

| 报告字段 | 含义 | 对方案的影响 |
| --- | --- | --- |
| `capture.<目标>.best` | 最可用的截图后端 | 决定 `win_capture.py` 的默认实现与降级顺序 |
| `capture.*.methods[].metrics.black_ratio` | 黑屏率，≈1 表示没截到画面 | 排除对应后端 |
| `occlusion.*.diff_before_vs_covered.changed_ratio` | ≈0 表示被遮挡后仍能截到真实画面 | 决定能否后台多开并行跑 |
| `input.*.baseline_ratio` | 不操作时的画面变化（动画底噪） | 点击判定阈值 |
| `input.*.<方法>.likely_effective` / `user_confirmed` | 该点击方式是否生效 | 决定 `win_input.py` 的默认实现 |
| `resize.*.matched` | 能否固定 1600×900 | 能否复用现有模板与流程 |

## 六、参数速查

| 参数 | 说明 |
| --- | --- |
| `--out DIR` | 输出目录，默认 `probe_out` |
| `--list-only` | 只枚举窗口，不做任何测试 |
| `--pid N` / `--hwnd 0x...` | 只测指定实例（hwnd 支持 `0x` 前缀） |
| `--exe-keyword K` / `--title-keyword K` | 追加候选关键字，可重复传 |
| `--all-windows` | 报告里写入全部窗口（排查用） |
| `--no-capture` | 跳过截图测试 |
| `--no-input` | 跳过点击测试（完全不碰游戏） |
| `--no-occlusion` | 跳过遮挡测试 |
| `--no-save-shots` | 不保存 BMP，只出报告（省磁盘） |
| `--click-x/--click-y` | 点击测试的客户区坐标，默认窗口中心 |
| `--text "abc"` | 键盘注入测试文本（需先点开输入框） |
| `--resize 1600x900` | 窗口尺寸归一化测试 |
| `--interactive` | 每种点击方式后人工确认（y/n），优先于自动判定 |
| `--yes` | 跳过输入测试的风险确认 |

## 七、已知限制与注意

- 本工具**只做窗口消息级操作与截图**，不注入进程、不改游戏文件、不读游戏内存。
- 输入测试会真实点击游戏，请自行承担风险（包括被反外挂判定为异常操作的可能）。
- 键盘测试为了验证"剪贴板粘贴"回退路径，**会改写系统剪贴板内容**。
- 若客户端以独占全屏运行，截图可能全黑：改成窗口化再试。
- 若三种点击方式都不生效（`likely_effective` 全为 false），说明该客户端拒收窗口消息输入，
  届时需要在"前台真实输入（会占用鼠标键盘）"和"驱动级方案（风险更高）"之间做取舍。
