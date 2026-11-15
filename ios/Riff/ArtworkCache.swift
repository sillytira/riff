import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let root: URL
    private let session: URLSession
    private let memory = NSCache<NSString, NSData>()
    private let maximumBytes = 8 * 1024 * 1024

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Riff/Artwork"), session: URLSession = .shared) {
        self.root = root
        self.session = session
        memory.totalCostLimit = 16 * 1024 * 1024
        memory.countLimit = 128
    }

    func imageData(for raw: String, pixelSize: Int = 1024) async throws -> Data {
        let size = max(1, min(1024, pixelSize))
        let source: URL?
        let key: String
        if raw.hasPrefix("riff-artwork://") {
            let value = String(raw.dropFirst("riff-artwork://".count))
            guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { throw URLError(.badURL) }
            key = value
            source = nil
        } else {
            var components = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw)
            if components?.scheme?.lowercased() == "http", let host = components?.host,
               host != "localhost", host != "127.0.0.1", host != "::1" { components?.scheme = "https" }
            guard let url = components?.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
            source = url
            key = digest(url.absoluteString)
        }
        let memoryKey = "\(key)-\(size)" as NSString
        if let data = memory.object(forKey: memoryKey) { return data as Data }
        let file = root.appending(path: key + ".img")
        let master: Data
        if FileManager.default.fileExists(atPath: file.path) {
            master = try Data(contentsOf: file)
        } else {
            guard let source else { throw URLError(.fileDoesNotExist) }
            var request = URLRequest(url: source)
            request.timeoutInterval = 15
            request.setValue("Riff/0.7.5 (iOS)", forHTTPHeaderField: "User-Agent")
            let (download, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: download) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= Int64(maximumBytes) else {
                throw URLError(.badServerResponse)
            }
            let size = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            let data = try Data(contentsOf: download)
            master = try thumbnail(data, size: 1024)
            try persist(master, key: key)
        }
        let display = size == 1024 ? master : try thumbnail(master, size: size)
        memory.setObject(display as NSData, forKey: memoryKey, cost: display.count)
        return display
    }

    func storeEmbedded(_ data: Data, identity: String) throws -> String {
        guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let key = digest("embedded:" + identity)
        try persist(thumbnail(data, size: 1024), key: key)
        return "riff-artwork://" + key
    }

    private func digest(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func persist(_ data: Data, key: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appending(path: key + ".img"), options: .atomic)
    }
    private func thumbnail(_ data: Data, size: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let output = NSMutableData()
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else { throw URLError(.cannotDecodeContentData) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
        return output as Data
    }
}
