// TBBar.swift — 把 4 个 AI 应用按钮常驻显示在 MacBook 的物理 Touch Bar 上。
//
// 关键机制（macOS 的「系统模态 Touch Bar」）：
//   macOS 提供了一个私有类方法：
//       +[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]
//   调用后，这个 NSTouchBar 会**独立于前台 App**渲染到物理 Touch Bar 上，
//   无论你当前在用哪个 App，这 4 个按钮都一直在 Touch Bar 上；
//   且不会抢焦点、不会干扰输入（不需要 activate）。
//   Pock / MTMR 等 Touch Bar 工具用的就是这个机制。
//
//   （Apple 没有把它放进公开头文件，但运行时依然存在；本程序通过
//     Objective-C runtime 直接调用，并在调用前检测是否可用。）
//
// 兜底：若该私有接口在未来系统上消失，则退回「App 级 Touch Bar」，
//       即点击菜单栏图标激活本 App 时，4 个按钮显示在 Touch Bar 上。
import Cocoa
import ObjectiveC.runtime

// ---------------------------------------------------------------------------
// 日志（固定写到 ~/.tbbar/tbbar.log，与 .app 安装位置无关，便于排查）
// ---------------------------------------------------------------------------
let LOG_DIR: String = {
    let home = NSHomeDirectory()
    let d = (home as NSString).appendingPathComponent(".tbbar")
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}()
let LOG_PATH = (LOG_DIR as NSString).appendingPathComponent("tbbar.log")

func tbLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: LOG_PATH) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(toFile: LOG_PATH, atomically: true, encoding: .utf8)
    }
}

// ---------------------------------------------------------------------------
// 亮度控制（0~100，默认 75 偏暗，降低 OLED 电流 / 减缓烧屏）
//   持久化到 ~/.tbbar/config.json；菜单可实时调节并即时生效
// ---------------------------------------------------------------------------
let CONFIG_DIR: String = LOG_DIR
let CONFIG_PATH = (CONFIG_DIR as NSString).appendingPathComponent("config.json")

func loadBrightness() -> Int {
    let keys = ["brightness"]
    for k in keys {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH)),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let v = o[k] as? Int {
            return min(100, max(0, v))
        }
    }
    return 75
}

func saveBrightness(_ v: Int) {
    let v = min(100, max(0, v))
    let obj: [String: Int] = ["brightness": v]
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
        try? data.write(to: URL(fileURLWithPath: CONFIG_PATH))
    }
    tbLog("brightness -> \(v)%")
}

var gBrightness: Int = 75   // 默认 75%（偏暗）

// 把一张 SF Symbol 图像按亮度降为：对每个像素通道做 value = value × brightness
//   （缩放而非"叠黑"，保持色相 HSB.H/S 不变，只调亮度 V）
//   brightness = 100 → 原图；50 → 亮度减半；0 → 全黑
//   图标与按钮色块使用同一系数，保证明暗一致。
// 把一张 SF Symbol 图像按亮度缩放（委托 ObjC bridge 做像素级 RGB×factor，
// 保持 alpha 与色相；factor = brightness/100）
func dimmed(_ image: NSImage, _ brightness: Int) -> NSImage {
    let f = Float(brightness) / 100.0
    return TB_dimImage(image, f)
}

// 把按钮底色（bezelColor）按亮度调整：保留色相 H、饱和度 S，把 HSB 的 V × factor
// 在深色 Touch Bar 上得到"可控明暗的彩色块"，与图标使用同一系数，明暗一致。
func dimmed(_ color: NSColor, _ brightness: Int) -> NSColor {
    let f = Float(brightness) / 100.0
    // 兜底：ObjC 侧失败会返回原色，避免崩溃
    let out = TB_dimColor(color, f)
    return out
}

// ---------------------------------------------------------------------------
// 按钮配置
// ---------------------------------------------------------------------------
struct TBButton {
    let label: String
    let bundleId: String
    let symbol: String
    let tint: NSColor
}

let buttons: [TBButton] = [
    TBButton(label: "TRAEWork", bundleId: "cn.trae.solo.app",
             symbol: "sparkles",
             tint: NSColor(red: 0.298, green: 0.553, blue: 1.0, alpha: 1.0)),
    TBButton(label: "Hermes", bundleId: "com.nousresearch.hermes",
             symbol: "terminal",
             tint: NSColor(red: 1.0, green: 0.478, blue: 0.271, alpha: 1.0)),
    TBButton(label: "豆包", bundleId: "com.work.pc.doubao",
             symbol: "torus",
             tint: NSColor(red: 0.251, green: 0.502, blue: 0.878, alpha: 1.0)),
    TBButton(label: "Agnes", bundleId: "com.agnes.code",
             symbol: "code",
             tint: NSColor(red: 0.608, green: 0.349, blue: 0.710, alpha: 1.0)),
]

