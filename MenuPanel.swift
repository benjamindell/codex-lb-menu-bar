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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(roundedPercent(value)) left")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
            QuotaBar(value: value)
            Text(relativeReset(resetAt).replacingOccurrences(of: "Reset in", with: "Resets in"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct AccountCard: View {
    let account: AccountSummary
    let openAccount: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                if account.windowMinutesPrimary != nil || account.usage?.primaryRemainingPercent != nil {
                    QuotaRow(title: "5-hour", value: account.usage?.primaryRemainingPercent, resetAt: account.resetAtPrimary)
                }
                if account.windowMinutesSecondary != nil || account.usage?.secondaryRemainingPercent != nil {
                    QuotaRow(title: "Weekly", value: account.usage?.secondaryRemainingPercent, resetAt: account.resetAtSecondary)
                }
                if account.windowMinutesMonthly != nil || account.usage?.monthlyRemainingPercent != nil {
                    QuotaRow(title: "Monthly", value: account.usage?.monthlyRemainingPercent, resetAt: account.resetAtMonthly)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(warmupText, systemImage: account.limitWarmupEnabled == true ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(account.limitWarmupEnabled == true ? Color.blue : Color.secondary)
                    if let warmup = account.limitWarmup {
                        Text("Last warm-up: \(warmup.status.replacingOccurrences(of: "_", with: " ")) · \(elapsedSince(warmup.completedAt ?? warmup.attemptedAt) ?? "just now")")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10))
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
    @State private var settingsHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        summary
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
                Circle().fill(model.errorMessage != nil ? .orange : model.overview != nil ? .green : .secondary)
                    .frame(width: 5, height: 5)
                Text(model.errorMessage != nil ? "Offline" : model.overview != nil ? "Connected" : "Connecting")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private var summary: some View {
        VStack(spacing: 12) {
            SectionHeading(title: "REMAINING CAPACITY", detail: "\(model.activeCount) of \(model.totalCount) active")
            HStack(spacing: 16) {
                summaryMetric("5-hour", value: model.primaryAverage)
                Divider().frame(height: 36)
                summaryMetric("Weekly", value: model.secondaryAverage)
            }
            HStack {
                Text(model.lastRefreshedAt.map { "Updated \(relativeUpdated($0))" } ?? "Auto-refreshes every minute")
                Spacer()
                if let version = model.serverVersion { Text("Server \(version)").lineLimit(1) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .panelCard()
    }

    private func summaryMetric(_ title: String, value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(roundedPercent(value)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(quotaTint(for: value))
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Menu {
                Button("Config Server…", action: configureServer)
                Button(action: toggleLaunchAtLogin) {
                    if actions.launchAtLogin { Label("Launch at Login", systemImage: "checkmark") }
                    else { Text("Launch at Login") }
                }
                Divider()
                Button(actions.updateTitle, action: checkForUpdates).disabled(actions.updateBusy)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16).frame(height: 32)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(.secondary)
            .background(.primary.opacity(settingsHovered ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 10))
            .onHover { settingsHovered = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: settingsHovered)
            Button(action: openDashboard) {
                Label("Dashboard", systemImage: "chart.bar.xaxis")
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
