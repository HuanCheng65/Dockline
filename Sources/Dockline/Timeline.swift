import Foundation

/// 窗口从出现到进入索引的时间线埋点。
/// 目的只有一个：把「新开 App 的窗口为什么慢」这件事从猜测变成读数。
enum Timeline {
    private static let path = ("~/Library/Logs/Dockline.log" as NSString).expandingTildeInPath
    private static let launched = Date()
    private static let queue = DispatchQueue(label: "dev.starrydream.Dockline.timeline")

    static func start() {
        try? "=== Dockline 启动 \(Date()) ===\n".write(toFile: path, atomically: false, encoding: .utf8)
    }

    static func log(_ message: @autoclosure () -> String) {
        let stamp = String(format: "%8.3fs", Date().timeIntervalSince(launched))
        let line = "\(stamp)  \(message())\n"
        queue.async {
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
}
