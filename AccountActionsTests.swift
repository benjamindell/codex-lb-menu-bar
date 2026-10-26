import Foundation

private final class MockAccountProtocol: URLProtocol {
    @MainActor static var handle: ((URLRequest) async -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            let (status, data) = await Self.handle(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main enum AccountActionsTests {
    @MainActor static func main() async throws {
        let suite = "AccountActionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.baseURLString = "https://account-actions-test.invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAccountProtocol.self]

        var status = "active"
        var mutationPaths: [String] = []
        var failMutation = false
        var holdMutation = false
        var pending: CheckedContinuation<Void, Never>?
        func overviewData() -> Data {
            Data("""
            {"accounts":[{"accountId":"test-account","email":"test@example.invalid","displayName":"Test",
            "planType":"pro","routingPolicy":"normal","status":"\(status)","availableResetCredits":2}]}
            """.utf8)
        }
        MockAccountProtocol.handle = { request in
            let path = request.url!.path
            if path == "/api/dashboard-auth/session" {
                return (200, Data("""
                {"authenticated":true,"passwordRequired":false,"totpRequiredOnLogin":false,
                "guestAccessEnabled":false,"guestPasswordRequired":false,"role":"admin"}
                """.utf8))
            }
            if path == "/api/dashboard/overview" { return (200, overviewData()) }
            if path == "/api/accounts/test-account/rate-limit-reset-credits" {
                assert(request.httpMethod == "GET")
                return (200, Data("{\"availableCount\":0,\"credits\":[]}".utf8))
            }
            assert(request.httpMethod == "POST" && request.httpBody == nil)
            assert(path == "/api/accounts/test-account/pause" || path == "/api/accounts/test-account/reactivate")
            mutationPaths.append(path)
            if holdMutation { await withCheckedContinuation { pending = $0 } }
            if failMutation { return (403, Data("Write access required".utf8)) }
            status = path.hasSuffix("/pause") ? "paused" : "active"
            return (200, Data("{\"status\":\"\(status == "paused" ? "paused" : "reactivated")\"}".utf8))
        }
        let model = StatusViewModel(settings: settings, sessionConfiguration: configuration)
        model.overview = try JSONDecoder().decode(DashboardOverview.self, from: overviewData())
        let active = model.overview!.accounts[0]
        let resetStore = model.resetStore(for: active)
        await resetStore.load()
        assert(resetStore.snapshot?.availableCount == 0)

        holdMutation = true
        let pause = Task { await model.changeAccountState(active, action: .pause) }
        for _ in 0..<1_000 {
            if pending != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(pending != nil, "The mocked pause request must start: \(model.accountActionErrors)")
        assert(model.changingAccountIDs.contains(active.id))
        await model.changeAccountState(active, action: .pause)
        assert(mutationPaths.count == 1, "Duplicate clicks must not send another mutation")
        pending?.resume()
        holdMutation = false
        await pause.value
        assert(model.changingAccountIDs.isEmpty)
        assert(model.overview?.accounts.first?.status == "paused", "Refresh must reflect the confirmed pause")
        assert(model.accountActionErrors.isEmpty)
        assert(resetStore.snapshot == nil, "Pause must discard stale reset details")
        assert(model.overview!.accounts[0].resetAvailability(snapshot: resetStore.snapshot).count == 2)

        await model.changeAccountState(active, action: .pause)
        assert(mutationPaths.count == 1, "A stale menu action must not mutate a changed account")
        let paused = model.overview!.accounts[0]
        failMutation = true
        await model.changeAccountState(paused, action: .resume)
        assert(model.overview?.accounts.first?.status == "paused", "Failure must preserve confirmed status")
        assert(model.accountActionErrors[active.id]?.contains("403") == true)
        assert(model.changingAccountIDs.isEmpty, "Failure must release the busy state")

        failMutation = false
        await model.changeAccountState(paused, action: .resume)
        assert(model.overview?.accounts.first?.status == "active")
        assert(model.accountActionErrors.isEmpty)
        await resetStore.load()
        assert(resetStore.snapshot?.availableCount == 0)
        model.refresh()
        for _ in 0..<1_000 {
            if resetStore.snapshot == nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        assert(resetStore.snapshot == nil, "An unchanged overview count of two must invalidate cached zero")
        assert(mutationPaths == ["/api/accounts/test-account/pause", "/api/accounts/test-account/reactivate", "/api/accounts/test-account/reactivate"])
        print("Account action tests passed (mocked HTTP; no live accounts changed)")
    }
}
