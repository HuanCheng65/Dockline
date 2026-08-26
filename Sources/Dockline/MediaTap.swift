import Accelerate
import CoreAudio
import Foundation
import QuartzCore

/// 均衡器那三根柱子此刻的高度。
///
/// **写在音频线程，读在渲染线程，中间只隔一把锁。** 不走 `@Observable`：分析每秒出九十多
/// 帧，每一帧都推一次观察通知，等于把主线程当成音频线程用。视图按显示刷新率自己来取。
///
/// **落是读的时候算的，不是写的时候算的。** 存下来的是「某一刻的包络值 + 那一刻是什么
/// 时候」，读的时候按经过的时间往下推——与播放进度同一个手法。这样两次分析之间的每一
/// 个显示帧都有自己的值，柱子的回落是连续的，而不是九十多个台阶。
final class MediaLevels {
    private let lock = NSLock()
    private var punch = [0.0, 0.0, 0.0]
    private var punchStamp = [0.0, 0.0, 0.0]
    private var body = [0.0, 0.0, 0.0]
    private var bodyStamp = [0.0, 0.0, 0.0]
    private var alive = false

    /// 每段音头包络的回落时间常数，单位秒。
    ///
    /// 三段各不相同，这是它看起来自然的一半原因：声音本身就是这样，底鼓的能量拖一百多
    /// 毫秒才散，镲几十毫秒就没了。三根用同一个常数，它们就永远一起起一起落。
    static let release = [0.13, 0.09, 0.07]
    /// **峰值保持**：抬升之后先钉住这么久，再开始回落。低段的音头本身长，保持也长一档。
    ///
    /// 没有它，峰顶会抽搐：一次音头持续两到四个分析帧，`flux` 在峰附近晃（0.75 → 0.68 →
    /// 0.74），而 τ = 0.13 秒在 94fps 的帧间只掉 8%，于是包络「落一点 → 被重触发 → 再落
    /// 一点」，形成一个四十多赫兹的微颤。保持期内低于峰值的晃动一律不可见，只有真更高的
    /// 值才动它——峰先钉住，然后干脆地落下。这是电平表的经典弹道。
    static let hold = [0.06, 0.05, 0.04]
    /// 电平层（`body`）的回落。它是背景，落得比音头慢一档。
    static let bodyRelease = 0.30
    /// 电平层能占的最大高度。它只负责在 pad、弦乐这种没有音头的段落里让柱子还有呼吸，
    /// 主角是音头。
    static let bodyShare = 0.35

    /// 音频线程调用。`flux` 与 `level` 都已经映射到 0…1。
    ///
    /// **存的是「抬升那一刻的值 + 那一刻是什么时候」，回落全部在读侧按时间算。** 时间戳
    /// 因此是每段各一份而不是全局一份——与播放进度同一个手法，两次分析之间的每个显示帧
    /// 都有自己的值。
    func receive(flux: [Double], level: [Double], at now: Double) {
        lock.lock()
        for index in 0..<3 {
            // 只在新值高过**此刻的**包络时才抬；抬了就重置时钟，保持期从头开始
            if flux[index] >= current(punch[index], punchStamp[index], now,
                                      Self.release[index], Self.hold[index]) {
                punch[index] = flux[index]
                punchStamp[index] = now
            }
            if level[index] >= current(body[index], bodyStamp[index], now,
                                       Self.bodyRelease, 0) {
                body[index] = level[index]
                bodyStamp[index] = now
            }
        }
        alive = true
        lock.unlock()
    }

    func silence() {
        lock.lock()
        punch = [0, 0, 0]
        body = [0, 0, 0]
        alive = false
        lock.unlock()
    }

    /// 渲染线程调用：此刻三根柱子各有多高（0…1）。`nil` 表示没有电平可用。
    func bars(at now: Double) -> [CGFloat]? {
        lock.lock()
        defer { lock.unlock() }
        guard alive else { return nil }
        return (0..<3).map { index in
            let attack = current(punch[index], punchStamp[index], now,
                                 Self.release[index], Self.hold[index])
            let ground = current(body[index], bodyStamp[index], now,
                                 Self.bodyRelease, 0) * Self.bodyShare
            return CGFloat(max(attack, ground))
        }
    }

