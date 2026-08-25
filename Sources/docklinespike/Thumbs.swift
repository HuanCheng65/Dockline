import AppKit
import DocklineCore
import ScreenCaptureKit

// MARK: - thumbs —— 缩略图采集的代价（计划书 §9 / §6 M6 大预览）
//
// 要回答的是「大预览做成实时的，付得起吗」。现在的悬停预览是「停 260ms 抓一张、
// 悬停期间 1.2 秒刷一次」，而大预览要的是实时——频率差两个数量级，不能照搬结论。
//
// 量三件事，缺一件结论就不完整：
//
//   **分项**  每一轮里 `SCShareableContent` 枚举与真正抓图各占多少。现在的实现每抓一张
//             都重新枚举一遍全部窗口；如果开销主要在那儿，实时预览只要把窗口对象缓存住
//             就便宜得多，这一分项直接改变结论。
//   **跟得上吗**  请求 N Hz，实际达成多少。达不成本身就是答案。
//   **代价**  本进程的 CPU 时间，以及**系统整体**的 CPU 时间。后者是必须的：
//             ScreenCaptureKit 的活儿有相当一部分在 WindowServer / replayd 里干，
//             只看自己的进程会把账算少。两段都先跑一段空转基线再减。
//
// 说清楚这个命令**量不到**什么：没有 sudo 就拿不到 `powermetrics`，因此没有真正的
// 瓦特数与 GPU 占用。CPU 时间是能拿到的最诚实的替身，别把它当功耗读。
//
//   docklinespike thumbs --wid n [--hz N] [--seconds S] [--width W] [--reuse]
//
// `--reuse` 把窗口对象缓存住、只重复抓图，用来和默认的「每轮重新枚举」对照。

// MARK: - CPU 取样

/// 本进程用掉的 CPU 秒数（用户态 + 内核态）。
private func processCPU() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// 全系统用掉的 CPU 滴答（不含 idle）。ScreenCaptureKit 的活儿有一部分在别的进程里，
/// 只看自己会把账算少一大截。
private func systemCPUTicks() -> Double {
    var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                      / MemoryLayout<integer_t>.size)
    var info = host_cpu_load_info_data_t()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let busy = info.cpu_ticks.0 + info.cpu_ticks.1 + info.cpu_ticks.3   // user + system + nice
    return Double(busy)
}

/// 一段时间里的 CPU 占用，折算成「几个核」。
private struct Load {
    let process: Double
    let system: Double

    /// **必须包住 await**：把异步的活儿留在外面、只在这里跑一个同步的等待，量到的会是
    /// 一段没有事情发生的时间。第一版就是这么错的——基线里那句 `RunLoop.run` 在协作线程上
    /// 立刻返回，除出来的百分比是一千多。
    static func measure(_ work: () async -> Void) async -> Load {
        let cpu0 = processCPU()
        let sys0 = systemCPUTicks()
        let began = Date()
        await work()
        // 除以一个接近零的数会得出荒唐的百分比，宁可读到 0 也不要读到假的大数
        let elapsed = max(Date().timeIntervalSince(began), 0.001)
        return Load(process: (processCPU() - cpu0) / elapsed,
                    // host 的滴答每核每秒 100 下，除以 100 即「几个核在忙」
                    system: (systemCPUTicks() - sys0) / 100 / elapsed)
    }

    func line(_ name: String) -> String {
        String(format: "  %@  本进程 %.0f%% 一核 · 全系统 %.2f 核", name, process * 100, system)
    }
}

// MARK: - 抓取

private func shareableWindow(_ wid: CGWindowID) async -> SCWindow? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: false) else { return nil }
    return content.windows.first { $0.windowID == wid }
}

/// 抓一张，返回耗时（毫秒）。与 `Preview.swift` 里那段走同一套参数。
/// 失败要把错误交出去——第一版用 `try?` 吞了，于是读到「0 帧」却不知道为什么。
private func grab(_ window: SCWindow, width: CGFloat) async -> (ms: Double?, error: String?) {
    let configuration = SCStreamConfiguration()
    let scale = min(1, width / window.frame.width)
    configuration.width = Int(window.frame.width * scale)
    configuration.height = Int(window.frame.height * scale)
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let began = DispatchTime.now().uptimeNanoseconds
    do {
        _ = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                       configuration: configuration)
        return (Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6, nil)
    } catch {
        return (nil, String(describing: error))
    }
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

