import SwiftUI

struct RibbonShape: Shape {
    static let notch: CGFloat = 0.28

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                           CGPoint(x: rect.midX, y: rect.maxY - rect.width * Self.notch), CGPoint(x: rect.minX, y: rect.maxY)])
            path.closeSubpath()
        }
    }
}