    private func current(_ value: Double, _ since: Double, _ now: Double,
                         _ tau: Double, _ hold: Double) -> Double {
        let elapsed = now - since - hold
        return elapsed <= 0 ? value : value * exp(-elapsed / tau)
    }
}

/// 从正在发声的那个进程上取电平。
///
/// **为什么这条路成立**（实测记录见设计文档 §5.4）：`AudioHardwareCreateProcessTap` 是
/// CoreAudio 的公开 API（头文件标 `API_AVAILABLE(macos(14.2))`），按**音频进程对象**挂，
/// 而不是按 Unix 进程。这一点正好解掉浏览器那个坎：Chrome、Arc 出声的是它们的 helper，
/// 而 helper 以自己的 bundle ID 出现在 `kAudioHardwarePropertyProcessObjectList` 里
/// （实测 `company.thebrowser.browser.helper`），按前缀一匹配就找到了。
final class MediaTap {
    private let levels: MediaLevels
    /// 三段的频率边界。低段是底鼓与贝斯，中段是人声与主奏，高段是镲与齿音。
    static let bands: [(Double, Double)] = [(30, 250), (250, 2000), (2000, 12000)]
    /// 电平层每段的固定补偿与量程，单位分贝。实测三段的每格平均功率分别落在
    /// −5…35、9…31、8…29，各自抬进同一段窗口。
    static let tilt: [Double] = [0, 6, 8]
    static let range = (-10.0, 55.0)
    /// 音头判定：`fluxSmooth` 超过自己的慢均值多少倍才算一次音头。
    ///
    /// **跟踪的是均值，不是极值——这是它与前两版自适应的分界。** 那两版把量程的上端定义成
    /// 自己最近的输出，状态一累积就自指，失效方式只有「死」和「爆表」两种。均值由输入主导、
    /// 自然收敛；比值又让它只回答「此刻比平常高多少倍」，没有那个回路。
    ///
    /// 比值这一层还顺带免掉了标定：对数差分已经免疫音量，除以基线再免疫曲风，
    /// 渐近饱和免疫削顶。三个数都是无量纲的形状参数，看着柱子调就行。
    /// **按段给。** 实测三段的比值动态差得很远：低段九五分位 1.86、顶 2.8，中段 1.50，
    /// 高段只有 1.25。一刀切成 1.25 的话正好切在高段的九五分位上，那根柱子会几乎全程为零。
    /// 这正是「密集的内容会抬高自己的基线」那个特性走到极端——高频本来就密，音头一个接
    /// 一个，慢均值被顶得高，相对新颖度就被压扁了。
    static let fluxK: [Double] = [1.25, 1.15, 1.08]
    /// 饱和曲线的膝点。管的是中等力度的音头显示多高。
    ///
    /// **膝点要配 novelty 的现实范围，而且要逐段配。** 先前取 1.0，那是给 novelty 能到
    /// 5–10 的信号用的；20 毫秒预平滑之后真实音乐的峰均比只有 2–3，novelty 的现实范围是
    /// 0–2，配 1.0 的话柱子的天花板就只有 0.4 上下。
    ///
    /// 三段共用一个膝点同样不行：实测低段的 novelty 顶到 1.55，高段的九五分位只有 0.17，
    /// **差了近十倍**。共用 0.35 的话低段过曲线得 0.82、高段只有 0.33，中高两根就被压在
    /// 电平层附近，看起来像「只有低段在动」。取法是让每段实测的顶级 novelty 映射到 0.8
    /// 上下，也就是 `膝点 ≈ 顶级 novelty / 4`。
    static let fluxKnee: [Double] = [0.35, 0.2, 0.12]
    /// 慢均值的保持系数，τ 约 1.5 秒。
    static let meanKeep = 0.993
    /// 慢均值往上走时步长打的折。
    ///
    /// **不对称是必须的**：对称更新的话音头自己会把均值抬上去，而比值该除的是**非音头
    /// 的基线**。打折之后均值贴着基线走，顺带还免掉两件事——开播的巨型瞬态和暂停恢复时的
    /// 整谱跳变都拖不动它了，密集踩镲抬高自身基线那个特性也缓解了一半。
    static let meanRise = 0.3
    /// 音头的预平滑，τ 约 20 毫秒。阈值判断作用在干净信号上，起音只慢十毫秒左右，
    /// 视觉上仍是瞬跳。
    static let smoothKeep = 0.59
    /// 参与差分的最低格电平。低于此一律当噪底——不钳的话，接近噪底时对数会剧烈抖动，
    /// 安静反而让柱子狂跳。
    static let binFloor = -35.0
    /// 整帧的绝对静音门，真正的 dBFS（时域求的，与 FFT 的定标无关）。
    static let silence = -55.0

