import Cocoa
import Combine
import Foundation
import ServiceManagement
import SwiftUI

private let defaultBaseURL = "http://127.0.0.1:2455"

private final class SettingsStore {
    private let defaults = UserDefaults.standard
    private let baseURLKey = "codexLBBaseURL"

    var baseURLString: String {
        get { defaults.string(forKey: baseURLKey) ?? defaultBaseURL }
        set { defaults.set(Self.normalized(newValue), forKey: baseURLKey) }
    }

    var baseURL: URL { URL(string: baseURLString) ?? URL(string: defaultBaseURL)! }

    private static func normalized(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultBaseURL : value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private enum UpdateConfiguration {
    // Keep the release channel in Info.plist so a fork can point at its own
    // GitHub repository without changing updater code.
    static var repository: String {
        (Bundle.main.object(forInfoDictionaryKey: "CodexLBUpdateRepository") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var assetName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CodexLBUpdateAssetName") as? String ?? "CodexLBMenuBar.zip")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var releasesURL: URL? {
        guard !repository.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        return url
    }

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let body: String?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct AppUpdate {
    let version: String
    let releaseName: String
    let releaseNotes: String
    let assetURL: URL
}

private struct ComparableVersion: Comparable {
    private let components: [Int]

    init(_ value: String) {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        components = normalized
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func < (lhs: ComparableVersion, rhs: ComparableVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

private enum UpdateError: LocalizedError {
    case notConfigured
    case invalidResponse
    case server(Int)
    case noCompatibleAsset
    case invalidArchive
    case unsignedArchive
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "GitHub Releases updates are not configured for this build."
        case .invalidResponse:
            return "GitHub returned an invalid release response."
        case .server(let status):
            return "GitHub returned HTTP \(status) while checking for updates."
        case .noCompatibleAsset:
            return "The latest GitHub release does not contain a Codex LB Menu Bar update archive."
        case .invalidArchive:
            return "The downloaded update did not contain a Codex LB Menu Bar app."
        case .unsignedArchive:
            return "The downloaded update failed its code-signature check."
        case .installFailed(let message):
            return "Couldn’t prepare the update: \(message)"
        }
    }
}

private final class AppUpdater {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func checkForUpdate() async throws -> AppUpdate? {
        guard let url = UpdateConfiguration.releasesURL else { throw UpdateError.notConfigured }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexLBMenuBar/\(UpdateConfiguration.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
        guard response.statusCode == 200 else { throw UpdateError.server(response.statusCode) }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard ComparableVersion(release.tagName) > ComparableVersion(UpdateConfiguration.currentVersion) else { return nil }
        guard let asset = release.assets.first(where: { $0.name == UpdateConfiguration.assetName })
            ?? release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else {
            throw UpdateError.noCompatibleAsset
        }
        return AppUpdate(
            version: release.tagName,
            releaseName: release.name,
            releaseNotes: release.body ?? "",
            assetURL: asset.browserDownloadURL
        )
    }

    func install(_ update: AppUpdate) async throws {
        var request = URLRequest(url: update.assetURL)
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        request.setValue("CodexLBMenuBar/\(UpdateConfiguration.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent("CodexLBMenuBar-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
            let archive = workspace.appendingPathComponent("update.zip")
            try data.write(to: archive, options: .atomic)
            let extractionDirectory = workspace.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
            try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extractionDirectory.path])

            guard let appURL = findApp(in: extractionDirectory) else { throw UpdateError.invalidArchive }
            guard verifyCodeSignature(at: appURL) else { throw UpdateError.unsignedArchive }
            try launchInstaller(workspace: workspace, replacementApp: appURL)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    private func findApp(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }
        return nil
    }

    private func verifyCodeSignature(at appURL: URL) -> Bool {
        (try? runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])) != nil
    }

    private func launchInstaller(workspace: URL, replacementApp: URL) throws {
        let currentApp = Bundle.main.bundleURL.standardizedFileURL
        let replacementAppPath = replacementApp.path
        let targetApp = currentApp.deletingLastPathComponent().appendingPathComponent(replacementApp.lastPathComponent)
        let scriptURL = workspace.appendingPathComponent("install-update.zsh")
        let script = """
        #!/bin/zsh
        set -euo pipefail
        old_target=\(shellQuote(currentApp.path))
        target=\(shellQuote(targetApp.path))
        replacement=\(shellQuote(replacementAppPath))
        workspace=\(shellQuote(workspace.path))
        pid=\(ProcessInfo.processInfo.processIdentifier)
        for _ in {1..120}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.25
        done
        /bin/rm -rf "$old_target"
        /bin/rm -rf "$target"
        /usr/bin/ditto "$replacement" "$target"
        /usr/bin/open "$target"
        /bin/rm -rf "$workspace"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    private func runProcess(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.installFailed("\(path) exited with status \(process.terminationStatus)")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum ClientError: LocalizedError {
    case invalidURL(String), unauthorized, savedPasswordRejected, twoFactorRequired, server(Int, String), transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "Invalid server URL: \(value)"
        case .unauthorized: return "Dashboard login required"
        case .savedPasswordRejected: return "The saved dashboard password was rejected. Open Config Server… and enter the current password."
        case .twoFactorRequired: return "Two-factor authentication is required. Open Config Server… to finish logging in."
        case .server(let code, let body): return body.isEmpty ? "Server returned HTTP \(code)" : "Server returned HTTP \(code): \(body)"
        case .transport(let message): return message
        }
    }
}

private struct AuthSession: Decodable {
    let authenticated: Bool
    let passwordRequired: Bool
    let totpRequiredOnLogin: Bool
    let guestAccessEnabled: Bool
    let guestPasswordRequired: Bool
    let role: String
}

struct DashboardOverview: Decodable {
    let lastSyncAt: Date?
    let accounts: [AccountSummary]
}

struct AccountSummary: Decodable, Identifiable {
    let accountId: String
    let email: String
    let alias: String?
    let displayName: String
    let planType: String
    let routingPolicy: String
    let status: String
    let usage: AccountUsage?
    let resetAtPrimary: Date?
    let resetAtSecondary: Date?
    let resetAtMonthly: Date?
    let windowMinutesPrimary: Int?
    let windowMinutesSecondary: Int?
    let windowMinutesMonthly: Int?
    let lastRefreshAt: Date?
    let deactivationReason: String?
    let securityWorkAuthorized: Bool?
    let limitWarmupEnabled: Bool?
    let limitWarmup: AccountLimitWarmupStatus?
    let availableResetCredits: Int?
    let resetCreditNearestExpiresAt: Date?

    var id: String { accountId }
    var title: String { (alias?.isEmpty == false ? alias : displayName) ?? displayName }
}

struct AccountUsage: Decodable {
    let primaryRemainingPercent: Double?
    let secondaryRemainingPercent: Double?
    let monthlyRemainingPercent: Double?
}

struct AccountLimitWarmupStatus: Decodable {
    let window: String
    let status: String
    let model: String
    let attemptedAt: Date
    let completedAt: Date?
    // Newer servers may expose this; older servers simply omit it.
    let attempts: Int?
    let attemptCount: Int?
}

private final class CodexLBClient {
    private let settings: SettingsStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private(set) var serverVersion: String?

    init(settings: SettingsStore) {
        self.settings = settings
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
        decoder = JSONDecoder.codexLBDecoder()
    }

    func getSession() async throws -> AuthSession { try await request(path: "/api/dashboard-auth/session") }
    func fetchOverview() async throws -> DashboardOverview { try await request(path: "/api/dashboard/overview?timeframe=7d") }

    func loginPassword(_ password: String) async throws -> AuthSession {
        let body = try JSONSerialization.data(withJSONObject: ["password": password])
        return try await request(path: "/api/dashboard-auth/password/login", method: "POST", body: body)
    }

    func loginGuest(password: String?) async throws -> AuthSession {
        let body = password.flatMap { $0.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: ["password": $0]) }
        return try await request(path: "/api/dashboard-auth/guest/login", method: "POST", body: body)
    }

    func verifyTotp(_ code: String) async throws -> AuthSession {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        return try await request(path: "/api/dashboard-auth/totp/verify", method: "POST", body: body)
    }

    private func request<T: Decodable>(path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let base = settings.baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let rawURL = "\(base)/\(suffix)"
        guard let url = URL(string: rawURL) else { throw ClientError.invalidURL(rawURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ClientError.transport("Unexpected non-HTTP response") }
            serverVersion = response.value(forHTTPHeaderField: "X-App-Version")
            if response.statusCode == 401 { throw ClientError.unauthorized }
            guard (200..<300).contains(response.statusCode) else { throw ClientError.server(response.statusCode, String(data: data, encoding: .utf8) ?? "") }
            return try decoder.decode(T.self, from: data)
        } catch let error as ClientError { throw error }
        catch { throw ClientError.transport(error.localizedDescription) }
    }
}

private extension JSONDecoder {
    static func codexLBDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }
}

@MainActor
private final class StatusViewModel: ObservableObject {
    @Published var overview: DashboardOverview?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var lastRefreshedAt: Date?
    @Published var serverVersion: String?
    @Published var showSettings = false
    @Published var availableHeight: CGFloat = 520
    @Published var measuredContentHeight: CGFloat?

    let settings: SettingsStore
    private var client: CodexLBClient
    private let passwordStore = KeychainPasswordStore()
    private var refreshTask: Task<Void, Never>?
    private var automaticLoginFailedAccount: String?

    init(settings: SettingsStore) {
        self.settings = settings
        client = CodexLBClient(settings: settings)
    }

    var activeCount: Int { overview?.accounts.filter { $0.status == "active" }.count ?? 0 }
    var totalCount: Int { overview?.accounts.count ?? 0 }
    var primaryAverage: Double? { average(overview?.accounts.filter { $0.status == "active" }.map { $0.usage?.primaryRemainingPercent } ?? []) }
    var secondaryAverage: Double? { average(overview?.accounts.filter { $0.status == "active" }.map { $0.usage?.secondaryRemainingPercent } ?? []) }

    /// The menu item should be content-sized until the account list genuinely
    /// needs scrolling. `availableHeight` is only the screen-derived ceiling.
    var preferredMenuHeight: CGFloat {
        guard let accounts = overview?.accounts, !accounts.isEmpty else {
            return min(320, availableHeight)
        }

        if let measuredContentHeight, measuredContentHeight > 0 {
            return min(measuredContentHeight, availableHeight)
        }

        // Keep the native menu content-sized for the common case instead of
        // reserving a generic fixed-height viewport. A row with one quota has
        // no quota heading; rows with multiple windows get a little more room
        // for the labelled bars and their reset metadata.
        let accountHeight = accounts.reduce(CGFloat.zero) { total, account in
            let quotaCount = [
                account.windowMinutesPrimary != nil || account.usage?.primaryRemainingPercent != nil,
                account.windowMinutesSecondary != nil || account.usage?.secondaryRemainingPercent != nil,
                account.windowMinutesMonthly != nil || account.usage?.monthlyRemainingPercent != nil,
            ].filter { $0 }.count
            let quotaRowHeight: CGFloat = quotaCount > 1 ? 45 : 25
            let quotaSpacing = CGFloat(max(0, quotaCount - 1)) * 8
            let cardHeight = 16 + 40 + 8 + CGFloat(quotaCount) * quotaRowHeight + quotaSpacing
            return total + cardHeight
        }
        let separators = CGFloat(max(0, accounts.count - 1))
        let desiredHeight = 10 + 52 + 14 + accountHeight + separators + 14
        return min(desiredHeight, availableHeight)
    }

    func refresh() {
        guard !isRefreshing else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.performRefresh() }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let session = try await client.getSession()
            try await recoverAuthenticationIfNeeded(session)
            let value = try await client.fetchOverview()
            overview = value
            serverVersion = client.serverVersion
            errorMessage = nil
            lastRefreshedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
            if error is ClientError { overview = nil }
        }
    }

    private func recoverAuthenticationIfNeeded(_ session: AuthSession) async throws {
        let account = credentialAccount(for: settings.baseURLString)
        let password = try passwordStore.password(for: settings.baseURLString)
        let action = authenticationRecoveryAction(
            authenticated: session.authenticated,
            passwordRequired: session.passwordRequired,
            hasStoredPassword: password != nil,
            automaticRetryAllowed: automaticLoginFailedAccount != account
        )

        switch action {
        case .none:
            automaticLoginFailedAccount = nil
        case .requireLogin:
            throw ClientError.unauthorized
        case .useStoredPassword:
            guard let password else { throw ClientError.unauthorized }
            do {
                let recovered = try await client.loginPassword(password)
                if recovered.totpRequiredOnLogin {
                    automaticLoginFailedAccount = account
                    throw ClientError.twoFactorRequired
                }
                guard recovered.authenticated else {
                    automaticLoginFailedAccount = account
                    throw ClientError.savedPasswordRejected
                }
                automaticLoginFailedAccount = nil
            } catch ClientError.unauthorized {
                automaticLoginFailedAccount = account
                throw ClientError.savedPasswordRejected
            }
        }
    }

    func changeServerURL(_ value: String, refreshImmediately: Bool = true) {
        settings.baseURLString = value
        client = CodexLBClient(settings: settings)
        automaticLoginFailedAccount = nil
        if refreshImmediately { refresh() }
    }

    func loginAdmin(password: String) async throws -> Bool {
        let session = try await client.loginPassword(password)
        try passwordStore.save(password, for: settings.baseURLString)
        automaticLoginFailedAccount = nil
        if session.totpRequiredOnLogin { return true }
        refresh()
        return false
    }

    func hasSavedPassword(for serverURL: String) -> Bool {
        (try? passwordStore.password(for: serverURL)) != nil
    }

    func forgetSavedPassword() throws {
        try passwordStore.deletePassword(for: settings.baseURLString)
        automaticLoginFailedAccount = credentialAccount(for: settings.baseURLString)
    }

    func verifyTotp(_ code: String) async throws { _ = try await client.verifyTotp(code); refresh() }

    func loginGuest(password: String?) async throws { _ = try await client.loginGuest(password: password); refresh() }
}

private struct MenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum MenuLayout {
    static let width: CGFloat = 300
    static let hoverInset: CGFloat = 7
    static let rowPadding: CGFloat = 7
    // Every visible content edge uses this guide; backgrounds extend outward
    // by rowPadding, leaving hoverInset between them and the menu edge.
    static let contentInset = hoverInset + rowPadding
    static let trailingColumnWidth: CGFloat = 38
}

private struct ColorTokens {
    static let blue = Color(red: 0.19, green: 0.49, blue: 0.92)
    static let green = Color(red: 0.16, green: 0.72, blue: 0.43)
    static let amber = Color(red: 0.92, green: 0.58, blue: 0.15)
    static let red = Color(red: 0.88, green: 0.23, blue: 0.29)
}

private func quotaTint(for percent: Double?) -> Color {
    guard let percent else { return .secondary }
    switch quotaTone(for: percent) { case .healthy: return ColorTokens.green; case .watch: return ColorTokens.amber; case .critical: return ColorTokens.red }
}

private struct ColoredQuotaProgressStyle: ProgressViewStyle {
    let tint: Color
    let minimumFill: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            let fraction = min(max(configuration.fractionCompleted ?? 0, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: fraction == 0 ? minimumFill : proxy.size.width * fraction)
            }
            .frame(height: 6)
        }
        .frame(height: 6)
        .accessibilityElement(children: .combine)
    }
}

private struct QuotaBar: View {
    let value: Double?
    var body: some View {
        ProgressView(value: value.map { min(max($0, 0), 100) }, total: 100)
            .progressViewStyle(ColoredQuotaProgressStyle(tint: quotaTint(for: value), minimumFill: value == nil ? 0 : 2))
            .frame(height: 6)
    }
}

private struct QuotaRow: View {
    let title: String?
    let value: Double?
    let resetAt: Date?

    init(title: String? = nil, value: Double?, resetAt: Date?) {
        self.title = title
        self.value = value
        self.resetAt = resetAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            QuotaBar(value: value)
            HStack(spacing: 4) {
                Text(relativeReset(resetAt).replacingOccurrences(of: "Reset in", with: "Resets in"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(roundedPercent(value)) left")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(value == nil ? .secondary : .primary)
            }
            .font(.caption2.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountCard: View {
    let account: AccountSummary
    let openAccount: () -> Void
    @State private var isHovered = false

    private var warmupText: String { account.limitWarmupEnabled == true ? "Warm-up on" : "Warm-up off" }
    private var warmupIcon: String { account.limitWarmupEnabled == true ? "bolt.fill" : "bolt.slash" }
    private var warmupColor: Color { account.limitWarmupEnabled == true ? ColorTokens.blue : .secondary }
    private var hasPrimary: Bool { account.windowMinutesPrimary != nil || account.usage?.primaryRemainingPercent != nil }
    private var hasWeekly: Bool { account.windowMinutesSecondary != nil || account.usage?.secondaryRemainingPercent != nil }
    private var hasMonthly: Bool { account.windowMinutesMonthly != nil || account.usage?.monthlyRemainingPercent != nil }
    private var quotaCount: Int { [hasPrimary, hasWeekly, hasMonthly].filter { $0 }.count }
    private var showQuotaLabels: Bool { quotaCount > 1 }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(account.email).font(.headline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(account.planType.capitalized).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: warmupIcon)
                        .font(.caption)
                        .foregroundStyle(warmupColor)
                    Text(warmupText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
            VStack(spacing: 8) {
                if hasPrimary {
                    QuotaRow(
                        title: showQuotaLabels ? "5-hour" : nil,
                        value: account.usage?.primaryRemainingPercent,
                        resetAt: account.resetAtPrimary
                    )
                }
                if hasWeekly {
                    QuotaRow(
                        title: showQuotaLabels ? "Weekly" : nil,
                        value: account.usage?.secondaryRemainingPercent,
                        resetAt: account.resetAtSecondary
                    )
                }
                if hasMonthly {
                    QuotaRow(
                        title: showQuotaLabels ? "Monthly" : nil,
                        value: account.usage?.monthlyRemainingPercent,
                        resetAt: account.resetAtMonthly
                    )
                }
            }
        }
        .padding(.vertical, 8)
    }

    var body: some View {
        Button(action: openAccount) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MenuLayout.rowPadding)
                .background(isHovered ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open \(account.title) in Codex LB")
    }
}

private struct MenuContentView: View {
    @ObservedObject var model: StatusViewModel
    let openAccount: (AccountSummary) -> Void

    private var sortedAccounts: [AccountSummary] { (model.overview?.accounts ?? []).sorted { ($0.status == "active" ? 0 : 1, $0.title.lowercased()) < ($1.status == "active" ? 0 : 1, $1.title.lowercased()) } }

    var body: some View {
        ZStack {
            // Keep the surface transparent so the native NSMenu window supplies
            // its material, edge treatment, and shadow.
            Color.clear.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let _ = model.overview, !sortedAccounts.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(sortedAccounts.enumerated()), id: \.element.id) { index, account in
                                AccountCard(account: account, openAccount: { openAccount(account) })
                                if index < sortedAccounts.count - 1 {
                                    Divider().padding(.horizontal, MenuLayout.rowPadding)
                                }
                            }
                        }
                    } else if let message = model.errorMessage {
                        emptyState(title: message == "Dashboard login required" ? "Login required" : "Can’t reach Codex LB", detail: message)
                    } else {
                        emptyState(title: model.isRefreshing ? "Refreshing usage" : "No accounts yet", detail: model.isRefreshing ? "Checking your connected apps…" : "Import an account in Codex LB, then refresh.")
                    }
                }
                .padding(.horizontal, MenuLayout.hoverInset)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: MenuContentHeightKey.self, value: proxy.size.height)
                })
            }
        }
        // Keep the native menu item tight for the empty/error state. Once there
        // are enough account cards to exceed the screen-derived ceiling, the
        // inner ScrollView becomes the bounded viewport.
        .frame(width: MenuLayout.width, height: model.preferredMenuHeight)
        .preferredColorScheme(nil)
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            guard height > 0 else { return }
            model.measuredContentHeight = height
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex LB").font(.headline.weight(.semibold))
                    Text(model.lastRefreshedAt.map { "Updated \(relativeUpdated($0))" } ?? "Auto-refreshes every minute")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    let average = model.secondaryAverage ?? model.primaryAverage
                    Text(roundedPercent(average))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(quotaTint(for: average))
                    Text("\(model.activeCount)/\(model.totalCount) active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
        }
        .padding(.horizontal, MenuLayout.rowPadding)
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Image(systemName: "waveform.path.ecg").font(.title2).foregroundStyle(ColorTokens.blue); Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, MenuLayout.rowPadding).padding(.vertical, 18).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

}

private func relativeUpdated(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "just now" }
    if seconds < 3_600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3_600)h ago"
}

private final class MenuActionItemView: NSView {
    private let titleField: NSTextField
    private let trailingField: NSTextField
    private let activateAction: () -> Void
    private(set) var isHighlighted = false
    private var isActionEnabled = true

    override var intrinsicContentSize: NSSize { NSSize(width: MenuLayout.width, height: 24) }

    init(title: String, trailing: String = "", action: @escaping () -> Void = {}) {
        titleField = NSTextField(labelWithString: title)
        trailingField = NSTextField(labelWithString: trailing)
        activateAction = action
        super.init(frame: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 24))
        titleField.font = .menuFont(ofSize: 0)
        trailingField.font = .menuFont(ofSize: 0)
        trailingField.alignment = .right
        titleField.translatesAutoresizingMaskIntoConstraints = false
        trailingField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingField.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(titleField)
        addSubview(trailingField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuLayout.contentInset),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingField.leadingAnchor, constant: -8),
            trailingField.widthAnchor.constraint(equalToConstant: MenuLayout.trailingColumnWidth),
            trailingField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuLayout.contentInset),
            trailingField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ value: String) { titleField.stringValue = value }

    func setTrailing(_ value: String) { trailingField.stringValue = value }

    func setEnabled(_ enabled: Bool) {
        isActionEnabled = enabled
        alphaValue = enabled ? 1 : 0.55
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isActionEnabled else { return }
        setHighlighted(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isActionEnabled else { return }
        let location = convert(event.locationInWindow, from: nil)
        setHighlighted(false)
        guard bounds.contains(location) else { return }
        activateAction()
    }

    func setHighlighted(_ highlighted: Bool) {
        isHighlighted = highlighted
        updateColors()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.systemBlue.setFill()
        let highlightRect = bounds.insetBy(dx: MenuLayout.hoverInset, dy: 0)
        NSBezierPath(roundedRect: highlightRect, xRadius: 7, yRadius: 7).fill()
    }

    private func updateColors() {
        let color = isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.controlTextColor
        titleField.textColor = color
        trailingField.textColor = isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsStore()
    private let updater = AppUpdater()
    private lazy var viewModel = StatusViewModel(settings: settings)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let menuItem = NSMenuItem()
    private var launchAtLoginItem: NSMenuItem?
    private var launchAtLoginView: MenuActionItemView?
    private var updateItem: NSMenuItem?
    private var updateView: MenuActionItemView?
    private var latestUpdate: AppUpdate?
    private var updateCheckTask: Task<Void, Never>?
    private var hostingView: NSHostingView<MenuContentView>?
    private var timer: Timer?
    private var updateTimer: Timer?
    private var modelObservation: AnyCancellable?
    private var heightObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex LB")
            button.imagePosition = .imageLeading
            button.title = "LB"
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.toolTip = "Codex LB Menu Bar"
        }

        // Assigning an NSMenu to the status item gives us the same native menu
        // tracking, anchoring, keyboard handling, and dismissal behavior as the
        // rest of the macOS menu bar. The single custom item is only the content
        // surface; AppKit still owns the menu window itself.
        menu.delegate = self
        menu.autoenablesItems = false
        menuItem.isEnabled = true
        menuItem.view = makeHostingView(height: viewModel.preferredMenuHeight)
        menu.addItem(menuItem)
        menu.addItem(.separator())
        addNativeActionItems()
        statusItem.menu = menu
        checkForUpdates(showErrors: false)

        modelObservation = viewModel.$overview.sink { [weak self] _ in
            self?.updateStatusButton()
            self?.resizeHostingView()
        }
        heightObservation = viewModel.$measuredContentHeight.sink { [weak self] _ in
            self?.resizeHostingView()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.viewModel.refresh() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates(showErrors: false) }
        }
        viewModel.refresh()
    }

    private func makeHostingView(height: CGFloat) -> NSHostingView<MenuContentView> {
        let rootView = MenuContentView(
            model: viewModel,
            openAccount: { [weak self] account in self?.openAccount(account) }
        )
        let view = NSHostingView(rootView: rootView)
        view.frame = NSRect(x: 0, y: 0, width: MenuLayout.width, height: height)
        view.autoresizingMask = [.width, .height]
        hostingView = view
        return view
    }

    private func menuHeight(for screen: NSScreen?) -> CGFloat {
        let visibleHeight = screen?.visibleFrame.height ?? 720
        // Leave a little room for the menu bar and the native menu's own margins.
        return min(720, max(320, visibleHeight - 72))
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let button = statusItem.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let height = menuHeight(for: screen)
        viewModel.availableHeight = height
        resizeHostingView()
        updateStatusButton()
        updateLaunchAtLoginItem()
        viewModel.refresh()
    }

    private func resizeHostingView() {
        hostingView?.setFrameSize(NSSize(width: MenuLayout.width, height: viewModel.preferredMenuHeight))
    }

    func menuDidClose(_ menu: NSMenu) {
        // NSMenu owns the close animation and state. This callback is intentionally
        // side-effect free so reopening always starts from AppKit's normal state.
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = menuBarTitle(primary: viewModel.primaryAverage, secondary: viewModel.secondaryAverage)
    }

    private func addNativeActionItems() {
        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboardFromMenu(_:)), keyEquivalent: "")
        dashboardItem.target = self
        dashboardItem.view = MenuActionItemView(title: "Open Dashboard", action: { [weak self] in self?.openDashboard() })
        menu.addItem(dashboardItem)

        let serverItem = NSMenuItem(title: "Config Server…", action: #selector(configureServerFromMenu(_:)), keyEquivalent: "")
        serverItem.target = self
        serverItem.view = MenuActionItemView(title: "Config Server…", action: { [weak self] in self?.configureServer() })
        menu.addItem(serverItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        let launchView = MenuActionItemView(title: "Launch at Login", action: { [weak self] in self?.toggleLaunchAtLogin(nil) })
        launchItem.view = launchView
        launchAtLoginView = launchView
        launchAtLoginItem = launchItem
        menu.addItem(launchItem)
        updateLaunchAtLoginItem()

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesFromMenu(_:)), keyEquivalent: "")
        updateItem.target = self
        let updateView = MenuActionItemView(title: "Check for Updates…", action: { [weak self] in self?.checkForUpdatesFromMenu(nil) })
        updateItem.view = updateView
        self.updateItem = updateItem
        self.updateView = updateView
        menu.addItem(updateItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Codex LB Menu Bar", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        quitItem.view = MenuActionItemView(title: "Quit Codex LB Menu Bar", trailing: "⌘Q", action: { [weak self] in self?.quit() })
        menu.addItem(quitItem)
    }

    private func updateLaunchAtLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        launchAtLoginItem?.state = .off
        guard launchAtLoginItem != nil else { return }
        launchAtLoginView?.setTrailing(enabled ? "✓" : "")
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            (menuItem.view as? MenuActionItemView)?.setHighlighted(menuItem === item)
        }
    }

    private func closeMenu() {
        menu.cancelTracking()
    }

    private func openDashboard() { closeMenu(); NSWorkspace.shared.open(settings.baseURL) }

    private func openAccount(_ account: AccountSummary) {
        closeMenu()
        var components = URLComponents(url: settings.baseURL.appendingPathComponent("accounts"), resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "selected", value: account.accountId))
        components?.queryItems = queryItems
        NSWorkspace.shared.open(components?.url ?? settings.baseURL)
    }

    @objc private func openDashboardFromMenu(_ sender: Any?) { openDashboard() }
    @objc private func configureServerFromMenu(_ sender: Any?) { configureServer() }
    @objc private func checkForUpdatesFromMenu(_ sender: Any?) {
        if latestUpdate != nil {
            installUpdate()
        } else {
            checkForUpdates(showErrors: true)
        }
    }

    private func checkForUpdates(showErrors: Bool) {
        guard updateCheckTask == nil else { return }
        updateItem?.isEnabled = false
        updateView?.setEnabled(false)
        updateView?.setTitle("Checking for Updates…")
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let update = try await updater.checkForUpdate()
                latestUpdate = update
                updateView?.setTitle(update.map { "Install Update \($0.version)" } ?? "Check for Updates…")
            } catch {
                latestUpdate = nil
                updateView?.setTitle("Check for Updates…")
                if showErrors { showError(error.localizedDescription) }
            }
            updateItem?.isEnabled = true
            updateView?.setEnabled(true)
            updateCheckTask = nil
        }
    }

    private func installUpdate() {
        guard let update = latestUpdate else { return }
        closeMenu()
        updateItem?.isEnabled = false
        updateView?.setEnabled(false)
        updateView?.setTitle("Installing Update…")
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await updater.install(update)
                NSApp.terminate(nil)
            } catch {
                updateView?.setTitle("Install Update \(update.version)")
                updateItem?.isEnabled = true
                updateView?.setEnabled(true)
                showError(error.localizedDescription)
                updateCheckTask = nil
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        closeMenu()
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
            updateLaunchAtLoginItem()
            if service.status == .requiresApproval {
                showError("Allow Codex LB Menu Bar in System Settings → General → Login Items to finish enabling launch at login.")
            }
        } catch {
            updateLaunchAtLoginItem()
            showError("Couldn’t update launch at login: \(error.localizedDescription)")
        }
    }
    @objc private func quitFromMenu(_ sender: Any?) { quit() }

    private func configureServer() {
        closeMenu()
        let alert = NSAlert()
        alert.messageText = "Codex LB Server"
        alert.informativeText = "Passwords are stored securely in your Mac login Keychain and reused when the dashboard session expires."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let urlLabel = NSTextField(labelWithString: "Server URL")
        let urlField = NSTextField(string: settings.baseURLString)
        let passwordLabel = NSTextField(labelWithString: "Password")
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = viewModel.hasSavedPassword(for: settings.baseURLString)
            ? "Saved in Keychain — leave blank to keep"
            : "Enter password if required"
        let forgetPassword = NSButton(checkboxWithTitle: "Forget saved password", target: nil, action: nil)

        let form = NSStackView(views: [urlLabel, urlField, passwordLabel, passwordField, forgetPassword])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 5
        form.frame = NSRect(x: 0, y: 0, width: 360, height: 112)
        NSLayoutConstraint.activate([
            urlField.widthAnchor.constraint(equalToConstant: 360),
            passwordField.widthAnchor.constraint(equalToConstant: 360),
        ])
        alert.accessoryView = form

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = passwordField.stringValue
        let shouldForgetPassword = forgetPassword.state == .on && password.isEmpty
        viewModel.changeServerURL(
            urlField.stringValue,
            refreshImmediately: password.isEmpty && !shouldForgetPassword
        )

        if shouldForgetPassword {
            do {
                try viewModel.forgetSavedPassword()
                viewModel.refresh()
            } catch { showError(error.localizedDescription) }
            return
        }
        guard !password.isEmpty else { return }

        Task {
            do {
                if try await viewModel.loginAdmin(password: password) {
                    try await verifyTotp()
                }
            } catch { showError(error.localizedDescription) }
        }
    }

    private func verifyTotp() async throws {
        let alert = NSAlert()
        alert.messageText = "Two-factor authentication"
        alert.informativeText = "Enter the dashboard TOTP code."
        alert.addButton(withTitle: "Verify")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try await viewModel.verifyTotp(field.stringValue)
    }

    private func quit() {
        closeMenu()
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) { let alert = NSAlert(); alert.messageText = "Codex LB Menu Bar"; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.runModal() }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        updateTimer?.invalidate()
        updateCheckTask?.cancel()
        modelObservation?.cancel()
        heightObservation?.cancel()
    }
}

@main
private enum CodexLBMenuBarMain {
    @MainActor static func main() { let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run() }
}
