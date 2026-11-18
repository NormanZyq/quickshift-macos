import Foundation
import Testing
@testable import QuickShiftDisplay

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status = LoginItemStatus.notRegistered
    var registrationResult = LoginItemStatus.enabled
    var registrationError: Error?
    var unregistrationError: Error?
    var registrations = 0
    var unregistrations = 0
    var settingsOpened = 0
    func register() throws {
        registrations += 1
        if let registrationError { throw registrationError }
        status = registrationResult
    }
    func unregister() throws {
        unregistrations += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
    func openSettings() { settingsOpened += 1 }
}

@Test @MainActor func loginItemCanBeEnabledDisabledAndReflectExternalChanges() {
    let service = FakeLoginItemService()
    let controller = LoginItemController(service: service)
    #expect(!controller.status.isRequested)
    controller.setEnabled(true)
    controller.setEnabled(true)
    #expect(service.registrations == 1)
    #expect(controller.status == .enabled)
    controller.setEnabled(false)
    controller.setEnabled(false)
    #expect(service.unregistrations == 1)
    #expect(controller.status == .notRegistered)
    service.status = .enabled
    #expect(controller.status.isRequested)
    service.status = .notRegistered
    #expect(!controller.status.isRequested)
}

@Test @MainActor func loginItemFailuresKeepTheActualSystemState() {
    let service = FakeLoginItemService()
    let controller = LoginItemController(service: service)
    let failure = NSError(domain: "QuickShiftTests", code: 1)
    service.registrationError = failure
    controller.setEnabled(true)
    #expect(!controller.status.isRequested)
    #expect(controller.errorMessage != nil)
    service.registrationError = nil
    controller.setEnabled(true)
    #expect(controller.status.isRequested)
    #expect(controller.errorMessage == nil)
    service.unregistrationError = failure
    controller.setEnabled(false)
    #expect(controller.status.isRequested)
    #expect(controller.errorMessage != nil)
}

@Test @MainActor func loginItemPendingApprovalCanOpenSettingsOrBeCancelled() {
    let service = FakeLoginItemService()
    service.registrationResult = .requiresApproval
    let controller = LoginItemController(service: service)
    controller.setEnabled(true)
    #expect(controller.status.isRequested)
    #expect(controller.status.needsSystemSettings)
    controller.openSettings()
    #expect(service.settingsOpened == 1)
    controller.setEnabled(false)
    #expect(controller.status == .notRegistered)
    #expect(service.unregistrations == 1)
}
