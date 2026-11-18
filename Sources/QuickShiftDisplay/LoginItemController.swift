import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound, unknown

    var isRequested: Bool { self == .enabled || self == .requiresApproval }
    var needsSystemSettings: Bool { self == .requiresApproval }
    var explanation: String {
        switch self {
        case .notRegistered: "登录时不自动启动。"
        case .enabled: "登录时自动启动 QuickShift，并恢复已保存的快捷键开关。"
        case .requiresApproval: "已申请登录时启动，请在系统登录项中允许 QuickShift。"
        case .notFound: "登录项尚未启用，开启后将向 macOS 注册。"
        case .unknown: "无法读取系统登录项状态。"
        }
    }
}

@MainActor
protocol LoginItemServicing {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
struct SystemLoginItemService: LoginItemServicing {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// System registration is authoritative, including changes made in System Settings.
@MainActor
final class LoginItemController {
    private let service: any LoginItemServicing
    private(set) var errorMessage: String?
    var status: LoginItemStatus { service.status }

    init(service: any LoginItemServicing = SystemLoginItemService()) { self.service = service }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        guard enabled != status.isRequested else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch { errorMessage = "无法修改登录项：\(error.localizedDescription)" }
    }

    func openSettings() { service.openSettings() }
}
