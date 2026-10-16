import SwiftUI

struct ResetCreditButton: View {
    let account: AccountSummary
    @ObservedObject var store: ResetCreditStore
    @ObservedObject var model: StatusViewModel

    private var isPresented: Binding<Bool> {
        Binding(get: { model.resetPopoverAccountID == account.id },
                set: { model.resetPopoverAccountID = $0 ? account.id : nil })
    }
    private var countText: String {
        if store.isApplying { return "Applying reset…" }
        if store.retryCredit != nil { return "Check reset" }
        let count = store.snapshot?.availableCredits().count ?? account.availableResetCredits
        return count.map { "\($0) \($0 == 1 ? "reset" : "resets")" } ?? "Resets"
    }

    var body: some View {
        Button { isPresented.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                if store.isApplying || store.isLoading {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "arrow.counterclockwise")
                }
                Text(countText)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(ResetCountButtonStyle())
        .fixedSize()
        // Align the text with the quota values; let the hover fill extend beyond it.
        .padding(.trailing, -6)
        .help("View available resets for \(account.email)")
        .accessibilityLabel("\(countText) for \(account.email)")
        .accessibilityValue(isPresented.wrappedValue ? "Expanded" : "Collapsed")
        .onChange(of: account.availableResetCredits) { _ in
            if store.snapshot != nil { Task { await store.load() } }
        }
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            ResetCreditPicker(account: account, store: store) { isPresented.wrappedValue = false }
                .task {
                    store.beginPresentation()
                    await store.load()
                }
        }
    }
}

private struct ResetCountButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration) }
    private struct Surface: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.foregroundStyle(.secondary)
                .background(.primary.opacity(hovered || configuration.isPressed ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}

private struct ResetCreditPicker: View {
    let account: AccountSummary
    @ObservedObject var store: ResetCreditStore
    let close: () -> Void

    private var contentHeight: CGFloat {
        store.credits.isEmpty ? 72 : min(CGFloat(store.credits.count) * 56 - 4, 276)
    }
    private var creditRows: some View {
        VStack(spacing: 4) {
            ForEach(store.credits) { credit in
                ResetCreditRow(credit: credit, isApplying: store.applyingCreditID == credit.id)
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Available resets").font(.system(size: 14, weight: .semibold))
                    Text(account.email).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                QuietIconButton(symbol: "arrow.clockwise", title: "Refresh resets", isLoading: store.isLoading) {
                    Task { await store.load() }
                }.disabled(store.isApplying)
                Divider().frame(height: 14)
                QuietIconButton(symbol: "xmark", title: "Close resets", hoverColor: .red, action: close)
            }
            Group {
                if store.isLoading && store.snapshot == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading resets…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else if store.credits.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 20, weight: .light))
                        Text(store.snapshot == nil ? "Reset availability is unavailable. Try refreshing." : "No resets available.")
                            .font(.system(size: 12)).multilineTextAlignment(.center)
                    }.foregroundStyle(.secondary).padding(.vertical, 16)
                } else {
                    if store.credits.count > 5 {
                        ScrollView { creditRows }
                    } else {
                        creditRows
                    }
                }
            }
            .frame(maxWidth: .infinity).frame(height: contentHeight)

            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            if store.hasAppliedReset {
                Button {} label: {
                    Label("Reset applied", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(true)
            } else {
                Button {
                    if store.retryCredit != nil { Task { await store.retry() } }
                    else if store.confirmation != nil { Task { await store.confirm() } }
                    else { store.requestConfirmation() }
                } label: {
                    HStack(spacing: 6) {
                        if store.isApplying { ProgressView().controlSize(.small) }
                        else { Image(systemName: store.confirmation != nil ? "exclamationmark.triangle" : "arrow.counterclockwise") }
                        Text(store.isApplying ? "Applying reset…" : store.retryCredit != nil ? "Retry same reset" : store.confirmation != nil ? "Confirm reset — can’t undo" : "Use next reset")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.confirmation != nil ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(HoverButtonStyle(isCard: true, isLoading: store.isApplying))
                .disabled(store.isApplying || store.isLoading || (store.credits.isEmpty && store.retryCredit == nil) || account.status != "active")
            }
        }
        .padding(14).frame(width: 320).tint(.blue)
        .onDisappear { store.cancelConfirmation() }
    }
}

private struct ResetCreditRow: View {
    let credit: ResetCredit
    let isApplying: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(credit.displayTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                Text(credit.expiryText).font(.system(size: 10)).foregroundStyle(.secondary)
            }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if isApplying { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
        }
        .padding(.vertical, 8).frame(height: 52)
    }
}
