import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@MainActor private final class MockResetAPI: ResetCreditAPI {
    var snapshot: ResetCreditSnapshot?
    var failRead = false
    var failConsume = false
    var waitForConsume = false
    var continuation: CheckedContinuation<Void, Never>?
    var requests: [(account: String, id: String)] = []

    func fetchResetCredits(accountID: String) async throws -> ResetCreditSnapshot? {
        if failRead { throw URLError(.notConnectedToInternet) }
        return snapshot
    }
    func consumeResetCredit(accountID: String, requestID: String) async throws -> ResetCreditResult {
        requests.append((accountID, requestID))
        if waitForConsume { await withCheckedContinuation { continuation = $0 } }
        if failConsume { throw URLError(.timedOut) }
        snapshot = ResetCreditSnapshot(availableCount: 1, credits: Array(snapshot?.availableCredits().dropFirst() ?? []))
        return ResetCreditResult(code: "ok", windowsReset: 1, redeemedAt: Date())
    }
}

@main enum ResetCreditsTests {
    @MainActor static func main() async throws {
        let now = Date()
        let first = ResetCredit(id: "first", resetType: "codex_rate_limits", status: "available", expiresAt: now.addingTimeInterval(3600), title: "Full reset")
        let second = ResetCredit(id: "second", resetType: nil, status: "available", expiresAt: now.addingTimeInterval(7200), title: nil)
        let expired = ResetCredit(id: "expired", resetType: nil, status: "available", expiresAt: now.addingTimeInterval(-1), title: nil)
        let used = ResetCredit(id: "used", resetType: nil, status: "redeemed", expiresAt: nil, title: nil)
        let snapshot = ResetCreditSnapshot(availableCount: 2, credits: [second, expired, used, first])
        expect(snapshot.availableCredits() == [first, second], "Filter expired/spent credits and sort by expiry")
        expect(ResetCreditSnapshot(availableCount: 0, credits: [first]).availableCredits().isEmpty, "Authoritative zero wins")
        let threeDays = now.addingTimeInterval(3 * 86_400)
        expect(ResetCreditAvailability(snapshot: nil, count: 1, nearestExpiry: threeDays, now: now).expiresSoon,
               "Exactly three days is urgent")
        expect(!ResetCreditAvailability(snapshot: nil, count: 1, nearestExpiry: threeDays.addingTimeInterval(1), now: now).expiresSoon,
               "More than three days is not urgent")
        expect(!ResetCreditAvailability(snapshot: nil, count: 0, nearestExpiry: threeDays, now: now).expiresSoon,
               "No credits means no expiry warning")
        expect(!ResetCreditAvailability(snapshot: nil, count: 1, nearestExpiry: now, now: now).expiresSoon,
               "Expired credits do not produce an availability warning")
        expect(!ResetCreditAvailability(snapshot: nil, count: 1, nearestExpiry: nil, now: now).expiresSoon,
               "Missing expiry is not guessed")
        let loaded = ResetCreditAvailability(snapshot: snapshot, count: 9, nearestExpiry: threeDays, now: now)
        expect(loaded.count == 2 && loaded.nearestExpiry == first.expiresAt && loaded.expiresSoon,
               "Loaded credits override the overview and select the soonest available expiry")
        let empty = ResetCreditAvailability(snapshot: ResetCreditSnapshot(availableCount: 0, credits: [first]),
                                            count: 9, nearestExpiry: threeDays, now: now)
        expect(empty.count == 0 && empty.nearestExpiry == nil && !empty.expiresSoon,
               "An authoritative empty snapshot removes the badge and warning")
        expect(ResetCreditRequest.path(accountID: "a/b?c#") == "/api/accounts/a%2Fb%3Fc%23/rate-limit-reset-credits", "Encode account path components")
        let body = try JSONSerialization.jsonObject(with: ResetCreditRequest.body(requestID: "same-id")) as! [String: String]
        expect(body == ["redeemRequestId": "same-id"], "Only send the supported idempotency field")

        let suite = "ResetCreditTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = MockResetAPI()
        api.snapshot = snapshot
        var appliedCount = 0
        let store = ResetCreditStore(accountID: "account-A", server: "https://test", api: api, defaults: defaults) { appliedCount += 1 }
        await store.load()
        expect(api.requests.isEmpty, "Loading must never redeem")
        store.requestConfirmation()
        expect(store.confirmation == first, "Confirm the soonest-expiring reset")
        expect(api.requests.isEmpty, "Opening confirmation must never redeem")
        store.cancelConfirmation()
        await store.confirm()
        expect(api.requests.isEmpty, "Cancel prevents redemption")

        store.requestConfirmation()
        store.beginPresentation()
        await store.confirm()
        expect(store.confirmation == nil && api.requests.isEmpty, "Reopening discards an unconfirmed first click")

        // An ambiguous timeout keeps the exact operation, including after restart.
        store.requestConfirmation()
        api.failConsume = true
        await store.confirm()
        expect(!store.hasAppliedReset && store.errorMessage != nil && store.retryCredit == first, "Retain uncertain redemption for safe retry")
        expect(api.requests.count == 1 && api.requests[0].account == "account-A", "One account-specific consume")
        let originalID = api.requests[0].id
        expect(UUID(uuidString: originalID) != nil, "Use a unique durable request ID")
        store.requestConfirmation()
        expect(store.confirmation == nil, "Cannot select another reset while outcome is uncertain")
        let other = ResetCreditStore(accountID: "account-B", server: "https://test", api: api, defaults: defaults)
        expect(other.retryCredit == nil, "Pending operations are isolated by account")
        let otherServer = ResetCreditStore(accountID: "account-A", server: "https://other", api: api, defaults: defaults)
        expect(otherServer.retryCredit == nil, "Pending operations are isolated by server")
        let restored = ResetCreditStore(accountID: "account-A", server: "https://test", api: api, defaults: defaults) { appliedCount += 1 }
        expect(restored.retryCredit == first, "Restore unresolved operation after relaunch")
        api.failConsume = false
        api.waitForConsume = true
        let applying = Task { await restored.retry() }
        while api.continuation == nil { await Task.yield() }
        expect(restored.isApplying && restored.applyingCreditID == first.id, "Publish loading state for spinners")
        await restored.retry()
        restored.requestConfirmation()
        await restored.confirm()
        expect(api.requests.count == 2, "Double clicks cannot issue duplicate consumes")
        api.continuation?.resume()
        await applying.value
        expect(api.requests[1].id == originalID, "Retry must reuse the durable ID")
        expect(restored.retryCredit == nil && !restored.isApplying && appliedCount == 1, "Success clears pending and refreshes usage once")
        expect(restored.credits == [second], "Reload remaining credits after applying")
        expect(restored.hasAppliedReset, "Success latches the disabled button for this presentation")
        await restored.load()
        restored.requestConfirmation()
        await restored.confirm()
        expect(restored.hasAppliedReset && restored.confirmation == nil && api.requests.count == 2,
               "Refreshing or clicking again cannot redeem another reset in the same presentation")
        restored.beginPresentation()
        restored.requestConfirmation()
        expect(!restored.hasAppliedReset && restored.confirmation == second, "Reopening allows the next reset with fresh confirmation")
        restored.cancelConfirmation()
        let relaunched = ResetCreditStore(accountID: "account-A", server: "https://test", api: api, defaults: defaults)
        expect(relaunched.retryCredit == nil, "Success clears persisted operation")
        api.snapshot = nil
        await relaunched.load()
        relaunched.requestConfirmation()
        expect(relaunched.snapshot == nil && relaunched.confirmation == nil, "Unknown cache is not redeemable zero")
        api.failRead = true
        await relaunched.load()
        expect(relaunched.errorMessage != nil && !relaunched.isLoading, "Read errors leave refresh available")
        print("Reset credit tests passed (no live resets consumed)")
    }
}
