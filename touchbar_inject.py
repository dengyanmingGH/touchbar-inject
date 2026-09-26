#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Touch Bar：4 个 AI 应用快捷按钮（官方 NSTouchBar 框架，v2）
==========================================================

背景 / 原理：
  这台 Mac 是 MacBook Pro 13 英寸 M1 (2020)，序列号 C02GL5CPQ05N，
  是最后搭载 Touch Bar 硬件的 13 英寸 Pro 机型，确实有物理 Touch Bar
  （键盘顶部的触控条 + 右侧 Touch ID）。
  系统有 TouchBarServer + ControlStrip 两个常驻进程负责渲染。

  本工具用 **macOS 的「系统模态 Touch Bar」** 实现（v4）：
    - 调用 AppKit 私有类方法（运行时存在）：
        +[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]
      它会把一个 NSTouchBar **独立于前台 App** 渲染到物理 Touch Bar 上；
    - 效果：无论你当前在用哪个 App（Trae / 微信 / 浏览器…），
      这 4 个按钮都常驻在 Touch Bar 上，点一下就启动对应应用；
    - 不抢焦点、不拦截键盘、不需要激活本 App，完全不干扰输入；
    - 私有 API 的调用封装在 tbbridge.m（Objective-C）里，最稳妥。

  兜底：若该私有接口在未来系统版本上消失，会自动回退为「App 级 Touch Bar」
       （点击菜单栏图标激活本 App 时按钮显示在 Touch Bar 上）。

四个按钮（带 SF Symbol 图标 + 颜色）：
  1. TRAEWork   -> cn.trae.solo.app
  2. Hermes     -> com.nousresearch.hermes
  3. 豆包        -> com.work.pc.doubao
  4. AgnesCode  -> com.agnes.code

使用：
  python3 touchbar_inject.py build      # 编译 host app（.app）
  python3 touchbar_inject.py install    # 编译并启动（按钮常驻 Touch Bar）
  python3 touchbar_inject.py remove     # 停止 host app
  python3 touchbar_inject.py list       # 列出按钮配置
  python3 touchbar_inject.py status     # 查看运行状态
  python3 touchbar_inject.py autostart  # 安装开机自启 LaunchAgent
  python3 touchbar_inject.py noautostart# 卸载开机自启

说明：
  - 按钮常驻物理 Touch Bar；菜单栏的 sparkles 图标是备用入口
    （「显示到 Touch Bar」可重新呈现，若不慎关掉 Touch Bar 上的按钮条可点它恢复）。
  - 运行日志写在 .app 同级的 tbbar.log，便于排查。
  - host app 常驻后台（LSUIElement，不出 Dock），占用极少，不拦截键盘事件。
"""

import os
import sys
import subprocess
import tempfile
from typing import Optional

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SWIFT_SRC = os.path.join(SCRIPT_DIR, "TBBar.swift")
APP_NAME = "TBBar.app"
APP_DIR = os.path.join(SCRIPT_DIR, APP_NAME)
BIN_NAME = "TBBar"
BIN_PATH = os.path.join(APP_DIR, "Contents", "MacOS", BIN_NAME)
LAUNCHAGENT = os.path.expanduser(
    "~/Library/LaunchAgents/local.tbbar.plist")
LAUNCHAGENT_LABEL = "local.tbbar.inject"

BUTTONS = [
    {"label": "TRAEWork", "bundle_id": "cn.trae.solo.app"},
    {"label": "Hermes", "bundle_id": "com.nousresearch.hermes"},
    {"label": "豆包", "bundle_id": "com.work.pc.doubao"},
    {"label": "Agnes", "bundle_id": "com.agnes.code"},
]


def run(cmd, check=False, timeout=180):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        return (p.returncode == 0, out.strip())
    except Exception as e:
        return (False, str(e))


def build() -> bool:
    """编译 TBBar.swift + tbbridge.m 为 .app 可执行文件。"""
    if not os.path.exists(SWIFT_SRC):
        print(f"[ERROR] 找不到源码 {SWIFT_SRC}")
        return False

    objc_src = os.path.join(SCRIPT_DIR, "tbbridge.m")
    objc_obj = os.path.join(SCRIPT_DIR, "tbbridge.o")
    if not os.path.exists(objc_src):
        print(f"[ERROR] 找不到源码 {objc_src}")
        return False

    macos_dir = os.path.join(APP_DIR, "Contents", "MacOS")
    os.makedirs(macos_dir, exist_ok=True)

    # Info.plist（LSUIElement = 不出现在 Dock / 程序菜单）
    info = os.path.join(APP_DIR, "Contents", "Info.plist")
    with open(info, "w", encoding="utf-8") as f:
        f.write("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>%s</string>
  <key>CFBundleIdentifier</key><string>local.tbbar.inject</string>
  <key>CFBundleName</key><string>TBBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>4.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
""" % BIN_NAME)

    # 1) 用 clang 编译 Objective-C 桥接（调用 NSTouchBar 私有系统模态接口）
    ok, out = run(["clang", "-c", objc_src, "-o", objc_obj, "-fobjc-arc"])
    print(f"[clang tbbridge.m] {'OK' if ok else 'FAIL'}")
    if not ok:
        print(out)
        return False

    # 2) 用 swiftc 编译 Swift 主体并链接桥接目标文件
    cmd = [
        "swiftc",
        "-O",
        "-o", BIN_PATH,
        SWIFT_SRC,
        objc_obj,
        "-framework", "Cocoa",
        "-target", "arm64-apple-macosx13.0",
    ]
    ok, out = run(cmd, check=False)
    print(f"[compile] {'OK' if ok else 'FAIL'}")
    if not ok:
        print("  swiftc 输出：")
        for line in out.splitlines():
            print("   ", line)
        return False
    os.chmod(BIN_PATH, 0o755)
    # ad-hoc 签名（否则部分系统上无法正常运行）
    run(["codesign", "-s", "-", "-f", APP_DIR], check=False)
    print(f"[compile] 已生成 {APP_DIR}")
    return True


