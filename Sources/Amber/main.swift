import Foundation

// `--selftest` 走纯计算路径，不启动 GUI、不碰显示器。
if Diagnostics.runIfRequested() {
    exit(0)
}

AmberApp.main()
