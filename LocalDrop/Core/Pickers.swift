import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// One file waiting to be uploaded or AirDropped.
struct UploadItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    var scoped = false      // security-scoped URL from the Files app
    var temp = false        // temp copy made by us, deleted after upload
}

/// Copies a Photos-library item to a temp file so it can be streamed to the server without loading it into memory.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try PickedMedia.copy(received)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try PickedMedia.copy(received)
        }
    }

    private static func copy(_ received: ReceivedTransferredFile) throws -> PickedMedia {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pick-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(received.file.lastPathComponent)
        try FileManager.default.copyItem(at: received.file, to: dest)
        return PickedMedia(url: dest)
    }
}

@MainActor
func loadPicked(_ items: [PhotosPickerItem]) async -> [UploadItem] {
    var out: [UploadItem] = []
    for item in items {
        guard let m = try? await item.loadTransferable(type: PickedMedia.self) else { continue }
        var name = m.url.lastPathComponent
        if !MediaKind.isMedia(name), let ext = item.supportedContentTypes.first?.preferredFilenameExtension {
            name += "." + ext
        }
        out.append(UploadItem(url: m.url, name: name, scoped: false, temp: true))
    }
    return out
}

/// Adds a Files importer and a Photos picker to any view. `onPick` receives ready-to-upload items.
/// The Photos picker keeps original encodings (`.current`), so HEIC/HEVC are uploaded untouched like the web version promises.
struct UploadPickers: ViewModifier {
    @Binding var showFiles: Bool
    @Binding var showPhotos: Bool
    let onPick: ([UploadItem]) -> Void
    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    onPick(urls.map { UploadItem(url: $0, name: $0.lastPathComponent, scoped: true) })
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $selection,
                          matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
            .onChange(of: selection) { _, new in
                guard !new.isEmpty else { return }
                let picked = new
                selection = []
                Task { onPick(await loadPicked(picked)) }
            }
    }
}

extension View {
    func uploadPickers(showFiles: Binding<Bool>, showPhotos: Binding<Bool>, onPick: @escaping ([UploadItem]) -> Void) -> some View {
        modifier(UploadPickers(showFiles: showFiles, showPhotos: showPhotos, onPick: onPick))
    }
}
