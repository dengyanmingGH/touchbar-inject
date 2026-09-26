# TBBar — Touch Bar AI 应用快捷按钮

将常用 AI 应用的启动按钮**常驻**显示在 MacBook 的物理 Touch Bar（触控条）上，无论你在用哪个 App，4 个按钮始终可见，点一下即可启动对应应用。

**适用机型**：MacBook Pro 13" 2016–2021（带 Touch Bar 的机型），macOS 13+

---

## 工作原理

macOS 提供了一个私有类方法：

```objc
+[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]
```

调用后，指定的 `NSTouchBar` 会**独立于前台 App** 渲染到物理 Touch Bar 上，效果等价于 Pock / MTMR 等知名 Touch Bar 工具的核心机制。

本项目的组成：

| 文件 | 语言 | 职责 |
|---|---|---|
| `TBBar.swift` | Swift | 主程序：Touch Bar 按钮构建、菜单栏、亮度控制、启动逻辑 |
| `tbbridge.m` | Objective-C | 私有 API 桥接 + 像素级亮度缩放工具（C 函数暴露给 Swift） |
| `touchbar_inject.py` | Python | 构建 & 安装脚本（编译 Swift + ObjC → `.app`，管理 LaunchAgent） |

---

## 快速开始

### 前置条件
- macOS 13 及以上（Apple Silicon / Intel 均可，需在 Touch Bar 机型上）
- Xcode Command Line Tools（提供 `clang` / `swiftc`）
- Python 3.8+

### 一键构建 & 安装

```bash
python3 touchbar_inject.py install
```

执行成功后：
- 4 个按钮**立即**出现在 Touch Bar 上
- 菜单栏出现 ✨ 图标（备用入口，可重新呈现 / 亮度调节 / 退出）
- 日志写入 `~/.tbbar/tbbar.log`

### 完整命令

```bash
python3 touchbar_inject.py build       # 仅编译（不启动）
python3 touchbar_inject.py install     # 编译 + 启动
python3 touchbar_inject.py remove      # 停止后台进程
python3 touchbar_inject.py status      # 查看是否运行中
python3 touchbar_inject.py list        # 列出按钮配置
python3 touchbar_inject.py autostart   # 安装开机自启（LaunchAgent）
python3 touchbar_inject.py noautostart # 卸载开机自启
```

---

## 自定义按钮

编辑 `TBBar.swift` 中的 `buttons` 数组，每个按钮对应一个 macOS App Bundle ID：

```swift
let buttons: [TBButton] = [
    TBButton(label: "TRAEWork",
            bundleId: "cn.trae.solo.app",
            symbol: "sparkles",                       // SF Symbol 名称
            tint: NSColor(red: 0.298, green: 0.553, blue: 1.0, alpha: 1.0)),
    TBButton(label: "Hermes",
            bundleId: "com.nousresearch.hermes",
            symbol: "terminal",
            tint: NSColor(red: 1.0, green: 0.478, blue: 0.271, alpha: 1.0)),
    TBButton(label: "豆包",
            bundleId: "com.work.pc.doubao",
            symbol: "torus",
            tint: NSColor(red: 0.251, green: 0.502, blue: 0.878, alpha: 1.0)),
    TBButton(label: "Agnes",
            bundleId: "com.agnes.code",
            symbol: "code",
            tint: NSColor(red: 0.608, green: 0.349, blue: 0.710, alpha: 1.0)),
]
```

- `symbol`：任何有效的 [SF Symbol 名称](https://developer.apple.com/sf-symbols/)
- `tint`：按钮底色（自动随亮度缩放）
- `bundleId`：App 的 Bundle Identifier（用 `open -b` 启动）

修改后执行 `python3 touchbar_inject.py install` 重新构建即可。

---

## 亮度控制

Touch Bar 使用 OLED 屏，较低亮度可减缓像素衰减（烧屏）。TBBar 支持 0–100% 亮度调节：

**持久化位置**：`~/.tbbar/config.json`

```json
{ "brightness": 75 }
```

**运行时调节**：菜单栏 ✨ 图标 → **亮度** → 预设档位（50% / 75% / 100%）或自定义输入。

亮度同时作用于：
- **图标**（SF Symbol）：像素级 RGB × factor，保持透明区域不受影响
- **按钮底色**（bezelColor）：RGB 三通道 × factor，色相不变

---

## 目录结构

**仓库内源码：**

```
touchbar-inject/
├── TBBar.swift            # Swift 主程序
├── tbbridge.m             # ObjC 桥接（私有 API + 亮度工具）
├── touchbar_inject.py     # 构建 & 安装脚本
├── README.md
└── .gitignore
```

**构建后生成（已在 .gitignore 中忽略）：**

```
├── TBBar.app/             # 编译产物（默认输出到项目目录，也可软链到 /Applications）
├── tbbridge.o             # 编译中间产物
└── tbbar.log              # 历史日志（运行时实际写到 ~/.tbbar/tbbar.log）
```

---

## 常见问题

**按钮不显示？**
- 确认你的 Mac 有物理 Touch Bar（13" 2016–2021 的 Pro 机型）
- 查看日志 `~/.tbbar/tbbar.log`，确认 `SystemModalTouchBar.available = true`
- 若为 `false`（未来系统移除私有 API），会自动回退到 App 级 Touch Bar：点击菜单栏 ✨ 图标后激活本 App 才显示

**如何停止？**
```bash
python3 touchbar_inject.py remove
# 或
pkill -f TBBar.app
```

**开机自启**
```bash
python3 touchbar_inject.py autostart    # 安装
python3 touchbar_inject.py noautostart  # 卸载
```

---

## 免责声明

本项目使用 macOS 私有 API（`presentSystemModalTouchBar:`），Apple 未公开承诺其长期稳定性。若未来系统版本移除该接口，程序会自动降级为普通 App 级 Touch Bar（需激活本 App 才显示），不影响其他功能。