func itemIdentifier(_ i: Int) -> NSTouchBarItem.Identifier {
    NSTouchBarItem.Identifier("tbbar.app.\(i)")
}

func launch(_ b: TBButton) {
    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = ["-c", "open -b \(b.bundleId)"]
    try? task.run()
    tbLog("launch \(b.label) -> \(b.bundleId)")
}

// ---------------------------------------------------------------------------
// 私有 API 封装：系统模态 Touch Bar
//   实现在 tbbridge.m（ObjC），通过 C 函数暴露给 Swift。
//   +[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]
//   +[NSTouchBar dismissSystemModalTouchBar:]
// ---------------------------------------------------------------------------
@_silgen_name("TB_systemModalTouchBarAvailable")
func TB_systemModalTouchBarAvailable() -> Bool

@_silgen_name("TB_presentSystemModalTouchBar")
func TB_presentSystemModalTouchBar(_ tb: NSTouchBar, _ trayItemIdentifier: NSString?)

@_silgen_name("TB_dismissSystemModalTouchBar")
func TB_dismissSystemModalTouchBar(_ tb: NSTouchBar)

// ObjC bridge：像素级亮度工具（TB_dimImage / TB_dimColor 实现在 tbbridge.m）
@_silgen_name("TB_dimImage")
func TB_dimImage(_ image: NSImage, _ factor: Float) -> NSImage

@_silgen_name("TB_dimColor")
func TB_dimColor(_ color: NSColor, _ factor: Float) -> NSColor

enum SystemModalTouchBar {
    static var available: Bool { TB_systemModalTouchBarAvailable() }

    @discardableResult
    static func present(_ tb: NSTouchBar, systemTrayItemIdentifier: NSTouchBarItem.Identifier? = nil) -> Bool {
        guard available else { return false }
        TB_presentSystemModalTouchBar(tb, systemTrayItemIdentifier?.rawValue as NSString?)
        tbLog("presentSystemModalTouchBar 已调用 (tray=\(systemTrayItemIdentifier?.rawValue ?? "nil"))")
        return true
    }

    static func dismiss(_ tb: NSTouchBar) {
        guard available else { return }
        TB_dismissSystemModalTouchBar(tb)
        tbLog("dismissSystemModalTouchBar 已调用")
    }
}

