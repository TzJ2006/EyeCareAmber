import AppKit

/// 全屏覆盖窗口 —— 只在两种情况下才用：
///
///   1. 需要压到显示器硬件最低亮度**以下**（深夜）。LUT 在极低亮度会出现色阶断层，
///      叠一层黑色反而更干净。
///   2. 某台显示器写不进 LUT（部分采集卡、虚拟显示器、少数外接屏），自动回落。
///
/// 平时 `extraDim == 0` 时窗口根本不存在，合成器一层都不多背。
/// 窗口内容是一个纯色 `CALayer`，没有任何重绘 —— 即使存在，开销也只是
/// 一次静态图层合成，没有 CPU 参与。
@MainActor
final class OverlayController {

    private var windows: [NSScreen: NSWindow] = [:]
    private var currentColor: NSColor = .clear
    private var active = false

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// - Parameters:
    ///   - dim: 额外调暗 0…1。
    ///   - tint: 需要覆盖层同时负责染色时（LUT 不可用）传入线性增益，否则传 nil。
    func update(dim: Double, tint: RGBGain?) {
        let color = Self.color(dim: dim, tint: tint)

        guard color.alphaComponent > 0.002 else {
            teardown()
            return
        }

        currentColor = color
        active = true
        syncWindows()
    }

    func teardown() {
        active = false
        for (_, window) in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - 颜色

    private static func color(dim: Double, tint: RGBGain?) -> NSColor {
        let d = dim.clamped(to: 0...1)

        guard let tint else {
            // 纯中性压暗：LUT 已经把颜色调好了，这里只负责再暗一点。
            return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: d)
        }

        // LUT 不可用时的回落：用「乘法」思路近似 —— 覆盖层颜色取目标增益，
        // alpha 取需要吃掉的比例。不如 LUT 精确（会抬黑位），但总比没有强。
        let peak = max(tint.r, max(tint.g, tint.b))
        guard peak > 0.001 else { return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: d) }
        let alpha = (1 - peak * (1 - d)).clamped(to: 0...0.85)
        guard alpha > 0.002 else { return .clear }

        // 覆盖层的颜色 = 我们希望「保留」的那部分光的补色方向。
        // 归一化到最暗通道，让被压得最狠的蓝通道贡献最多的遮挡。
        let inv = 1 / max(peak, 0.001)
        let sr = (tint.r * inv).clamped(to: 0...1)
        let sg = (tint.g * inv).clamped(to: 0...1)
        let sb = (tint.b * inv).clamped(to: 0...1)
        return NSColor(srgbRed: sr * 0.35, green: sg * 0.25, blue: sb * 0.10, alpha: alpha)
    }

    // MARK: - 窗口管理

    @objc private func screensChanged() {
        guard active else { return }
        // 屏幕拓扑变了，旧窗口的 frame 已经没意义，重建。
        for (_, w) in windows { w.orderOut(nil) }
        windows.removeAll()
        syncWindows()
    }

    private func syncWindows() {
        let screens = Set(NSScreen.screens)

        // 拔掉的屏幕，收掉窗口
        for (screen, window) in windows where !screens.contains(screen) {
            window.orderOut(nil)
            windows.removeValue(forKey: screen)
        }

        for screen in screens {
            let window = windows[screen] ?? makeWindow(for: screen)
            windows[screen] = window
            window.setFrame(screen.frame, display: false)
            window.contentView?.layer?.backgroundColor = currentColor.cgColor
            if !window.isVisible { window.orderFrontRegardless() }
        }
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false,
                              screen: screen)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // 点击穿透，完全不挡操作
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.sharingType = .none                // 不出现在截图 / 录屏 / 共享里
        window.displaysWhenScreenProfileChanges = true

        // 盖在包括菜单栏、Dock、全屏应用在内的一切之上。
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = currentColor.cgColor
        // 静态图层：没有重绘、没有动画、没有 display link。
        view.layer?.needsDisplayOnBoundsChange = false
        window.contentView = view

        return window
    }
}
