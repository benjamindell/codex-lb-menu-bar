import Combine
import Foundation

struct ResetCredit: Codable, Identifiable, Equatable {
    let id: String
    let resetType: String?
    let status: String?
    let expiresAt: Date?
    let title: String?

    var displayTitle: String { title?.isEmpty == false ? title! : "Full reset" }
    var expiryText: String {
        expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No expiry provided"
    }
}

struct ResetCreditSnapshot: Decodable {
    let availableCount: Int
    let credits: [ResetCredit]

    func availableCredits(at now: Date = Date()) -> [ResetCredit] {
        guard availableCount > 0 else { return [] }
        return credits.filter { $0.status == "available" && ($0.expiresAt.map { $0 > now } ?? true) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}

// Use the overview immediately, then prefer the detailed credit list once loaded.
struct ResetCreditAvailability {
    let count: Int?
    let nearestExpiry: Date?
    let expiresSoon: Bool

    init(snapshot: ResetCreditSnapshot?, count: Int?, nearestExpiry: Date?, now: Date = Date()) {
        if let snapshot {
            let credits = snapshot.availableCredits(at: now)
            self.count = credits.count
            self.nearestExpiry = credits.first?.expiresAt
        } else {
            self.count = count
            self.nearestExpiry = count == 0 ? nil : nearestExpiry.flatMap { $0 > now ? $0 : nil }
        }
        expiresSoon = self.nearestExpiry.map { $0.timeIntervalSince(now) <= 3 * 86_400 } ?? false
    }
}

struct ResetCreditResult: Decodable {
    let code: String?
    let windowsReset: Int?
    let redeemedAt: Date?
}

protocol ResetCreditAPI {
    func fetchResetCredits(accountID: String) async throws -> ResetCreditSnapshot?
    func consumeResetCredit(accountID: String, requestID: String) async throws -> ResetCreditResult
}

enum ResetCreditRequest {
    static func path(accountID: String) -> String {
        let component = accountID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? accountID
        return "/api/accounts/\(component)/rate-limit-reset-credits"
    }

    static func body(requestID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["redeemRequestId": requestID])
    }
}

// Keep a confirmed operation across retries and launches. The server pins this
// request ID to one credit, so retrying cannot consume the next available one.
private struct PendingReset: Codable {
    let credit: ResetCredit
    let requestID: String
}

@MainActor
final class ResetCreditStore: ObservableObject {
    @Published private(set) var snapshot: ResetCreditSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var confirmation: ResetCredit?
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasAppliedReset = false
    @Published private(set) var isPaused = false
    @Published private var overviewCount: Int?
    @Published private var overviewExpiry: Date?
    @Published private var pending: PendingReset?

    let accountID: String
    private let api: ResetCreditAPI
    private let defaults: UserDefaults
    private let pendingKey: String
    private let didApply: () -> Void
    private var loadGeneration = 0

    init(accountID: String, server: String, api: ResetCreditAPI,
         defaults: UserDefaults = .standard, didApply: @escaping () -> Void = {}) {
        self.accountID = accountID
        self.api = api
        self.defaults = defaults
        self.didApply = didApply
        pendingKey = "pendingReset." + Data("\(server)/\(accountID)".utf8).base64EncodedString()
        pending = defaults.data(forKey: pendingKey).flatMap { try? JSONDecoder().decode(PendingReset.self, from: $0) }
    }

    var credits: [ResetCredit] { snapshot?.availableCredits() ?? [] }
    var availability: ResetCreditAvailability {
        // Without individual dates, an expired summary cannot tell us how many
        // of the remembered credits remain. Show unknown until a fresh read.
        let summaryExpired = isPaused && overviewExpiry.map { $0 <= Date() } == true
        return ResetCreditAvailability(snapshot: snapshot,
                                       count: summaryExpired ? nil : overviewCount,
                                       nearestExpiry: overviewExpiry)
    }
    var retryCredit: ResetCredit? { pending?.credit }
    var applyingCreditID: String? { isApplying ? pending?.credit.id : nil }
    var isBlocked: Bool { isPaused || isLoading || isApplying || hasAppliedReset || confirmation != nil || pending != nil }

    func updateAccount(status: String, count: Int?, nearestExpiry: Date?) {
        let paused = status == "paused"
        let statusChanged = paused != isPaused
        if paused {
            // Paused endpoints may report zero usable credits. That is not an
            // inventory update: retain the last known count and expiry instead.
            if statusChanged {
                let staleZero = snapshot?.availableCredits().isEmpty == true && (overviewCount ?? 0) > 0
                invalidateSnapshot(preservingCredits: !staleZero)
                confirmation = nil
            }
            if overviewCount == nil, let count, count > 0 {
                overviewCount = count
                overviewExpiry = nearestExpiry
            }
        } else {
            let cachedCount = snapshot?.availableCredits().count
            if statusChanged || overviewCount != count || overviewExpiry != nearestExpiry ||
               (count != nil && cachedCount != nil && cachedCount != count) {
                invalidateSnapshot()
            }
            overviewCount = count
            overviewExpiry = nearestExpiry
        }
        isPaused = paused
    }

    func beginPresentation() {
        hasAppliedReset = false
        confirmation = nil
    }

    // A quota/status refresh supersedes cached credit details, including reads
    // started while an account was paused. Never let those restore an old zero.
    func invalidateSnapshot(preservingCredits: Bool = false) {
        loadGeneration += 1
        if !preservingCredits { snapshot = nil }
        isLoading = false
    }

    func load() async {
        guard !isPaused, !isLoading, !isApplying else { return }
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let result = try await api.fetchResetCredits(accountID: accountID)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            snapshot = result
            if pending == nil { errorMessage = nil }
        } catch is CancellationError {
            // Closing the picker cancels reads, never a confirmed redemption.
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    // Selecting or cancelling never sends a consume request.
    func requestConfirmation() {
        guard !isBlocked, let credit = credits.first else { return }
        confirmation = credit
    }

    func cancelConfirmation() { confirmation = nil }

    func confirm() async {
        guard !isPaused, let credit = confirmation, !isApplying else { return }
        confirmation = nil
        pending = PendingReset(credit: credit, requestID: UUID().uuidString)
        persistPending()
        await applyPending()
    }

    func retry() async {
        guard !isPaused, pending != nil, !isApplying, !isLoading else { return }
        await applyPending()
    }

    private func applyPending() async {
        guard let operation = pending, !isApplying else { return }
        isApplying = true
        errorMessage = nil
        do {
            _ = try await api.consumeResetCredit(accountID: accountID, requestID: operation.requestID)
            pending = nil
            defaults.removeObject(forKey: pendingKey)
            snapshot = nil
            hasAppliedReset = true
            didApply()
        } catch {
            errorMessage = "Couldn’t confirm the reset. Retry safely to check the same reset. \(error.localizedDescription)"
        }
        isApplying = false
        if pending == nil {
            await load()
        }
    }

    private func persistPending() {
        if let pending, let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: pendingKey) }
    }
}