def find_pid() -> Optional[int]:
    p = subprocess.run(["pgrep", "-f", f"{BIN_NAME}"], capture_output=True, text=True)
    if p.returncode == 0:
        pids = p.stdout.split()
        if pids:
            return int(pids[0])
    return None


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    action = sys.argv[1]

    if action == "list":
        print("按钮配置：")
        for i, b in enumerate(BUTTONS, 1):
            print(f"  {i}. {b['label']:<10} -> {b['bundle_id']}")
        return 0

    if action == "status":
        pid = find_pid()
        print(f"{'运行中 PID=' + str(pid) if pid else '未运行'}")
        return 0

    if action == "build":
        return 0 if build() else 1

    if action == "install":
        if not build():
            print("[ERROR] 编译失败，无法启动。")
            return 1
        pid = find_pid()
        if pid:
            run(["kill", str(pid)])
            print(f"[stop] 已终止旧实例 PID={pid}")
        ok, out = run(["open", APP_DIR], check=False)
        if ok:
            print(f"[done] host app 已启动：{APP_DIR}")
            print("      Touch Bar 上现在应常驻 4 个 AI 应用按钮（TRAEWork / Hermes / 豆包 / Agnes），")
            print("      点击即启动对应应用；切换任何 App 都不会消失，也不会抢焦点。")
            print("      菜单栏 sparkles 图标 = 备用入口（可重新呈现 / 直接启动 / 退出）。")
            return 0
        print("[install] 输出：")
        print(out)
        return 1

    if action == "remove":
        pid = find_pid()
        if pid is None:
            print("[hint] 未找到运行中的 TBBar，可能已停止。")
            return 0
        ok, out = run(["kill", str(pid)], check=False)
        if ok:
            print(f"[done] host app 已停止（PID={pid}）。")
        else:
            print("终止失败：")
            print(out)
        return 0 if ok else 1

    if action == "autostart":
        os.makedirs(os.path.dirname(LAUNCHAGENT), exist_ok=True)
        with open(LAUNCHAGENT, "w", encoding="utf-8") as f:
            f.write(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{LAUNCHAGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>open "{APP_DIR}"</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
""")
        run(["launchctl", "load", "-w", LAUNCHAGENT])
        print(f"[done] 开机自启已安装：{LAUNCHAGENT}")
        print("      现在 host app 也会随登录启动；若之前未运行，请再执行一次 install。")
        return 0

    if action == "noautostart":
        if os.path.exists(LAUNCHAGENT):
            run(["launchctl", "unload", "-w", LAUNCHAGENT])
            os.remove(LAUNCHAGENT)
            print(f"[done] 开机自启已卸载：{LAUNCHAGENT}")
        else:
            print("[hint] 未找到 LaunchAgent，可能已卸载。")
        return 0

    print(f"未知命令：{action}")
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
