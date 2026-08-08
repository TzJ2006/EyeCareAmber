import AppKit
import SwiftUI

struct AmberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var engine = Engine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(engine: engine)
                .environment(\.locale, engine.settings.language.locale)
        } label: {
            Image(systemName: symbolName)
        }
        .menuBarExtraStyle(.window)
    }

    private var symbolName: String {
        guard engine.settings.enabled else { return "eye.slash" }
        if engine.isPaused { return "pause.circle" }
        switch engine.target.phase {
        case .night, .dusk: return "moon.stars.fill"
        case .evening:      return "sun.horizon.fill"
        default:            return "sun.max.fill"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 纯菜单栏应用：不进 Dock、不进 Cmd-Tab。
        NSApp.setActivationPolicy(.accessory)
        Engine.shared.start()
        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.shutdown()
    }

    /// 被 `kill` / 注销掉时也要把显示器还原。
    ///
    /// CoreGraphics 在设置 LUT 的进程退出时通常会自己恢复，但那是实现细节，
    /// 不该赖着它 —— 让用户的屏幕卡在琥珀色是很糟糕的失败模式。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    Engine.shared.shutdown()
                    exit(0)
                }
            }
            src.resume()
            Self.signalSources.append(src)
        }
    }

    private static var signalSources: [DispatchSourceSignal] = []
}
