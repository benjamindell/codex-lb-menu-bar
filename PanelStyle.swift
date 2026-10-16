import SwiftUI

enum PanelMetrics {
    static let cardInset: CGFloat = 16
    static let panelCornerRadius: CGFloat = 16
}

extension View {
    func panelCard() -> some View {
        padding(PanelMetrics.cardInset)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.035)))
    }
}

struct CardTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String = ""

    var body: some View {
        HStack {
            CardTitle(title: title)
            Spacer()
            if !detail.isEmpty { Text(detail).font(.system(size: 11, weight: .medium)).monospacedDigit() }
        }
        .foregroundStyle(.secondary)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

struct QuietIconButton: View {
    let symbol: String
    let title: String
    var helpText: String? = nil
    var hoverColor: Color = .blue
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                }
            }
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(HoverButtonStyle(color: hoverColor, isLoading: isLoading))
        .disabled(isLoading)
        .help(helpText ?? title)
        .accessibilityLabel(title)
    }
}


struct HoverButtonStyle: ButtonStyle {
    var color: Color = .blue
    var isCard = false
    var isLoading = false

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, color: color, isCard: isCard, isLoading: isLoading)
    }

    private struct Surface: View {
        let configuration: ButtonStyle.Configuration
        let color: Color
        let isCard: Bool
        let isLoading: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let highlighted = isEnabled && (hovered || configuration.isPressed)
            configuration.label
                .foregroundStyle(highlighted && !isCard ? color : Color.secondary)
                .background(.primary.opacity(isCard ? (highlighted ? 0.10 : 0.045) : 0), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .opacity(isEnabled || isLoading ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: highlighted)
        }
    }
}
