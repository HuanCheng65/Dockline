import Foundation

/// 就地授权的接收端（实时状态设计 §4.7）。
///
/// 一次授权就是一条连接：请求从连接进来，答复从同一条连接回去，答完即关。
/// 于是三件事不必另外去做——
///
///   · 请求的**生命周期就是连接的生命周期**。对面被杀（Claude Code 的 hook 超时、
///     用户中断会话），连接断开，这条待授权当场撤下，不需要谁去发一条「作废」。
///   · 答复不会串到别的请求上：它只能从收到它的那条连接回去。
///   · 条没在跑的时候，对面连不上，直接退回 Claude Code 自己那套权限流程。
///
/// 状态上报不走这里，它是单向的、发完就走，分布式通知正合适（见 `ActivityCenter`）。
final class AskServer {
    static let path =
        ("~/Library/Application Support/Dockline/ask.sock" as NSString).expandingTildeInPath

    /// 来了一次授权请求。`id` 用来在之后对上它。
    var onAsk: ((UUID, [String: Any]) -> Void)?
    /// 这次请求没了：对面在拿到答复之前退出了。
    var onGone: ((UUID) -> Void)?

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        /// 请求已经交出去了，正等着用户回答。
        var delivered = false

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    private var listener: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]

    func start() {
        let directory = (Self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // 上次退出留下的那个文件还在，占着这个名字。bind 不会替我们清掉它。
        unlink(Self.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Timeline.log("⚠️ 就地授权不可用：套接字创建失败（errno \(errno)）")
            return
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard Self.path.utf8.count < capacity else {
            Timeline.log("⚠️ 就地授权不可用：套接字路径超过 \(capacity) 字节")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { path in
                _ = strlcpy(path, Self.path, capacity)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, size) == 0
            }
        }
        guard bound, listen(fd, 8) == 0 else {
            Timeline.log("⚠️ 就地授权不可用：\(Self.path) 监听失败（errno \(errno)）")
            close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    /// 回答这次授权。写完即关，对面读到这一行就退出。
    func answer(_ id: UUID, allow: Bool, message: String?) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        var object: [String: Any] = ["allow": allow]
        if let message { object["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            Timeline.log("⚠️ 生成授权答复失败")
            connection.source.cancel()
            return
        }
        var rest = (data + Data([0x0A]))[...]
        while !rest.isEmpty {
            let written = rest.withUnsafeBytes { write(connection.fd, $0.baseAddress, $0.count) }
            guard written > 0 else {
                // 对面已经不在了。它那边的结果与「条没接手」一样：照常弹自己的对话框。
                Timeline.log("⚠️ 授权答复写不出去（errno \(errno)），对面多半已经退出")
                break
            }
            rest = rest.dropFirst(written)
        }
        connection.source.cancel()
    }

    /// 不作决定，直接关掉。对面据此退回 Claude Code 自己那套权限流程。
    func decline(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()
    }

    private func accept(_ listener: Int32) {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // 对面若已经走了，write 默认会给我们一个 SIGPIPE——那会直接带走整条 bar
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let id = UUID()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        connections[id] = Connection(fd: fd, source: source)
        source.setEventHandler { [weak self] in self?.readable(id) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func readable(_ id: UUID) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(connection.fd, &chunk, chunk.count)
        // 0 是对面关了连接，负数是出错——两种都表示这次请求没有下文了
        guard count > 0 else {
            drop(id)
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])
        // 一条连接只承载一次请求，交出去之后余下的字节没有意义；继续读只为等 EOF
        guard !connection.delivered,
              let end = connection.buffer.firstIndex(of: 0x0A) else { return }
        guard let payload = (try? JSONSerialization.jsonObject(with: connection.buffer[..<end]))
                as? [String: Any] else {
            Timeline.log("⚠️ 收到格式不符的授权请求，已交回 Claude Code 自行处理")
            decline(id)
            return
        }
        connection.delivered = true
        onAsk?(id, payload)
    }

    private func drop(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()
        // 还没交出去的连接没人知道它存在，不必通知
        if connection.delivered { onGone?(id) }
    }
}
