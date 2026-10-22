import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let rgba = OwlLunaRGBA(hex: hex, alpha: alpha)
        self.init(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }
}
