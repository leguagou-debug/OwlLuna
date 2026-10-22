import UIKit

enum PhotoImport {
    /// A picture for placing on a page: at most `longSide` px on the long side, PNG when it has transparency.
    static func picture(_ image: UIImage, longSide: CGFloat = 1600) throws -> (data: Data, size: CGSize, ext: String) {
        guard image.size.width > 0, image.size.height > 0 else { throw ImportError.unreadable }
        let scale = min(1, longSide / max(image.size.width * image.scale, image.size.height * image.scale))
        let target = CGSize(width: (image.size.width * image.scale * scale).rounded(), height: (image.size.height * image.scale * scale).rounded())
        let alpha = image.cgImage?.alphaInfo ?? .none
        let transparent = ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
        let format = UIGraphicsImageRendererFormat(scale: 1, opaque: !transparent)
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let encoded = transparent ? renderer.pngData { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
                                  : renderer.jpegData(withCompressionQuality: 0.88) { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return (encoded, target, transparent ? "png" : "jpg")
    }

    /// Downscales to at most 2,400 px on the long side and re-encodes as JPEG, off the main thread.
    static func normalize(_ data: Data) throws -> (Data, CGSize) {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { throw ImportError.unreadable }
        let scale = min(1, 2400 / max(image.size.width, image.size.height))
        let target = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(scale: 1)
        let normalized = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = normalized.jpegData(compressionQuality: 0.88) else { throw ImportError.unreadable }
        return (jpeg, target)
    }
}
