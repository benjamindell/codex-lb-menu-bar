import Foundation

@main
enum StatusBarLogicTests {
    static func main() {
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
        print("StatusBarLogicTests passed")
    }
}
