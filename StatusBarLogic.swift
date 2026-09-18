import Foundation

enum QuotaTone {
    case healthy, watch, critical
}

func quotaTone(for percent: Double) -> QuotaTone {
    if percent >= 70 { return .healthy }
    if percent >= 30 { return .watch }
    return .critical
}

func roundedPercent(_ value: Double?) -> String {
    guard let value else { return "--" }
    return "\(Int(value.rounded()))%"
}

/// Deliberately avoids calendar dates. The menu is designed to answer “how long?” at a glance.
func relativeReset(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "Reset unavailable" }
    let seconds = Int(date.timeIntervalSince(now))
    if seconds <= 0 { return "Reset now" }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return hours > 0 ? "Reset in \(days)d \(hours)h" : "Reset in \(days)d" }
    if hours > 0 { return "Reset in \(hours)h \(max(1, minutes))m" }
    return "Reset in \(max(1, minutes))m"
}

func elapsedSince(_ date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return "\(days)d \(hours)h ago" }
    if hours > 0 { return "\(hours)h \(minutes)m ago" }
    return "\(max(1, minutes))m ago"
}

func warmupLabel(enabled: Bool, attemptCount: Int?) -> String {
    guard enabled else { return "Warm-up off" }
    guard let attemptCount, attemptCount > 0 else { return "Warm-up on" }
    return "Warm-up on (\(attemptCount) \(attemptCount == 1 ? "attempt" : "attempts"))"
}

func average(_ values: [Double?]) -> Double? {
    let values = values.compactMap { $0 }
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

func menuBarTitle(primary: Double?, secondary: Double?) -> String {
    if let primary { return "\(Int(primary.rounded()))%" }
    if let secondary { return "\(Int(secondary.rounded()))%" }
    return "LB"
}

