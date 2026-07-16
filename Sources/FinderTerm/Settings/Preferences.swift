import Foundation
import CoreGraphics

final class Preferences {
    static let shared = Preferences(defaults: .standard)

    private enum Key {
        static let ratio = "paneHeightRatio"
        static let panesVisible = "panesVisible"
    }

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
}
