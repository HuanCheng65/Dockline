import Foundation

// MARK: - 歧义驱动的区分性标签
//
// 计划书 §1 痛点第二名：同 App 多窗口无法定位。窗口标题里真正有区分力的部分，
// 通常被淹没在各 App 自己的固定后缀（项目名、App 名）或固定前缀里。
//
// 做法是把标题按分隔符切成段，剥掉「组内所有标题都相同」的首尾段——那些段按定义
// 没有区分力——剩下的第一段就是这个窗口独有的东西。
//
// 只在同 App ≥2 窗口时调用：单窗口没有歧义，也就不需要标签。

/// 分隔符。连字符族（- – — | :）必须两侧带空白才算数——裸的 `-` 会把
/// 「co-founder deck」切成「co」，裸的 `:` 会切时间戳。`·`「•」「：」是中文排版里
/// 天然的分隔符，不带空格也作数。
private let separatorPattern = try! NSRegularExpression(pattern: "\\s+[-\u{2013}\u{2014}|:]\\s+|[\u{00B7}\u{2022}\u{FF1A}]")

private func segments(of title: String) -> [String] {
    let full = NSRange(title.startIndex..., in: title)
    var result: [String] = []
    var cursor = title.startIndex
    for match in separatorPattern.matches(in: title, range: full) {
        guard let range = Range(match.range, in: title) else { continue }
        result.append(String(title[cursor..<range.lowerBound]))
        cursor = range.upperBound
    }
    result.append(String(title[cursor...]))
    return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// 输入同一 App 下若干窗口的标题，按输入顺序返回等长的标签数组。
///
/// 剥离后仍然重复的标签会退回完整标题：标签的唯一职责就是区分，
/// 区分不了的时候宁可长一点，也不能给出两个一样的。
public func distinctiveLabels(for titles: [String]) -> [String] {
    guard titles.count > 1 else { return titles }

    var parts = titles.map(segments(of:))
    // 有标题切不出任何段（纯分隔符或空标题）时，剥离会把它误伤成空，直接放弃剥离。
    guard parts.allSatisfy({ !$0.isEmpty }) else { return titles }

    // 剥尾：App 名、项目名一类固定后缀。留一段兜底，不能把标题剥空。
    while parts.allSatisfy({ $0.count > 1 }),
          let tail = parts.first?.last, parts.allSatisfy({ $0.last == tail }) {
        for i in parts.indices { parts[i].removeLast() }
    }
    // 剥首：固定前缀，如同一年份、同一账号名。
    while parts.allSatisfy({ $0.count > 1 }),
          let head = parts.first?.first, parts.allSatisfy({ $0.first == head }) {
        for i in parts.indices { parts[i].removeFirst() }
    }

    var labels = parts.map { $0[0] }
    // 剥完仍撞车的，那几个退回完整标题
    var counts: [String: Int] = [:]
    for label in labels { counts[label, default: 0] += 1 }
    for i in labels.indices where counts[labels[i]]! > 1 { labels[i] = titles[i] }
    return labels
}
