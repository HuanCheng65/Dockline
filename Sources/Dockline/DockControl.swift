import AppKit

/// 接管系统程序坞。
///
/// Dockline 浮在屏幕底部，系统程序坞若还会在鼠标触底时滑出，两者会互相打断。
/// 系统没有「彻底关闭程序坞」的开关，能做到的是把它的唤出延迟设到极大，
/// 并关掉图标弹跳——弹跳会让已隐藏的程序坞自己滑出来。
///
/// **另外把它挪到屏幕左侧。** 唤出延迟只管桌面场景：原生全屏 Space 里的唤出走的是
/// 窗口服务器自己那套「贴边显示系统部件」的机制（与全屏下的菜单栏同源），在 tap 之前
/// 就算完了——实测过改写坐标与整条丢弃两种拦截，程序坞照样滑出来，客户端没有入口。
/// 唤不掉就只能让它别唤在我们头上：挪到左边之后，它的全屏唤出跟着换到左边缘，
/// 底部就只剩 Dockline 一条。
///
/// 四个键都会先记下原值再改写，「恢复」按原值还原（原本没有的键则删除）。
enum DockControl {
    private static let domain = "com.apple.dock" as CFString
    private static let autohide = "autohide" as CFString
    private static let delay = "autohide-delay" as CFString
    private static let noBouncing = "no-bouncing" as CFString
    private static let orientation = "orientation" as CFString
    private static let sideOrientation = "left"
    /// 秒。这么大等于永不因悬停而唤出。取普通整数而非极端值，程序坞对偏好里的
    /// 极端浮点解析并不稳定。
    private static let suppressedDelay = 999.0

    struct Snapshot: Codable {
        var autohide: Bool?
        var delay: Double?
        var noBouncing: Bool?
        var orientation: String?
    }

    private static func read(_ key: CFString) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain)
    }

    private static func write(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFTypeRef?, domain)
    }

    static var isSuppressed: Bool {
        (read(delay) as? NSNumber)?.doubleValue ?? 0 >= suppressedDelay
    }

    static var isAutoHidden: Bool {
        (read(autohide) as? NSNumber)?.boolValue ?? false
    }

    /// 返回改动前的原值，调用方负责保存，供日后恢复。
    static func suppress() -> Snapshot {
        let snapshot = Snapshot(autohide: (read(autohide) as? NSNumber)?.boolValue,
                                delay: (read(delay) as? NSNumber)?.doubleValue,
                                noBouncing: (read(noBouncing) as? NSNumber)?.boolValue,
                                orientation: read(orientation) as? String)
        write(autohide, true)
        write(delay, suppressedDelay)
        write(noBouncing, true)
        write(orientation, sideOrientation)
        CFPreferencesAppSynchronize(domain)
        restartDock()
        return snapshot
    }

    static func restore(_ snapshot: Snapshot?) {
        write(autohide, snapshot?.autohide)
        write(delay, snapshot?.delay)
        write(noBouncing, snapshot?.noBouncing)
        write(orientation, snapshot?.orientation)
        CFPreferencesAppSynchronize(domain)
        restartDock()
    }

    /// 偏好改动要重启程序坞才生效。
    private static func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }

    /// 用户若直接删掉 Dockline，这些设置不会自己还原。设置界面里原样展示这条命令。
    static let manualRestoreCommand =
        "defaults delete com.apple.dock autohide-delay; "
        + "defaults delete com.apple.dock no-bouncing; "
        + "defaults delete com.apple.dock orientation; killall Dock"
}
