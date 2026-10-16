import AppKit
import SwiftUI

// Match the Sonos Bar panel and keep its chrome visible above a bounded card area.
enum MenuLayout {
    static let width: CGFloat = 384
    static let chromeHeight: CGFloat = 122 // 32 inset + 34 header + 32 footer + 24 gaps
}

@MainActor final class PanelActions: ObservableObject {
    @Published var launchAtLogin = false
    @Published var updateTitle = "Check for Updates…"
    @Published var updateBusy = false
}

private struct MenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private func quotaTint(for percent: Double?) -> Color {
    guard let percent else { return .secondary }
    switch quotaTone(for: percent) {
    case .healthy: return .green
    case .watch: return .orange
    case .critical: return .red
    }
}

private struct QuotaBar: View {
    let value: Double?

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(max(value ?? 0, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.10))
                Capsule().fill(quotaTint(for: value))
                    .frame(width: value == nil ? 0 : max(2, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Remaining capacity")
        .accessibilityValue(roundedPercent(value))
    }
}

private struct QuotaRow: View {
    let title: String
    let value: Double?
    let resetAt: Date?
    var warmupText: String? = nil
    var warmupEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(roundedPercent(value)) left")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
            QuotaBar(value: value)
            HStack(spacing: 8) {
                Text(relativeReset(resetAt).replacingOccurrences(of: "Reset in", with: "Resets in"))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let warmupText {
                    Label(warmupText, systemImage: warmupEnabled ? "bolt.fill" : "bolt.slash")
                        .labelStyle(CompactLabelStyle())
                        .foregroundStyle(warmupEnabled ? Color.blue : Color.secondary)
                        .fixedSize()
                }
            }
            .font(.system(size: 10))
        }
    }
}

private struct AccountCard: View {
    let account: AccountSummary
    let openAccount: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasPrimary: Bool { account.windowMinutesPrimary != nil || account.usage?.primaryRemainingPercent != nil }
    private var hasWeekly: Bool { account.windowMinutesSecondary != nil || account.usage?.secondaryRemainingPercent != nil }
    private var hasMonthly: Bool { account.windowMinutesMonthly != nil || account.usage?.monthlyRemainingPercent != nil }

    private var warmupText: String {
        warmupLabel(enabled: account.limitWarmupEnabled == true,
                    attemptCount: account.limitWarmup?.attempts ?? account.limitWarmup?.attemptCount)
    }