    private var bundleID: String?
    private var followed: [AudioObjectID] = []
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listening = false
    private let meter = Meter()

    init(levels: MediaLevels) {
        self.levels = levels
    }

    /// 跟住这个 App。`nil` 表示此刻没有播放源。
    func follow(_ bundleID: String?) {
        self.bundleID = bundleID
        rebuild()
    }

    func stop() {
        bundleID = nil
        rebuild()
        if listening { removeListener(); listening = false }
    }

    // MARK: - 挂与拆

    private func rebuild() {
        installListener()
        let wanted = matching(bundleID)
        Timeline.log("电平  跟随 \(bundleID ?? "—")，命中 \(wanted.count) 个音频进程")
        guard wanted != followed else { return }
        teardown()
        followed = wanted
        guard !wanted.isEmpty else {
            levels.silence()
            return
        }
        guard build(for: wanted) else {
            followed = []
            levels.silence()
            return
        }
    }

    private func build(for processes: [AudioObjectID]) -> Bool {
        let description = CATapDescription(monoMixdownOfProcesses: processes)
        description.name = "Dockline"
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr,
              tap != AudioObjectID(kAudioObjectUnknown) else {
            Timeline.log("⚠️ 均衡器取不到电平：建不起 tap，退回相位动画")
            tap = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        let rate = format(tap)?.mSampleRate ?? 48000
        meter.configure(sampleRate: rate)

        let recipe: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dockline Levels",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // 私有：不进系统的设备列表，也不会被别的 App 选中
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // 挂上默认输出当时钟源。空的子设备列表也能把设备建起来，但那台设备不走 IO
            // ——实测：一次回调都不来。
            kAudioAggregateDeviceSubDeviceListKey: defaultOutputUID()
                .map { [[kAudioSubDeviceUIDKey: $0]] } ?? [],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(recipe as CFDictionary, &device) == noErr else {
            Timeline.log("⚠️ 均衡器取不到电平：建不起聚合设备，退回相位动画")
            device = AudioObjectID(kAudioObjectUnknown)
            teardown()
            return false
        }

        let meter = self.meter
        let levels = self.levels
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) {
            _, input, _, _, _ in
            // 分析与包络全在音频线程上算完，只把结果写进一个上了锁的小结构。
            // 不往主线程投递：分析每秒出九十多帧，逐帧投递等于把主线程当音频线程用。
            guard let result = meter.consume(input) else { return }
            levels.receive(flux: result.flux, level: result.level, at: CACurrentMediaTime())
        }
        guard status == noErr, let procID, AudioDeviceStart(device, procID) == noErr else {
            Timeline.log("⚠️ 均衡器取不到电平：IOProc 起不来，退回相位动画")
            teardown()
            return false
        }
        Timeline.log("电平  挂上 \(processes.count) 个音频进程，\(rate)Hz")
        return true
    }

    private func teardown() {
        if let procID, device != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
        if device != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(device)
            device = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
        meter.reset()
    }

    // MARK: - 找进程

