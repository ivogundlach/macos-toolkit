import AppKit

enum Corner: String, CaseIterable, Identifiable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// The point of this corner on a screen, in Cocoa (origin bottom-left) coordinates.
    func point(on screen: NSScreen) -> CGPoint {
        let f = screen.frame
        switch self {
        case .topLeft: return CGPoint(x: f.minX, y: f.maxY)
        case .topRight: return CGPoint(x: f.maxX, y: f.maxY)
        case .bottomLeft: return CGPoint(x: f.minX, y: f.minY)
        case .bottomRight: return CGPoint(x: f.maxX, y: f.minY)
        }
    }

    /// True when `location` is within `size` points of this corner of `screen`.
    func contains(_ location: CGPoint, on screen: NSScreen, size: CGFloat) -> Bool {
        let corner = point(on: screen)
        return abs(location.x - corner.x) <= size && abs(location.y - corner.y) <= size
    }
}

/// What a corner does, and how long the pointer has to rest there first.
struct CornerAction: Codable, Equatable {
    /// Path to the app to open. `nil` means the corner is off.
    var appPath: String?
    /// Dwell time in seconds. 0 fires the moment the pointer touches the corner,
    /// which is how plain hot corners behave.
    var delay: Double = 0.5

    var appURL: URL? { appPath.map { URL(fileURLWithPath: $0) } }
    var isActive: Bool { appPath != nil }

    var appName: String? {
        guard let url = appURL else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
