import AppKit

// LSUIElement 已在 Info.plist 里声明；这里再设一次，保证从 .build 直接跑裸二进制时也不出现 Dock 图标。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
