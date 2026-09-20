import Foundation

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
        print("StatusBarLogicTests passed")
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
