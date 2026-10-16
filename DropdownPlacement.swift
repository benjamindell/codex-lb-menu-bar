import Foundation
import CoreGraphics

// Capture the status item's location for one opening. Its text can resize while
// playing/pausing; only a new opening should follow that new location.
struct DropdownPlacement {
    private var openingAnchor: CGRect?
    private var openingScreen: CGRect?

    mutating func open(anchor: CGRect, screen: CGRect) {
        openingAnchor = anchor
        openingScreen = screen
    }
    mutating func close() { openingAnchor = nil; openingScreen = nil }

    func frame(currentAnchor: CGRect, screen: CGRect, size: CGSize) -> CGRect {
        let anchor = openingAnchor ?? currentAnchor
        let visible = openingScreen ?? screen
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(visible.minY + 8, anchor.minY - size.height - 4)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
