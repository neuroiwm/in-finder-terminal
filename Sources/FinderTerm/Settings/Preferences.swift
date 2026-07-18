import Foundation
import CoreGraphics

final class Preferences {
    static let shared = Preferences(defaults: .standard)

    private enum Key {
        static let ratio = "paneHeightRatio"
        static let panesVisible = "panesVisible"
        static let opacity = "paneOpacity"
    }

    static let minOpacity: CGFloat = 0.3
    static let maxOpacity: CGFloat = 1.0

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var paneHeightRatio: CGFloat {
        get {
            let v = defaults.double(forKey: Key.ratio)
            guard v > 0 else { return 0.4 }
            return min(max(CGFloat(v), FrameMath.minRatio), FrameMath.maxRatio)
        }
        set {
            let clamped = min(max(newValue, FrameMath.minRatio), FrameMath.maxRatio)
            defaults.set(Double(clamped), forKey: Key.ratio)
        }
    }

    var panesVisible: Bool {
        get { defaults.object(forKey: Key.panesVisible) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.panesVisible) }
    }

    /// ペイン背景の不透明度。1.0で不透明、下げるほどFinderの中身が透ける
    var paneOpacity: CGFloat {
        get {
            let v = defaults.double(forKey: Key.opacity)
            guard v > 0 else { return 0.85 }
            return min(max(CGFloat(v), Self.minOpacity), Self.maxOpacity)
        }
        set {
            let clamped = min(max(newValue, Self.minOpacity), Self.maxOpacity)
            defaults.set(Double(clamped), forKey: Key.opacity)
        }
    }
}
