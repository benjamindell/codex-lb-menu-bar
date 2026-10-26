import Cocoa
import Combine
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

private let defaultBaseURL = "http://127.0.0.1:2455"

final class SettingsStore {
    private let defaults: UserDefaults
    private let baseURLKey = "codexLBBaseURL"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

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

    func resetAvailability(snapshot: ResetCreditSnapshot?) -> ResetCreditAvailability {
        ResetCreditAvailability(snapshot: snapshot, count: availableResetCredits,
                                nearestExpiry: resetCreditNearestExpiresAt)
    }
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

private final class CodexLBClient: ResetCreditAPI {
    private let settings: SettingsStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private(set) var serverVersion: String?

    init(settings: SettingsStore, configuration: URLSessionConfiguration = .default) {
        self.settings = settings
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

    func fetchResetCredits(accountID: String) async throws -> ResetCreditSnapshot? {
        try await request(path: ResetCreditRequest.path(accountID: accountID))
    }

    func consumeResetCredit(accountID: String, requestID: String) async throws -> ResetCreditResult {
        let body = try ResetCreditRequest.body(requestID: requestID)
        return try await request(path: ResetCreditRequest.path(accountID: accountID) + "/consume", method: "POST", body: body)
    }

    func setAccountState(accountID: String, action: AccountPauseAction) async throws {
        struct Response: Decodable { let status: String }
        let _: Response = try await request(path: action.path(accountID: accountID), method: "POST")
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
final class StatusViewModel: ObservableObject {
    @Published var overview: DashboardOverview?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var lastRefreshedAt: Date?
    @Published var serverVersion: String?
    @Published var availableHeight: CGFloat = 720
    @Published var measuredContentHeight: CGFloat?
    @Published var resetPopoverAccountID: String?
    @Published private(set) var changingAccountIDs: Set<String> = []
    @Published private(set) var accountActionErrors: [String: String] = [:]
    private var resetStores: [String: ResetCreditStore] = [:]

    let settings: SettingsStore
    private var client: CodexLBClient
    private let passwordStore = KeychainPasswordStore()
    private var refreshTask: Task<Void, Never>?
    private var refreshAfterCurrent = false
    private var automaticLoginFailedAccount: String?

    init(settings: SettingsStore, sessionConfiguration: URLSessionConfiguration = .default) {
        self.settings = settings
        client = CodexLBClient(settings: settings, configuration: sessionConfiguration)
    }

    func resetStore(for account: AccountSummary) -> ResetCreditStore {
        if let store = resetStores[account.accountId] { return store }
        let store = ResetCreditStore(accountID: account.accountId, server: settings.baseURLString, api: client) { [weak self] in
            guard let self else { return }
            if self.isRefreshing { self.refreshAfterCurrent = true }
            else { self.refresh() }
        }
        resetStores[account.accountId] = store
        return store
    }

    func changeAccountState(_ account: AccountSummary, action: AccountPauseAction) async {
        guard !changingAccountIDs.contains(account.id),
              let current = overview?.accounts.first(where: { $0.id == account.id }),
              AccountPauseAction(status: current.status) == action else { return }
        let operationClient = client
        changingAccountIDs.insert(account.id)
        accountActionErrors[account.id] = nil
        defer {
            if client === operationClient { changingAccountIDs.remove(account.id) }
        }
        do {
            try await operationClient.setAccountState(accountID: account.id, action: action)
            guard client === operationClient else { return }
            resetStores[account.id]?.invalidateSnapshot()
            // Wait out an older overview read before fetching the confirmed state.
            if let refreshTask { await refreshTask.value }
            guard client === operationClient else { return }
            refresh()
            await refreshTask?.value
        } catch {
            guard client === operationClient else { return }
            accountActionErrors[account.id] = "\(action.title) failed: \(error.localizedDescription)"
        }
    }

    var activeCount: Int { overview?.accounts.filter { $0.status == "active" }.count ?? 0 }
    var totalCount: Int { overview?.accounts.count ?? 0 }
    var primaryAverage: Double? { average(overview?.accounts.filter { $0.status == "active" }.map { $0.usage?.primaryRemainingPercent } ?? []) }
    var secondaryAverage: Double? { average(overview?.accounts.filter { $0.status == "active" }.map { $0.usage?.secondaryRemainingPercent } ?? []) }

    // Header and footer stay visible while the cards scroll on smaller screens.
    var cardViewportHeight: CGFloat {
        min(measuredContentHeight ?? 240, max(0, availableHeight - MenuLayout.chromeHeight))
    }

    var preferredPanelHeight: CGFloat { MenuLayout.chromeHeight + cardViewportHeight }

    func refresh() {
        guard !isRefreshing else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.performRefresh() }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshAfterCurrent {
                refreshAfterCurrent = false
                refresh()
            }
        }
        do {
            let session = try await client.getSession()
            try await recoverAuthenticationIfNeeded(session)
            let value = try await client.fetchOverview()
            for account in value.accounts {
                guard let store = resetStores[account.id] else { continue }
                let previous = overview?.accounts.first { $0.id == account.id }
                let cachedCount = store.snapshot?.availableCredits().count
                let countDisagrees = account.availableResetCredits.map { cachedCount != nil && cachedCount != $0 } ?? false
                if previous?.status != account.status || previous?.availableResetCredits != account.availableResetCredits ||
                   previous?.resetCreditNearestExpiresAt != account.resetCreditNearestExpiresAt || countDisagrees {
                    store.invalidateSnapshot()
                    if resetPopoverAccountID == account.id {
                        Task { await store.load() }
                    }
                }
            }
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
        resetPopoverAccountID = nil
        changingAccountIDs.removeAll()
        accountActionErrors.removeAll()
        resetStores.removeAll()
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

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let updater = AppUpdater()
    private lazy var viewModel = StatusViewModel(settings: settings)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = MenuBarPanel()
    private let actions = PanelActions()
    private var placement = DropdownPlacement()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var latestUpdate: AppUpdate?
    private var updateCheckTask: Task<Void, Never>?
    private var hostingView: NSHostingView<MenuContentView>?
    private var timer: Timer?
    private var updateTimer: Timer?
    private var modelObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--show-panel") ? .regular : .accessory)
        Logger(subsystem: "com.codexlb.status", category: "MenuPanel").info("Application launched")
        if let button = statusItem.button {
            button.image = menuBarIcon()
            button.imagePosition = .imageLeading
            button.title = "LB"
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.toolTip = "Codex LB Menu Bar"
        }

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let content = MenuContentView(
            model: viewModel, actions: actions,
            openAccount: { [weak self] in self?.openAccount($0) },
            openDashboard: { [weak self] in self?.openDashboard() },
            configureServer: { [weak self] in self?.configureServer() },
            toggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin(nil) },
            checkForUpdates: { [weak self] in self?.checkForUpdatesFromMenu(nil) },
            quit: { [weak self] in self?.quit() }
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        hostingView.layer?.cornerRadius = PanelMetrics.panelCornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        self.hostingView = hostingView
        resizeHostingView()
        updateLaunchAtLoginItem()
        checkForUpdates(showErrors: false)

        modelObservation = viewModel.objectWillChange.sink { [weak self] _ in
            // Published values and SwiftUI measurement settle before window sizing.
            Task { @MainActor in
                self?.updateStatusButton()
                self?.resizeHostingView()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.viewModel.refresh() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates(showErrors: false) }
        }
        viewModel.refresh()
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.togglePanel()
            }
        }
    }

