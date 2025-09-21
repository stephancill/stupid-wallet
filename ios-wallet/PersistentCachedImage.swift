import SwiftUI
import CryptoKit

struct PersistentCachedImage<Placeholder: View>: View {
    let url: URL?
    let cacheKey: String
    let folderName: String
    let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var didAttemptDownload: Bool = false

    init(url: URL?, cacheKey: String, folderName: String = "images", @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.cacheKey = cacheKey
        self.folderName = folderName
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let uiImage = uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
                    .onAppear { loadFromDiskIfAvailable() }
                    .task { await downloadIfNeeded() }
            }
        }
    }

    private func hashedKey() -> String {
        let data = Data(cacheKey.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func containerDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupId)
    }

    private func imagesDirectory() -> URL? {
        guard let base = containerDirectory() else { return nil }
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func imageFileURL() -> URL? {
        guard let dir = imagesDirectory() else { return nil }
        return dir.appendingPathComponent(hashedKey() + ".img", isDirectory: false)
    }

    private func loadFromDiskIfAvailable() {
        guard uiImage == nil, let file = imageFileURL(), let data = try? Data(contentsOf: file), let image = UIImage(data: data) else {
            return
        }
        uiImage = image
    }

    private func persistToDisk(_ data: Data) {
        guard let file = imageFileURL() else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func downloadIfNeeded() async {
        guard uiImage == nil else { return }
        guard !didAttemptDownload else { return }
        didAttemptDownload = true
        guard let url = url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                persistToDisk(data)
                await MainActor.run { uiImage = image }
            }
        } catch {
            // ignore
        }
    }
}


