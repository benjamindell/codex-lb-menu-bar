import Foundation
import CoreGraphics

@main
enum StatusBarLogicTests {
    static func main() {
        if CommandLine.arguments.count == 4 {
            runKeychainPersistenceProbe(
                mode: CommandLine.arguments[1],
                service: CommandLine.arguments[2],
                serverURL: CommandLine.arguments[3]
            )
            return
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        assert(relativeReset(now.addingTimeInterval(2 * 86_400 + 3 * 3_600), now: now) == "Reset in 2d 3h")
        assert(relativeReset(now.addingTimeInterval(45 * 60), now: now) == "Reset in 45m")
        assert(relativeReset(now.addingTimeInterval(-1), now: now) == "Reset now")
        assert(warmupLabel(enabled: true, attemptCount: 1) == "Warm-up on (1 attempt)")
        assert(warmupLabel(enabled: true, attemptCount: 3) == "Warm-up on (3 attempts)")
        assert(warmupLabel(enabled: false, attemptCount: 3) == "Warm-up off")
        assert(quotaTone(for: 70) == .healthy)
        assert(quotaTone(for: 30) == .watch)
        assert(quotaTone(for: 29.9) == .critical)
        assert(menuBarTitle(primary: 82.4, secondary: 55) == "82%")
        assert(authenticationRecoveryAction(
            authenticated: true,
            passwordRequired: true,
            hasStoredPassword: true,
            automaticRetryAllowed: true
        ) == .none)
        assert(authenticationRecoveryAction(
            authenticated: false,
            passwordRequired: true,
            hasStoredPassword: true,
            automaticRetryAllowed: true
        ) == .useStoredPassword)
        assert(authenticationRecoveryAction(
            authenticated: false,
            passwordRequired: true,
            hasStoredPassword: false,
            automaticRetryAllowed: true
        ) == .requireLogin)
        assert(authenticationRecoveryAction(
            authenticated: false,
            passwordRequired: true,
            hasStoredPassword: true,
            automaticRetryAllowed: false
        ) == .requireLogin)
        assert(credentialAccount(for: "  https://example.test:8448/  ") == "https://example.test:8448")
        testDropdownPlacement()
        print("StatusBarLogicTests passed")
    }

    private static func testDropdownPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let anchor = CGRect(x: 1000, y: 879, width: 50, height: 24)
        var placement = DropdownPlacement()
        placement.open(anchor: anchor, screen: screen)
        let size = CGSize(width: 384, height: 700)
        let initial = placement.frame(currentAnchor: anchor, screen: screen, size: size)
        assert(initial.maxY == anchor.minY - 4)
        assert(initial.midX == anchor.midX)
        let movedAnchor = anchor.offsetBy(dx: -80, dy: 0)
        // Refreshes may change the status title's width; an open panel stays put.
        assert(placement.frame(currentAnchor: movedAnchor, screen: screen, size: size) == initial)
        placement.close()
        let reopened = placement.frame(currentAnchor: movedAnchor, screen: screen, size: size)
        assert(reopened.midX == movedAnchor.midX)
        for screen in [screen, CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            for x in [screen.minX, screen.maxX] {
                let edgeAnchor = CGRect(x: x, y: screen.maxY, width: 40, height: 24)
                let frame = placement.frame(currentAnchor: edgeAnchor, screen: screen, size: size)
                assert(frame.minX >= screen.minX + 8)
                assert(frame.maxX <= screen.maxX - 8)
                assert(frame.minY >= screen.minY + 8)
            }
        }
    }

    private static func runKeychainPersistenceProbe(mode: String, service: String, serverURL: String) {
        let store = KeychainPasswordStore(service: service)
        #if KEYCHAIN_PROBE_V2
        let testPassword = "keychain-persistence-test-v2"
        #else
        let testPassword = "keychain-persistence-test-v1"
        #endif
        do {
            switch mode {
            case "write":
                try store.deletePassword(for: serverURL)
                try store.save(testPassword, for: serverURL)
                print("Keychain write passed")
            case "read-delete":
                let persistedPassword = try store.password(for: serverURL)
                assert(persistedPassword == testPassword)
                try store.deletePassword(for: serverURL)
                let deletedPassword = try store.password(for: serverURL)
                assert(deletedPassword == nil)
                print("Keychain cross-build read passed")
            default:
                fatalError("Unknown Keychain probe mode")
            }
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