// MARK: - 命令

func commandThumbs(wid: CGWindowID, hz: Double, seconds: Double, width: CGFloat, reuse: Bool) {
    let group = DispatchGroup()
    group.enter()
    Task {
        defer { group.leave() }

        // 屏幕的画像。ProMotion 与否、几块屏，都是这次要回答的问题的一部分。
        print("显示器：")
        for screen in NSScreen.screens {
            let mark = NSScreen.screens.count > 1 ? "  " : "  "
            print("\(mark)\(screen.localizedName)  \(Int(screen.frame.width))×"
                  + "\(Int(screen.frame.height))  \(screen.maximumFramesPerSecond)Hz")
        }
        // 抓图与枚举的权限是分开判的：枚举拿得到内容不等于抓得了图，这一行能立刻
        // 分清「命令写错了」和「跑它的那个终端没有屏幕录制权限」。
        print("屏幕录制权限：\(CGPreflightScreenCaptureAccess() ? "有" : "没有")")
        guard let window = await shareableWindow(wid) else {
            FileHandle.standardError.write("thumbs: 找不到窗口 \(wid)\n".data(using: .utf8)!)
            let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            for candidate in (content?.windows ?? []).filter({
                $0.frame.width > 300 && $0.frame.height > 200
            }).prefix(12) {
                print("  \(candidate.windowID)  \(candidate.owningApplication?.applicationName ?? "?")"
                      + "  \(Int(candidate.frame.width))×\(Int(candidate.frame.height))"
                      + "  \(candidate.title ?? "")")
            }
            exit(1)
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let host = NSScreen.screens.first { flipY($0.frame).contains(center) }
        print("目标 wid \(wid)  \(window.owningApplication?.applicationName ?? "?")"
              + "  \(Int(window.frame.width))×\(Int(window.frame.height))"
              + "  在 \(host?.localizedName ?? "判不出")"
              + "（\(host?.maximumFramesPerSecond ?? 0)Hz）")
        print("请求 \(Int(hz))Hz × \(Int(seconds))s，输出宽 \(Int(width))px，"
              + "\(reuse ? "复用窗口对象" : "每轮重新枚举")\n")

        // 空转基线。减掉它才是采集自己的账。
        let idle = await Load.measure {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        }
        print(idle.line("空转基线"))

        var enumerate: [Double] = []
        var capture: [Double] = []
        var failure: String?
        let interval = 1 / hz
        let deadline = Date().addingTimeInterval(seconds)
        let busy = await Load.measure {
            var target = window
            while Date() < deadline {
                let round = Date()
                if !reuse {
                    let began = DispatchTime.now().uptimeNanoseconds
                    guard let fresh = await shareableWindow(wid) else { break }
                    enumerate.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6)
                    target = fresh
                }
                let shot = await grab(target, width: width)
                if let ms = shot.ms { capture.append(ms) } else { failure = shot.error }
                // 跟不上就不补睡——「实际达成多少帧」正是要读的数之一
                let rest = interval - Date().timeIntervalSince(round)
                if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1e9)) }
            }
        }
        print(busy.line("采集中  "))
        print(String(format: "  净增    本进程 %.0f%% 一核 · 全系统 %.2f 核",
                     (busy.process - idle.process) * 100, busy.system - idle.system))
        print("")
        if let failure {
            print("⚠️ 有抓图失败：\(failure)")
        }
        print(String(format: "实际 %.1f Hz（请求 %.0f）  %d 帧 / %.0fs",
                     Double(capture.count) / seconds, hz, capture.count, seconds))
        if !enumerate.isEmpty {
            print(String(format: "  枚举  中位 %.1fms  P95 %.1fms",
                         percentile(enumerate, 0.5), percentile(enumerate, 0.95)))
        }
        if !capture.isEmpty {
            print(String(format: "  抓图  中位 %.1fms  P95 %.1fms",
                         percentile(capture, 0.5), percentile(capture, 0.95)))
        }
        let perFrame = percentile(enumerate, 0.5) + percentile(capture, 0.5)
        if perFrame > 0 {
            print(String(format: "  一轮合计中位 %.1fms —— 单线程的上限约 %.0f Hz",
                         perFrame, 1000 / perFrame))
        }
    }
    while group.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
