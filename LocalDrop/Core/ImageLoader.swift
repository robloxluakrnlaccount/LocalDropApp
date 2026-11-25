import SwiftUI
import UIKit
import ImageIO

/// AsyncImage uses its own URLSession and would not send the `ld_id` cookie, so private photos would 404.
/// This loader goes through APIClient instead and keeps decoded images in memory.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    var api: APIClient?
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 800
        cache.totalCostLimit = 220 * 1024 * 1024
    }

    private func key(_ url: URL) -> NSString { url.absoluteString as NSString }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: key(url)) }

    func clear() { cache.removeAllObjects() }

    func load(_ url: URL, animatedGIF: Bool = false) async -> UIImage? {
        if let c = cached(url) { return c }
        guard let api, let data = try? await api.rawData(url: url) else { return nil }
        var image: UIImage?
        if animatedGIF { image = ImageLoader.animatedGIF(data) }
        if image == nil { image = UIImage(data: data) }
        guard let img = image else { return nil }
        let ready = (await img.byPreparingForDisplay()) ?? img
        let cost = Int(ready.size.width * ready.size.height * ready.scale * ready.scale * 4)
        cache.setObject(ready, forKey: key(url), cost: cost)
        return ready
    }

    /// Decodes every frame of a GIF so UIImageView can animate it (the web version shows GIFs animated).
    static func animatedGIF(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return nil }
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<n {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            total += max(delay, 0.02)
        }
        return frames.isEmpty ? nil : UIImage.animatedImage(with: frames, duration: total)
    }
}

/// Square-friendly thumbnail. Fill the parent with `.aspectRatio(1, contentMode: .fit)` outside.
struct RemoteThumb: View {
    let url: URL?
    var isVideo = false
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color.clear
            .overlay {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if failed {
                        Image(systemName: isVideo ? "film" : "photo")
                            .font(.title2).foregroundStyle(.secondary)
                    }
                }
            }
            .clipped()
            .task(id: url) {
                image = nil
                failed = false
                guard let url else { failed = true; return }
                if let c = ImageLoader.shared.cached(url) { image = c; return }
                if let img = await ImageLoader.shared.load(url) { image = img } else { failed = true }
            }
    }
}
