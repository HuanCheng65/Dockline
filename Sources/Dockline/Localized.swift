import Foundation

/// 界面文案的唯一入口。
///
/// **凡是会显示给用户的文字都从这里取**，不在源码里硬编码。资源是
/// `Sources/Dockline/Resources/<语言>.lproj/Localizable.strings`，由 `Scripts/build-app.sh`
/// 拷进 bundle 的 `Contents/Resources`，因此查的是主 bundle 而不是 `Bundle.module`。
///
/// 键缺失时的行为是刻意的：给了 `fallback` 就显示它，没给就**显示键名本身**。
/// 界面上冒出一个 `activity.waiting.permission` 很难看，但那正是要的——
/// 少一条文案是个错误，应当当场看见，而不是悄悄显示成空白。
func localized(_ key: String, fallback: String? = nil) -> String {
    Bundle.main.localizedString(forKey: key, value: fallback ?? key, table: nil)
}

/// 带参数的文案。格式串本身也是资源，参数次序交给译者，不在代码里假定。
func localized(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), arguments: arguments)
}
