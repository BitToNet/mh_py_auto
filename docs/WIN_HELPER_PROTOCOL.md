# 时空客户端常驻控制服务 · 协议说明（P2）

`tools/win_helper.py` 是 Flutter 侧与 Win32 之间的常驻进程，负责：设备枚举、实时截图、点击/输入、
窗口尺寸、客户端启停。流程执行本身不经过它（流程运行器在 Python 侧直接调用设备层），
它服务的是**界面交互**与**需要常驻的场景（如 P5 的全局录制钩子）**。

## 一、启动方式

```bat
python tools\win_helper.py                     :: 作为常驻服务（stdin/stdout 走 JSON-Lines）
python tools\win_helper.py --health            :: 跑一次自检后退出（人肉排查用）
python tools\win_helper.py --list              :: 列出所有命令
python tools\win_helper.py --shot-dir D:\shots :: 指定截图输出目录
```

Flutter 侧建议用 `Process.start` 拉起，stdin/stdout 都是 UTF-8 文本行。

## 二、协议

当前协议版本：**1**（`ping` 的 `protocol` 字段；改协议时一起改这里）。

**请求**（一行一个 JSON）：

```json
{"id": 1, "cmd": "click", "args": {"deviceId": "win:12345", "x": 800, "y": 450}}
```

**响应**（一行一个 JSON，顺序与请求一致）：

```json
{"id": 1, "ok": true, "data": {"ok": true, "method": "postmessage", "realPoint": [800, 450]}, "error": null}
```

约定：

- 只有响应写 **stdout**；日志全部走 **stderr**，不要混读。
- 任何异常都不会让服务退出，只会返回 `ok:false` + `error`。
- 设备操作自身的失败（例如点击后端全部不可用）会被提升为 `ok:false`，细节仍在 `data` 里。
- `id` 原样回显；解析失败时 `id` 为 `null`。
- `shutdown` 命令会让服务退出（响应返回后进程结束）。

## 三、命令一览

| cmd | args | data |
| --- | --- | --- |
| `ping` | — | 协议版本、pid、是否 Windows、运行时长、截图目录 |
| `health` | — | 平台/管理员/屏幕/设备清单/首个设备截图自检 |
| `list_devices` | `includeOther?` | `{count, devices}`（设备数组见下） |
| `refresh` | `includeOther?` | `{count, devices}`，强制重新枚举 |
| `config` | `set?` | 当前配置（`set` 为要覆盖的键值） |
| `capture` | `deviceId?`, `normalize?`(默认 true), `method?`, `savePath?`, `encode?` | `{path, width, height, method, metrics}`；`encode="png_base64"` 时附 `pngBase64` |
| `probe_capture` | `deviceId?`, `order?` | 逐个截图后端的实测结果 |
| `click` | `deviceId?`, `x`, `y`, `designCoords?`(默认 true), `randomRadius?`, `method?`, `button?` | `{ok, method, realPoint}` |
| `double_click` | `deviceId?`, `x`, `y` | `{ok, method, realPoint}` |
| `swipe` | `deviceId?`, `x1`,`y1`,`x2`,`y2`, `durationMs?`, `method?` | `{ok, method, realFrom, realTo}` |
| `drag` | 同 `swipe` + `durationMs` | 同上 |
| `scroll` | `deviceId?`, `x`, `y`, `delta`(120 为一格，负=向下) | `{ok, method}` |
| `text` | `deviceId?`, `text`, `method?` | `{ok, method, length}` |
| `key` | `deviceId?`, `vk`(虚拟键码) | `{ok, method}` |
| `activate` | `deviceId?` | 置前台/取消最小化 |
| `resize` | `deviceId?`, `width?`, `height?`, `force?` | `{ok, matched, size, device}` |
| `ensure_running` | `deviceId?`, `timeout?` | 已在运行→`already`；最小化→恢复；都没有→拉起启动器 |
| `start` / `stop` / `restart` | `timeout?` / `deviceId?`,`includeLauncher?` / `deviceId?`,`timeout?` | 客户端启停结果 |
| `record_start` | `deviceId?`, `sampleIntervalMs?`(默认 16) | `{ok, device, status}`；安装 WH_MOUSE_LL 开始录制 |
| `record_poll` | — | `{running, eventCount, actionCount, actions}`；录制中轮询 |
| `record_stop` | — | `{ok, actions, actionCount, screenWidth, screenHeight, deviceId, durationSeconds}` |
| `stats` | — | 截图/输入后端命中与失败计数、当前设备快照 |
| `shutdown` | — | 让服务退出 |

