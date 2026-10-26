import SwiftUI

struct ResetCreditBadge: View {
    let availability: ResetCreditAvailability
    let isCardHovered: Bool

    var body: some View {
        if let count = availability.count, count > 0 {
            Text("\(count)")
                .font(.system(size: 7, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(width: 12, height: 12)
                .background(availability.expiresSoon ? Color.red : isCardHovered ? Color.blue : Color(nsColor: .darkGray), in: Circle())
                .offset(x: -2, y: -2)
                .accessibilityLabel("\(count) resets available" + (availability.expiresSoon ? ", next reset expires within 3 days" : ""))
        }
    }
}

struct AccountActionsMenu: View {
    let account: AccountSummary
    @ObservedObject var store: ResetCreditStore
    @ObservedObject var model: StatusViewModel
    @State private var menuAnchor = NSView()

    private var isPresented: Binding<Bool> {
        Binding(get: { model.resetPopoverAccountID == account.id },
                set: { model.resetPopoverAccountID = $0 ? account.id : nil })
    }
    private var isChangingAccount: Bool { model.changingAccountIDs.contains(account.id) }
    private var countText: String {
        let count = account.resetAvailability(snapshot: store.snapshot).count
        let title = count.map { "\($0) \($0 == 1 ? "reset" : "resets") available" } ?? "View available resets"
        if store.isApplying { return title + " · Applying…" }
        if store.retryCredit != nil { return title + " · Check previous reset" }
        return title
    }

    var body: some View {
        Button(action: showMenu) {
            Group {
                if isChangingAccount {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "ellipsis")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(HoverButtonStyle(isCard: true, isLoading: isChangingAccount))
        .fixedSize()
        .background(MenuAnchor(view: menuAnchor))
        .help("Account options for \(account.email)")
        .accessibilityLabel("Account options for \(account.email)")
        .onChange(of: account.availableResetCredits) { _ in
            if store.snapshot != nil { Task { await store.load() } }
        }
        .onChange(of: account.resetCreditNearestExpiresAt) { _ in
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

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem(title: countText) {
            // Present after the native dropdown has finished dismissing.
            DispatchQueue.main.async { isPresented.wrappedValue = true }
        })
        menu.addItem(.separator())
        let action = AccountPauseAction(status: account.status)
        let item = ActionMenuItem(title: isChangingAccount ? "Updating account…" : action?.title ?? "Pause account") {
            guard let action else { return }
            Task { await model.changeAccountState(account, action: action) }
        }
        item.image = NSImage(systemSymbolName: action?.symbol ?? "pause", accessibilityDescription: nil)
        item.isEnabled = action != nil && !isChangingAccount && !store.isApplying
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: menuAnchor)
    }
}

private struct ResetCreditPicker: View {
    let account: AccountSummary
    @ObservedObject var store: ResetCreditStore
    let close: () -> Void

    private var rowsHeight: CGFloat { CGFloat(store.credits.count) * 76 - 12 }
    private var contentHeight: CGFloat {
        store.credits.isEmpty ? 72 : min(rowsHeight, 276)
    }
    private var creditRows: some View {
        VStack(spacing: 12) {
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
                    if rowsHeight > 276 {
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
        .frame(height: 32)
        .panelCard()
    }
}
