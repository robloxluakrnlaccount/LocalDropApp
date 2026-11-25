import SwiftUI

/// What the full-screen viewer needs to know about where its media comes from.
struct ViewerContext {
    var items: [RemoteFile]
    var start: Int
    var srcURL: (RemoteFile) -> URL?
    var thumbURL: (RemoteFile) -> URL?
    var meta: (RemoteFile) -> MediaMeta?
    var deleteTitle: (RemoteFile) -> String
    var onDelete: ((RemoteFile) async -> Bool)?
}

struct ViewerSession: Identifiable {
    let id = UUID()
    let ctx: ViewerContext
}

@MainActor
final class PhotosModel: ObservableObject {
    let api: APIClient
    weak var store: AppStore?

    /// "shared" or the id of a photo folder (own private library or one shared with this device).
    @Published var space = "shared"
    @Published var photos: [RemoteFile] = []
    @Published var albums: [Album] = []
    @Published var meta: [String: MediaMeta] = [:]
    @Published var loaded = false

    init(api: APIClient) { self.api = api }

    var paths: SpacePaths { SpacePaths(space: space) }

    func reset() {
        space = "shared"; photos = []; albums = []; meta = [:]; loaded = false
    }

    // MARK: URLs

    func thumbURL(_ p: RemoteFile) -> URL? { api.thumbURL(path: paths.src(p.name), file: p) }
    func fullURL(_ p: RemoteFile) -> URL? { api.mediaURL(path: paths.src(p.name), file: p) }

    /// Best-known date for a photo: EXIF / video creation date from /api/meta, else the file date.
    func metaOf(_ p: RemoteFile) -> MediaMeta {
        meta[p.name] ?? MediaMeta(t: p.modified, src: "file", w: nil, h: nil, cam: nil)
    }

    func metaLine(_ p: RemoteFile) -> String {
        let m = metaOf(p)
        let extra = [m.cam ?? "", (m.w != nil && m.h != nil) ? "\(m.w!)×\(m.h!)" : "", m.src == "file" ? "file date" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let date = DateFmt.format(m.t, short: false)
        return extra.isEmpty ? date : date + "  ·  " + extra
    }

    // MARK: Loading

    func setSpace(_ v: String) async {
        var target = v
        if v == "mine" {
            if let lib = store?.myLibrary {
                target = lib.id
            } else {
                let name = "Photos by " + (store?.settings.deviceName ?? "Device")
                guard let id = try? await api.createMyLibrary(name: name) else {
                    store?.toast("Could not create your private library.")
                    return
                }
                target = id
            }
        }
        space = target
        photos = []; albums = []; meta = [:]; loaded = false
        await refresh()
    }

    func refresh() async {
        await store?.refreshFolders()
        if space != "shared", store?.folders.contains(where: { $0.id == space }) != true { space = "shared" }
        let sp = space
        do {
            let list = try await api.get(FilesResponse.self, SpacePaths(space: sp).list).files.sorted { $0.modified > $1.modified }
            guard sp == space else { return }
            photos = list
            albums = (try? await api.albums(space: sp)) ?? []
            loaded = true
        } catch {
            store?.toast("Could not load photos.")
        }
        if let m = try? await api.meta(space: sp), sp == space { meta = m }
    }

    // MARK: Library actions

    func upload(_ items: [UploadItem]) async {
        guard let store else { return }
        await store.upload(items, path: paths.upload)
        await refresh()
    }

    func delete(_ p: RemoteFile) async -> Bool {
        do {
            try await api.send(paths.del(p.name), method: "DELETE")
            await refresh()
            return true
        } catch {
            store?.toast((error as? APIError)?.errorDescription ?? "Could not delete.")
            return false
        }
    }

    // MARK: Albums

    @discardableResult
    func createAlbum(name: String, add: [String] = []) async -> String? {
        do {
            let id = try await api.albumPost(space: space, id: nil, body: ["name": name, "add": add])
            await refresh()
            return id
        } catch {
            store?.toast((error as? APIError)?.errorDescription ?? "Something went wrong")
            return nil
        }
    }

    @discardableResult
    func updateAlbum(_ id: String, name: String? = nil, add: [String] = [], remove: [String] = []) async -> Bool {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if !add.isEmpty { body["add"] = add }
        if !remove.isEmpty { body["remove"] = remove }
        do {
            _ = try await api.albumPost(space: space, id: id, body: body)
            await refresh()
            return true
        } catch {
            store?.toast((error as? APIError)?.errorDescription ?? "Something went wrong")
            return false
        }
    }

    func deleteAlbum(_ id: String) async {
        try? await api.albumDelete(space: space, id: id)
        await refresh()
    }

    // MARK: Viewer

    func context(items: [RemoteFile], start: Int, album: Album?) -> ViewerContext {
        ViewerContext(
            items: items, start: start,
            srcURL: { [weak self] p in self?.fullURL(p) },
            thumbURL: { [weak self] p in self?.thumbURL(p) },
            meta: { [weak self] p in self?.metaOf(p) },
            deleteTitle: { p in
                if let album { return "Remove \(p.name) from “\(album.name)”? The photo stays in your library." }
                return "Delete \(p.name)?"
            },
            onDelete: { [weak self] p in
                guard let self else { return false }
                if let album { return await self.updateAlbum(album.id, remove: [p.name]) }
                return await self.delete(p)
            })
    }
}