    private func menuBarIcon() -> NSImage {
        if let resourceURL = Bundle.main.url(forResource: "ChatGPTLogo", withExtension: "svg"),
           let image = NSImage(contentsOf: resourceURL) {
            image.isTemplate = true
            image.size = NSSize(width: 17, height: 17)
            image.accessibilityDescription = "Codex LB"
            return image
        }

        // Keep the status item usable if an older/incomplete app bundle is
        // launched before the new resource has been copied into place.
        return NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex LB")!
    }

    @objc private func togglePanel() {
        if panel.isVisible { closeMenu(); return }
        guard let button = statusItem.button, let window = button.window else { return }
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        viewModel.availableHeight = max(MenuLayout.chromeHeight, visible.height - 12)
        placement.open(anchor: window.convertToScreen(button.convert(button.bounds, to: nil)), screen: visible)
        updateLaunchAtLoginItem()
        resizeHostingView()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        Logger(subsystem: "com.codexlb.status", category: "MenuPanel")
            .info("Dropdown visible: \(self.panel.isVisible), frame: \(NSStringFromRect(self.panel.frame), privacy: .public)")
        startDismissalMonitors()
        viewModel.refresh()
    }

    private func resizeHostingView() {
        guard let button = statusItem.button, let window = button.window else { return }
        let size = NSSize(width: MenuLayout.width, height: viewModel.preferredPanelHeight)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let frame = placement.frame(currentAnchor: anchor, screen: visible, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
            panel.invalidateShadow()
        }
    }

    private func startDismissalMonitors() {
        stopDismissalMonitors()
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in self?.closeMenu() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // Let an open Settings menu handle Escape before closing the panel.
                if event.keyCode == 53, event.window === self.panel {
                    self.closeMenu()
                    return nil
                }
            } else if !self.belongsToPanel(event.window),
                      event.window !== self.statusItem.button?.window,
                      event.window?.level != .popUpMenu {
                self.closeMenu()
            }
            return event
        }
    }

    private func belongsToPanel(_ window: NSWindow?) -> Bool {
        var current = window
        while let candidate = current {
            if candidate === panel { return true }
            current = candidate.parent
        }
        return false
    }

    private func stopDismissalMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = menuBarTitle(primary: viewModel.primaryAverage, secondary: viewModel.secondaryAverage)
    }

    private func updateLaunchAtLoginItem() {
        actions.launchAtLogin = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }

    private func closeMenu() {
        viewModel.resetPopoverAccountID = nil
        panel.orderOut(nil)
        placement.close()
        stopDismissalMonitors()
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

    @objc private func checkForUpdatesFromMenu(_ sender: Any?) {
        if latestUpdate != nil {
            installUpdate()
        } else {
            checkForUpdates(showErrors: true)
        }
    }

    private func checkForUpdates(showErrors: Bool) {
        guard updateCheckTask == nil else { return }
        actions.updateBusy = true
        actions.updateTitle = "Checking for Updates…"
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let update = try await updater.checkForUpdate()
                latestUpdate = update
                actions.updateTitle = update.map { "Install Update \($0.version)" } ?? "Check for Updates…"
            } catch {
                latestUpdate = nil
                actions.updateTitle = "Check for Updates…"
                if showErrors { showError(error.localizedDescription) }
            }
            actions.updateBusy = false
            updateCheckTask = nil
        }
    }

    private func installUpdate() {
        guard let update = latestUpdate else { return }
        closeMenu()
        actions.updateBusy = true
        actions.updateTitle = "Installing Update…"
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await updater.install(update)
                NSApp.terminate(nil)
            } catch {
                actions.updateTitle = "Install Update \(update.version)"
                actions.updateBusy = false
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
        stopDismissalMonitors()
    }
}

#if !TESTING
@main
#endif
private enum CodexLBMenuBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
