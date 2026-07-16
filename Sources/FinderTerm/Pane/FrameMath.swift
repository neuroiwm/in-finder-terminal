import CoreGraphics

enum FrameMath {
    static let minRatio: CGFloat = 0.1
    static let maxRatio: CGFloat = 0.9

    /// AX座標系(左上原点・Y下向き)で、Finderウィンドウの下部ratio分のフレームを返す
    static func paneFrameAX(finderFrame f: CGRect, ratio: CGFloat) -> CGRect {
        let r = min(max(ratio, minRatio), maxRatio)
        let h = (f.height * r).rounded()
        return CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
    }

    /// AX座標系(左上原点)→ Cocoa座標系(左下原点)。primaryScreenHeightは主画面の高さ
    static func axToCocoa(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }
}
