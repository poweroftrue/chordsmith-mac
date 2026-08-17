import AppKit
import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case unavailable
    case disabled
    case enabled
    case requiresApproval
    case error(String)

    var isEnabled: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    var needsApproval: Bool {
        self == .requiresApproval
    }

    var description: String {
        switch self {
        case .unavailable:
            return "Install Chordsmith.app to enable launch at login"
        case .disabled:
            return "Does not start automatically"
        case .enabled:
            return "Starts automatically when you log in"
        case .requiresApproval:
            return "Approval required in System Settings › Login Items"
        case .error(let message):
            return "Launch-at-login error: \(message)"
        }
    }
}

@MainActor
final class LaunchAtLoginController {
    private let service: SMAppService
    private let bundle: Bundle

    init(service: SMAppService = .mainApp, bundle: Bundle = .main) {
        self.service = service
        self.bundle = bundle
    }

    var isInstalledApplication: Bool {
        bundle.bundleURL.pathExtension.lowercased() == "app" && bundle.bundleIdentifier != nil
    }

    func currentState() -> LaunchAtLoginState {
        guard isInstalledApplication else { return .unavailable }
        switch service.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .error("Unknown Service Management status")
        }
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtLoginState {
        guard isInstalledApplication else { return .unavailable }
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            return currentState()
        } catch {
            return .error(error.localizedDescription)
        }
    }

    var serviceWasNotFound: Bool {
        isInstalledApplication && service.status == .notFound
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
