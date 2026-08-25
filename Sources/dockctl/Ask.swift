import Foundation

/// 就地授权的请求端（实时状态设计 §4.7）。
///
/// 状态上报是单向的、发完就走，用分布式通知正合适；授权是**一问一答**，形状不同。
/// 这里改用 Unix 域套接字，一次授权就是一次连接——这一条选择同时解决了另外三件事：
///
///   · 连不上 = 条没在跑。不必另外去查进程。
///   · 读到 EOF = 条中途退出了。不必盯着它的进程。
///   · 这个进程被杀（Claude Code 的 hook 超时、用户中断），连接随之断开，
///     条那边据此撤掉这条待授权。两端都不需要发「我走了」。
///
/// 答复走同一条连接，所以「回答串到另一次请求上去」在结构上就不可能发生。
enum Ask {
    static let socketPath =
        ("~/Library/Application Support/Dockline/ask.sock" as NSString).expandingTildeInPath

    struct Answer {
        let allow: Bool
        /// 拒绝的理由。由条那边给——界面文案统一走条的本地化资源。
        let message: String?
    }

    /// 把这次授权请求交给条，阻塞等它回话。
    ///
    /// **返回 nil 表示条没有接手这次授权**（没在跑、连不上、没等到答复就断了）。
    /// 调用方此时什么都不打印，Claude Code 照常走它自己那套权限流程——
    /// 这条路上的任何失败都退化成现状，不会静默地放行或拦下什么。
    static func request(_ payload: [String: Any]) -> Answer? {
        guard let line = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        guard send(fd, line + Data([0x0A])) else { return nil }
        guard let reply = readLine(fd),
              let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let allow = object["allow"] as? Bool
        else { return nil }
        return Answer(allow: allow, message: object["message"] as? String)
    }

    private static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { path in
                _ = strlcpy(path, socketPath, capacity)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, size) == 0
            }
        }
        guard ok else {
            close(fd)
            return nil
        }
        // 写的时候对端可能已经没了。默认那会给这个进程一个 SIGPIPE 直接把它带走，
        // 而 hook 进程被信号带走与「不作决定」在 Claude Code 那边是同一个结果，
        // 只是这样连日志都留不下。改成让 write 返回错误。
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func send(_ fd: Int32, _ data: Data) -> Bool {
        var rest = data[...]
        while !rest.isEmpty {
            let written = rest.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { return false }
            rest = rest.dropFirst(written)
        }
        return true
    }

    /// 读到换行为止。**不设超时**：这里等的是用户，而「用户多久算不管了」不是我们能定的。
    /// 外面那道界限由 Claude Code 自己的 hook 超时给出，超时的后果是它照常弹自己的对话框。
    private static func readLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            if let end = buffer.firstIndex(of: 0x0A) { return buffer[..<end] }
        }
    }
}
