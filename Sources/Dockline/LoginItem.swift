import ServiceManagement

/// 登录时启动。
///
/// 一个用来取代程序坞的东西，如果每天开机都要手动打开一次，它就不成立。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 抛出的错误由调用点报给用户。用户可能在「登录项」里手动禁用过，
    /// 那种情况下注册会失败，必须让用户知道去哪儿改。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
