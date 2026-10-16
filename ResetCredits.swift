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
    @Published private(set) var successMessage: String?
    @Published private var pending: PendingReset?

    let accountID: String
    private let api: ResetCreditAPI
    private let defaults: UserDefaults
    private let pendingKey: String
    private let didApply: () -> Void

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
    var retryCredit: ResetCredit? { pending?.credit }
    var applyingCreditID: String? { isApplying ? pending?.credit.id : nil }
    var isBlocked: Bool { isLoading || isApplying || confirmation != nil || pending != nil }

    func load() async {
        guard !isLoading, !isApplying else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await api.fetchResetCredits(accountID: accountID)
            try Task.checkCancellation()
            snapshot = result
            if pending == nil { errorMessage = nil }
        } catch is CancellationError {
            // Closing the picker cancels reads, never a confirmed redemption.
        } catch {
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
        guard let credit = confirmation, !isApplying else { return }
        confirmation = nil
        pending = PendingReset(credit: credit, requestID: UUID().uuidString)
        persistPending()
        await applyPending()
    }

    func retry() async {
        guard pending != nil, !isApplying, !isLoading else { return }
        await applyPending()
    }

    private func applyPending() async {
        guard let operation = pending, !isApplying else { return }
        isApplying = true
        errorMessage = nil
        successMessage = nil
        do {
            _ = try await api.consumeResetCredit(accountID: accountID, requestID: operation.requestID)
            pending = nil
            defaults.removeObject(forKey: pendingKey)
            snapshot = nil
            successMessage = "Reset applied. Refreshing usage…"
            didApply()
        } catch {
            errorMessage = "Couldn’t confirm the reset. Retry safely to check the same reset. \(error.localizedDescription)"
        }
        isApplying = false
        if pending == nil {
            await load()
            successMessage = "Reset applied."
        }
    }

    private func persistPending() {
        if let pending, let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: pendingKey) }
    }
}
