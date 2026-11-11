// SPDX-License-Identifier: MIT
import AppKit

// NSApplication.delegate 是弱引用，必须用全局变量强持有 AppDelegate。
private var strongAppDelegate: AppDelegate?

autoreleasepool {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    strongAppDelegate = delegate
    app.delegate = delegate

    app.run()
}