### 手势录制（`record_*`）

- `record_start` 在常驻服务进程里安装全局低级鼠标钩子（`WH_MOUSE_LL`），
  **录制期间不要关闭常驻服务**；同时只允许一个录制任务。
- 只有落在目标窗口（或同 PID 窗口）上的按下才会开始一段动作，多开时不会串台；
  按下之后的移动/抬起全部记录，直到抬起。
- 输出动作与 Android 版录制格式完全一致（`type/delayMs/startX/startY/endX/endY/
  durationMs/holdBeforeMoveMs/dragPath/rawEvents`），坐标是**设计分辨率 1600×900**。
- 钩子只能看到同等或更低完整性级别的进程输入：目标客户端若以管理员运行，
  常驻服务也需要管理员权限，否则录不到事件（表现为 `actionCount` 一直是 0）。

### 设备对象（`list_devices` / `refresh` 的 `devices` 元素）

```json
{
  "deviceId": "win:12345",     // 对上层唯一标识，稳定；内部再解析成 HWND
  "pid": 12345,
  "hwnd": 4194304,
  "title": "梦幻西游：时空",
  "exeName": "MyGame_x64r.exe",
  "kind": "game",              // game | launcher | other
  "captureHwnd": 4194304,      // 真正能截到画面的窗口（可能是子窗口）
  "inputHwnd": 4194304,        // 接收消息的窗口（一般是顶层窗口）
  "offset": [0, 0],            // capture 窗口相对顶层客户区左上角的偏移
  "captureSize": [1600, 900],  // 截图/坐标空间的真实尺寸
  "clientSize": [1600, 900],
  "isChildCapture": false,
  "foreground": true,
  "minimized": false,
  "dpi": 96
}
```

## 四、坐标约定（重要）

**所有坐标都是「设计分辨率」坐标**（默认 1600×900），与自定义流程、录制流程、模板图片完全一致。

- `click/swipe/drag/scroll`：传入设计坐标，服务自动换算成真实窗口坐标再发送消息。
- 需要绝对真实坐标时传 `"designCoords": false`。
- `capture`：默认把图像归一化到 1600×900 再返回，所以模板匹配无需关心窗口实际大小。
- 窗口不是 1600×900 时：截图按比例缩放到设计分辨率，点击按比例放大回真实坐标；
  若 `autoResize` 打开且窗口允许，会直接把客户区调成设计分辨率（此时比例为 1:1，最准）。

## 五、错误码与排查

| 现象 | 含义 | 处理 |
| --- | --- | --- |
| `设备不存在` | `deviceId` 对应的窗口已关闭 | 先 `list_devices` 刷新 |
| `截图失败（可能窗口已关闭或全部后端不可用）` | 所有截图后端都拿不到画面 | 用 `probe_capture` 看哪个后端有黑屏率问题 |
| `SetWindowPos 失败` / `窗口处于最小化状态` | 窗口不允许改尺寸或最小化中 | `ensure_running` 恢复窗口，或接受按比例缩放 |
| `找不到客户端启动器` | 自动推断失败 | 在 `config/win_backend.json` 里配 `launcherPath` |

## 六、示例（一次完整交互）

```json
{"id":1,"cmd":"health","args":{}}
{"id":2,"cmd":"list_devices","args":{}}
{"id":3,"cmd":"capture","args":{"deviceId":"win:12345"}}
{"id":4,"cmd":"click","args":{"deviceId":"win:12345","x":800,"y":450}}
{"id":5,"cmd":"text","args":{"deviceId":"win:12345","text":"hello"}}
{"id":6,"cmd":"capture","args":{"deviceId":"win:12345"}}
{"id":7,"cmd":"shutdown","args":{}}
```