    /// 匹配这个 App 的所有音频进程对象。
    ///
    /// **不按「此刻在不在出声」筛。** 那个标志会翻，而对象列表不会——按它筛的话，扫描时
    /// 刚好停着的播放器就永远挂不上。挂一个不出声的进程无非收到一串零。
    private func matching(_ bundleID: String?) -> [AudioObjectID] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        let wanted = bundleID.lowercased()
        return processObjects().filter {
            guard let id = string($0, kAudioProcessPropertyBundleID)?.lowercased() else {
                return false
            }
            // 前缀：浏览器的 helper 是「主 bundle ID + .helper」这一类
            return id == wanted || id.hasPrefix(wanted + ".")
        }
    }

    private func processObjects() -> [AudioObjectID] {
        var address = Self.listAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static let listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// 进程列表变了就重挂。**这是必须的**：播放器起播的那一刻才会出现在这张表里，
    /// 而浏览器换一个标签页出声可能换一个 helper。
    private func installListener() {
        guard !listening else { return }
        listening = true
        var address = Self.listAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                self?.rebuild()
            }
    }

    private func removeListener() {
        var address = Self.listAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in }
    }

    // MARK: - 读属性

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
        -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value as String?
    }

    private func format(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var output = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &output) == noErr else { return nil }
        return string(output, kAudioDevicePropertyDeviceUID)
    }

    /// 分析：分频、电平、音头。只在音频线程上碰。
    ///
    /// **按 hop 驱动，不按墙钟。** 先前是每 1/30 秒去环形缓冲取「最新 2048 点」，相邻两次
    /// 分析的实际重叠量是抖的。电平对此不敏感，而音头是**相邻帧的差分**，重叠一抖就直接
    /// 变成音头噪声。现在每攒够 `hop` 个样本分析一次，间隔严格均匀。
    ///
    /// 窗长也从 2048 缩到 1024：48kHz 下是 21 毫秒，比底鼓的起振短，瞬态不再被时间糊掉。
    private final class Meter: @unchecked Sendable {
        private static let size = 1024
        private static let half = size / 2
        private static let hop = 512

        private var fft: vDSP.FFT<DSPSplitComplex>?
        private var window = [Float](repeating: 0, count: Meter.size)
        private var ring = [Float](repeating: 0, count: Meter.size)
        private var head = 0
        private var pending = 0
        private var edges: [(Int, Int)] = []
        private var previous = [Double](repeating: MediaTap.binFloor, count: Meter.half)
        private var primed = false
        private var fluxSmooth = [0.0, 0.0, 0.0]
        private var slowMean = [0.0, 0.0, 0.0]
        /// 冷启动计帧。0.25 秒足够跨过开播瞬态、让慢均值滑到真实基线附近。
        private static let warmFrames = 24
        private var warm = [0, 0, 0]

        private var frame = [Float](repeating: 0, count: Meter.size)
        private var real = [Float](repeating: 0, count: Meter.half)
        private var imaginary = [Float](repeating: 0, count: Meter.half)
        private var outputReal = [Float](repeating: 0, count: Meter.half)
        private var outputImaginary = [Float](repeating: 0, count: Meter.half)
        private var power = [Float](repeating: 0, count: Meter.half)

        func configure(sampleRate: Double) {
            fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                 count: Meter.size, isHalfWindow: false)
            // 逐段接力，不各算各的：各算各的话相邻两段会共用边界那一格，
            // 而差分是有副作用的——低段先把 `previous[边界格]` 消费掉，
            // 中段再算同一格时差分恒为零。
            var start = 1
            edges = MediaTap.bands.map { _, high in
                let top = min(Meter.half - 1,
                              max(start, Int(high * Double(Meter.size) / sampleRate)))
                let range = (start, top)
                start = top + 1
                return range
            }
            reset()
        }

        func reset() {
            ring = [Float](repeating: 0, count: Meter.size)
            head = 0
            pending = 0
            previous = [Double](repeating: MediaTap.binFloor, count: Meter.half)
            primed = false
            fluxSmooth = [0, 0, 0]
            slowMean = [0, 0, 0]
            warm = [0, 0, 0]
        }

        /// 吃掉这一批样本，攒够一跳就分析一次。返回这一批里产生的最后一帧结果。
        func consume(_ list: UnsafePointer<AudioBufferList>) -> (flux: [Double], level: [Double])? {
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            var result: (flux: [Double], level: [Double])?
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for index in 0..<frames {
                    ring[head] = samples[index]
                    head = (head + 1) % Meter.size
                    pending += 1
                    if pending >= Meter.hop {
                        pending = 0
                        if let analysed = analyse() { result = analysed }
                    }
                }
            }
            return result
        }

        private func analyse() -> (flux: [Double], level: [Double])? {
            guard let fft, !edges.isEmpty else { return nil }
            // 环形缓冲展平：head 是下一个要写的位置，也就是最老的那个样本
            for index in 0..<Meter.size { frame[index] = ring[(head + index) % Meter.size] }

            // 绝对静音门走时域均方根。它是真正的 dBFS，与 FFT 怎么定标无关。
            var mean: Float = 0
            vDSP_measqv(frame, 1, &mean, vDSP_Length(Meter.size))
            let loudness = 10 * log10(max(Double(mean), 1e-12))

            vDSP.multiply(frame, window, result: &frame)
            frame.withUnsafeBytes { raw in
                let interleaved = raw.bindMemory(to: DSPComplex.self)
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                        var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                                    imagp: imaginaryBuffer.baseAddress!)
                        vDSP_ctoz(interleaved.baseAddress!, 2, &split, 1, vDSP_Length(Meter.half))
                    }
                }
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    outputReal.withUnsafeMutableBufferPointer { outRealBuffer in
                        outputImaginary.withUnsafeMutableBufferPointer { outImaginaryBuffer in
                            let input = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                                        imagp: imaginaryBuffer.baseAddress!)
                            var output = DSPSplitComplex(realp: outRealBuffer.baseAddress!,
                                                         imagp: outImaginaryBuffer.baseAddress!)
                            fft.forward(input: input, output: &output)
                            vDSP.squareMagnitudes(output, result: &power)
                        }
                    }
                }
            }

            var flux = [0.0, 0.0, 0.0]
            var level = [0.0, 0.0, 0.0]
            let quiet = loudness < MediaTap.silence
            for band in 0..<3 {
                let (low, high) = edges[band]
                var sum = 0.0
                var rise = 0.0
                for bin in low...high {
                    let decibels = max(MediaTap.binFloor,
                                       10 * log10(max(Double(power[bin]), 1e-12)))
                    sum += Double(power[bin])
                    // 半波整流的谱通量：只数变响的那部分。持续的长音帧间差分接近零，
                    // 于是它天然被忽略——低段里那些盖住底鼓的贝斯长音不必另想办法拆。
                    rise += max(0, decibels - previous[bin])
                    previous[bin] = decibels
                }
                let bins = Double(high - low + 1)
                // 静音期把基线冻住：继续更新的话，暂停几秒后慢均值衰到零，
                // 恢复播放头几帧的比值就是天文数字。
                guard primed, !quiet else { continue }
                // 取每格的平均，不取整段之和：段宽差着几十倍，取和等于给宽的那一段
                // 白送一个跟带宽成正比的增益。
                let (floor, ceiling) = MediaTap.range
                let decibels = 10 * log10(max(sum / bins, 1e-12)) + MediaTap.tilt[band]
                level[band] = min(1, max(0, (decibels - floor) / (ceiling - floor)))
                let rate = rise / bins
                // 预平滑：阈值判断要作用在干净信号上，不然一半的抖动来自单帧噪声
                fluxSmooth[band] = fluxSmooth[band] * MediaTap.smoothKeep
                    + rate * (1 - MediaTap.smoothKeep)
                // 冷启动：快速双向跟踪，同时把输出压死。
                //
                // 先前是头三帧（32 毫秒）直接把当时的 `fluxSmooth` 赋给慢均值——那时它才
                // 刚从零爬起来，远低于真实基线，于是第一个鼓点的比值虚高、打出一次大跳，
                // 随后均值收敛上去又把一切压回去。「开播跳一下然后趴下」就是这条时间线。
                guard warm[band] >= Meter.warmFrames else {
                    warm[band] += 1
                    slowMean[band] = slowMean[band] * 0.85 + fluxSmooth[band] * 0.15
                    continue
                }
                let step = (1 - MediaTap.meanKeep)
                    * (fluxSmooth[band] > slowMean[band] ? MediaTap.meanRise : 1)
                slowMean[band] += step * (fluxSmooth[band] - slowMean[band])
                let ratio = fluxSmooth[band] / max(slowMean[band], 1e-6)
                let novelty = max(0, ratio - MediaTap.fluxK[band])
                flux[band] = novelty / (novelty + MediaTap.fluxKnee[band])
            }
            primed = true
            return (flux, level)
        }
    }
}