    var body: some View {
        Button(action: openAccount) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(account.status == "active" ? Color.blue : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(account.status == "active" ? .blue.opacity(0.10) : .primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.email).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(account.planType.capitalized + " · " + account.status.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hovered ? Color.blue : Color.secondary)
                }
                if hasPrimary {
                    QuotaRow(title: "5-hour", value: account.usage?.primaryRemainingPercent, resetAt: account.resetAtPrimary,
                             warmupText: !hasWeekly && !hasMonthly ? warmupText : nil, warmupEnabled: account.limitWarmupEnabled == true)
                }
                if hasWeekly {
                    QuotaRow(title: "Weekly", value: account.usage?.secondaryRemainingPercent, resetAt: account.resetAtSecondary,
                             warmupText: !hasMonthly ? warmupText : nil, warmupEnabled: account.limitWarmupEnabled == true)
                }
                if hasMonthly {
                    QuotaRow(title: "Monthly", value: account.usage?.monthlyRemainingPercent, resetAt: account.resetAtMonthly,
                             warmupText: warmupText, warmupEnabled: account.limitWarmupEnabled == true)
                }
                if !hasPrimary && !hasWeekly && !hasMonthly {
                    HStack {
                        Spacer()
                        Label(warmupText, systemImage: account.limitWarmupEnabled == true ? "bolt.fill" : "bolt.slash")
                            .labelStyle(CompactLabelStyle())
                            .foregroundStyle(account.limitWarmupEnabled == true ? Color.blue : Color.secondary)
                    }
                    .font(.system(size: 10))
                }
                if let warmup = account.limitWarmup {
                    Text("Last warm-up: \(warmup.status.replacingOccurrences(of: "_", with: " ")) · \(elapsedSince(warmup.completedAt ?? warmup.attemptedAt) ?? "just now")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let reason = account.deactivationReason, !reason.isEmpty {
                    Text(reason).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
            .overlay(RoundedRectangle(cornerRadius: 18).fill(.primary.opacity(hovered ? 0.035 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: hovered)
        .help("Open \(account.title) in Codex LB")
    }
}

struct MenuContentView: View {
    @ObservedObject var model: StatusViewModel
    @ObservedObject var actions: PanelActions
    let openAccount: (AccountSummary) -> Void
    let openDashboard: () -> Void
    let configureServer: () -> Void
    let toggleLaunchAtLogin: () -> Void
    let checkForUpdates: () -> Void
    let quit: () -> Void
    @State private var settingsMenuAnchor = NSView()

    private var sortedAccounts: [AccountSummary] {
        (model.overview?.accounts ?? []).sorted {
            ($0.status == "active" ? 0 : 1, $0.title.lowercased()) < ($1.status == "active" ? 0 : 1, $1.title.lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            header.frame(height: 34)
            ScrollView {
                VStack(spacing: 12) {
                    if !sortedAccounts.isEmpty {
                        ForEach(sortedAccounts) { account in
                            AccountCard(account: account) { openAccount(account) }
                        }
                    } else if model.errorMessage == nil {
                        emptyState
                    }
                    if let message = model.errorMessage {
                        errorCard(message)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: MenuContentHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(height: model.cardViewportHeight)
            footer.frame(height: 32)
        }
        .padding(16)
        .frame(width: MenuLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PanelMetrics.panelCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.panelCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelMetrics.panelCornerRadius, style: .continuous)
            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .tint(.blue)
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            guard height > 0, model.measuredContentHeight != height else { return }
            model.measuredContentHeight = height
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Group {
                if let url = Bundle.main.url(forResource: "ChatGPTLogo", withExtension: "svg"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "chart.bar").font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(.blue)
            .frame(width: 32, height: 32)
            .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            Text("Codex LB").font(.system(size: 16, weight: .semibold))
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small).frame(width: 14, height: 14) }
            HStack(spacing: 5) {
                let remaining = model.primaryAverage ?? model.secondaryAverage
                Circle().fill(quotaTint(for: remaining)).frame(width: 5, height: 5)
                Text(remaining.map { "\(roundedPercent($0)) remaining" }
                     ?? (model.errorMessage != nil ? "Offline" : model.isRefreshing ? "Connecting" : "No usage"))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
        .help(headerHelp)
    }

    private var headerHelp: String {
        let window = model.primaryAverage != nil ? "5-hour" : "Weekly"
        var details = ["\(window) average remaining capacity", "\(model.activeCount) of \(model.totalCount) accounts active"]
        if let date = model.lastRefreshedAt { details.append("Updated \(relativeUpdated(date))") }
        if let version = model.serverVersion { details.append("Server \(version)") }
        return details.joined(separator: "\n")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary).padding(.top, 20)
            Text(model.isRefreshing ? "Refreshing usage" : "No accounts yet")
                .font(.system(size: 20, weight: .semibold))
            Text(model.isRefreshing ? "Checking your connected accounts…" : "Import an account in Codex LB, then refresh.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Dashboard", action: openDashboard).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity).padding(.bottom, 22).panelCard()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message == "Dashboard login required" ? "Login required" : "Can’t refresh Codex LB", systemImage: "exclamationmark.circle")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Config Server…", action: configureServer).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading).panelCard()
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: showSettingsMenu) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 32)
            }
            .buttonStyle(HoverButtonStyle(isCard: true))
            .background(SettingsMenuAnchor(view: settingsMenuAnchor))
            Button(action: openDashboard) {
                Label("Dashboard", systemImage: "chart.bar.xaxis")
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 32)
            }
            .buttonStyle(HoverButtonStyle(isCard: true))
            Spacer(minLength: 0)
            QuietIconButton(symbol: "arrow.clockwise", title: "Refresh usage", isLoading: model.isRefreshing) { model.refresh() }
            Divider().frame(height: 14).padding(.horizontal, 4)
            QuietIconButton(symbol: "power", title: "Quit Codex LB Menu Bar", hoverColor: .red, action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func showSettingsMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SettingsMenuItem(title: "Config Server…", action: configureServer))
        let launchItem = SettingsMenuItem(title: "Launch at Login", action: toggleLaunchAtLogin)
        launchItem.state = actions.launchAtLogin ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(.separator())
        let updateItem = SettingsMenuItem(title: actions.updateTitle, action: checkForUpdates)
        updateItem.isEnabled = !actions.updateBusy
        menu.addItem(updateItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: settingsMenuAnchor)
    }

}

// The visible control uses the same SwiftUI Button as Dashboard. This view only
// supplies the native menu's anchor, so NSMenu cannot override the button size.
private struct SettingsMenuAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor private final class SettingsMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(activate), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { handler() }
}

private func relativeUpdated(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "just now" }
    if seconds < 3_600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3_600)h ago"
}

final class MenuBarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Codex LB"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