// ---------------------------------------------------------------------------
// App 主体
// ---------------------------------------------------------------------------
final class TBApp: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    var touchBar: NSTouchBar?
    var itemCache: [NSTouchBarItem.Identifier: NSButtonTouchBarItem] = [:]
    var statusItem: NSStatusItem?
    var usingSystemModal = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 不出现在 Dock
        gBrightness = loadBrightness()          // 从 config.json 读回上次的亮度
        tbLog("=== TBBar 启动 (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) ===")
        tbLog("SystemModalTouchBar.available = \(SystemModalTouchBar.available)  brightness=\(gBrightness)%")

        buildStatusItem()
        buildTouchBar()

        // 稍等一下，确保 TouchBarServer 已就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.present()
        }

        // 诊断模式（TB_DEBUG_VIS=1）：每 3 秒记录一次可见性与当前前台 App
        if ProcessInfo.processInfo.environment["TB_DEBUG_VIS"] != nil {
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                tbLog("vis=\(self?.touchBar?.isVisible ?? false)  frontmost=\(front)")
            }
        }
    }

    // MARK: - 构造 Touch Bar
    func buildTouchBar() {
        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [.flexibleSpace] + (0..<buttons.count).map(itemIdentifier) + [.flexibleSpace]
        tb.customizationAllowedItemIdentifiers = (0..<buttons.count).map(itemIdentifier)
        self.touchBar = tb
    }

    // MARK: - 系统模态呈现
    func present() {
        guard let tb = touchBar else { return }
        if SystemModalTouchBar.available {
            usingSystemModal = SystemModalTouchBar.present(tb)
        }
        if !usingSystemModal {
            // 兜底：App 级 Touch Bar（点击菜单栏图标激活时才显示）
            tbLog("回退到 App 级 Touch Bar（NSApp.touchBar）")
            NSApp.touchBar = tb
        }
        // 记录可见状态（1.5s 后）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            tbLog("touchBar.isVisible = \(tb.isVisible)")
        }
    }

    // MARK: - 菜单栏（备用入口 + 退出 + 亮度调节）
    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "TBBar")
            btn.image?.isTemplate = true
            btn.toolTip = "TBBar：AI 应用 Touch Bar 按钮（默认亮度 \(gBrightness)%）"
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "显示到 Touch Bar", action: #selector(onShow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        // —— 亮度调节子菜单 ——
        let brightItem = NSMenuItem(title: "亮度（Touch Bar 图标）", action: nil, keyEquivalent: "")
        let brightMenu = NSMenu()
        brightMenu.title = "亮度"
        // 预设档位（50% 最暗 / 75% 适中 / 100% 全亮）+ 自定义输入
        let presets: [(Int, String)] = [(50, "50% 最暗"), (75, "75% 适中"), (100, "100% 全亮")]
        for (v, title) in presets {
            let mi = NSMenuItem(title: title, action: #selector(onSetBrightness(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = v
            mi.state = (v == gBrightness) ? .on : .off
            brightMenu.addItem(mi)
        }
        brightMenu.addItem(.separator())
        // 自定义 0~45 / 45~95 步进 5
        let customTitle = NSMenuItem(title: "自定义…", action: #selector(onCustomBrightness), keyEquivalent: "")
        brightMenu.addItem(customTitle)
        brightItem.submenu = brightMenu
        menu.addItem(brightItem)

        menu.addItem(.separator())
        for (i, b) in buttons.enumerated() {
            let mi = NSMenuItem(title: "打开 \(b.label)", action: #selector(onQuickLaunch(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        self.statusItem = item
    }

    @objc func onShow() {
        present()
    }

    @objc func onSetBrightness(_ sender: NSMenuItem) {
        let v = sender.tag
        gBrightness = v
        saveBrightness(v)
        // 刷新菜单栏标题 + 当前档位勾选
        if let top = statusItem?.menu {
            for mi in top.items {
                if mi.title.hasPrefix("亮度") {
                    for preset in mi.submenu?.items ?? [] {
                        if preset.action == #selector(onSetBrightness(_:)) {
                            preset.state = (preset.tag == v) ? .on : .off
                        }
                    }
                }
            }
        }
        rebuildTouchBarItems()
    }

    @objc func onCustomBrightness() {
        let alert = NSAlert()
        alert.messageText = "自定义亮度（0~100）"
        alert.informativeText = "输入 0（全黑）到 100（全亮）之间的整数，例如 60。"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        tf.stringValue = String(gBrightness)
        tf.placeholderString = "0 - 100"
        tf.alignment = .center
        alert.accessoryView = tf
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        // 让输入框聚焦
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            if let v = Int(tf.stringValue), (0...100).contains(v) {
                // 直接设值（避免构造 NSMenuItem 时 tag 默认为 0 的 bug）
                gBrightness = v
                saveBrightness(v)
                if let top = statusItem?.menu {
                    for mi in top.items {
                        if mi.title.hasPrefix("亮度") {
                            for preset in mi.submenu?.items ?? [] {
                                if preset.action == #selector(onSetBrightness(_:)) {
                                    preset.state = .off   // 自定义值时取消所有预设勾选
                                }
                            }
                        }
                    }
                }
                rebuildTouchBarItems()
            }
        }
        NSApp.hide(nil)
    }

    @objc func onQuickLaunch(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < buttons.count else { return }
        launch(buttons[sender.tag])
    }

    @objc func onQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Touch Bar 按钮回调
    @objc func onTouchBarTap(_ sender: NSButtonTouchBarItem) {
        guard let idx = (0..<buttons.count).first(where: { itemIdentifier($0) == sender.identifier }) else { return }
        launch(buttons[idx])
    }

    func applicationWillTerminate(_ note: Notification) {
        if let tb = touchBar, usingSystemModal {
            SystemModalTouchBar.dismiss(tb)
        }
    }
}

extension TBApp {
    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard let idx = (0..<buttons.count).first(where: { itemIdentifier($0) == identifier }) else {
            return nil
        }
        if let cached = itemCache[identifier] { return cached }
        let b = buttons[idx]

        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        // 按全局亮度把图标"调暗"（保持色相，叠半透明黑）
        let rawImg = NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.label)?
            .withSymbolConfiguration(cfg)
        let img: NSImage? = rawImg.map { dimmed($0, gBrightness) }

        let item = NSButtonTouchBarItem(identifier: identifier,
                                        title: b.label,
                                        image: img ?? NSImage(),
                                        target: self,
                                        action: #selector(onTouchBarTap(_:)))
        item.bezelColor = dimmed(b.tint, gBrightness)   // 按钮底色同步调暗
        item.customizationLabel = b.label
        itemCache[identifier] = item
        return item
    }

    // MARK: - 重建 Touch Bar 按钮（亮度变化后调用）
    func rebuildTouchBarItems() {
        // 清空缓存，下次 makeItemForIdentifier 时按新亮度重建
        itemCache.removeAll()
        guard let tb = touchBar else { return }
        // 触发系统重新拉取每个 item（强制重取）
        let ids = (0..<buttons.count).map(itemIdentifier)
        for id in ids {
            _ = self.touchBar(tb, makeItemForIdentifier: id)
        }
        // 重新 present 一次，让系统模态 Touch Bar 重绘
        if usingSystemModal {
            SystemModalTouchBar.dismiss(tb)
            SystemModalTouchBar.present(tb)
        }
        tbLog("rebuildTouchBarItems @\(gBrightness)%")
    }
}

let app = NSApplication.shared
let delegate = TBApp()
app.delegate = delegate
app.run()
