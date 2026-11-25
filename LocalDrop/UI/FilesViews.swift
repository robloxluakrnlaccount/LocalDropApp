import SwiftUI
import QuickLook

// MARK: - Shared file-list behaviour (preview, download, delete) used by Files, Only me and shared folders

@MainActor
final class FileOps: ObservableObject {
    @Published var viewer: ViewerSession?
    @Published var quick: URL?
    @Published var pending: RemoteFile?
}

struct FileOpsPresenters: ViewModifier {
    @ObservedObject var ops: FileOps
    let onDelete: (RemoteFile) async -> Void

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $ops.viewer) { s in MediaViewer(ctx: s.ctx, ns: nil) }
            .quickLookPreview($ops.quick)
            .confirmationDialog("Delete this file?",
                                isPresented: Binding(get: { ops.pending != nil }, set: { if !$0 { ops.pending = nil } }),
                                titleVisibility: .visible, presenting: ops.pending) { f in
                Button("Delete", role: .destructive) { Task { await onDelete(f) } }
            } message: { f in
                Text(f.name)
            }
    }
}

extension View {
    func fileOps(_ ops: FileOps, onDelete: @escaping (RemoteFile) async -> Void) -> some View {
        modifier(FileOpsPresenters(ops: ops, onDelete: onDelete))
    }
}

struct FileRows: View {
    let files: [RemoteFile]
    /// Server path of a file, e.g. "/download/<name>".
    let path: (RemoteFile) -> String
    let ops: FileOps
    var icon = "doc"
    let onDelete: (RemoteFile) async -> Void
    @EnvironmentObject var store: AppStore

    var body: some View {
        ForEach(files) { f in
            Button { open(f) } label: { FileRow(file: f, icon: icon).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { ops.pending = f } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading) {
                    Button { Task { await download(f) } } label: { Label("Download", systemImage: "arrow.down.circle") }.tint(.blue)
                }
                .contextMenu {
                    Button { open(f) } label: { Label(f.isMedia ? "Preview" : "Open", systemImage: "eye") }
                    Button { Task { await download(f) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                    Button(role: .destructive) { ops.pending = f } label: { Label("Delete", systemImage: "trash") }
                }
                .rowGlass()
        }
    }

    private func full(_ f: RemoteFile) -> URL? { store.api.url(path(f)) }

    private func download(_ f: RemoteFile) async {
        if let u = await store.fetchLocal(full(f), name: f.name) { store.share(u) }
    }

    private func open(_ f: RemoteFile) {
        if f.isMedia {
            let media = files.filter { $0.isMedia }
            let api = store.api
            let p = path
            let del = onDelete
            ops.viewer = ViewerSession(ctx: ViewerContext(
                items: media, start: media.firstIndex(of: f) ?? 0,
                srcURL: { api.mediaURL(path: p($0), file: $0) },
                thumbURL: { api.thumbURL(path: p($0), file: $0) },
                meta: { _ in nil },
                deleteTitle: { "Delete \($0.name)?" },
                onDelete: { file in await del(file); return true }))
        } else {
            Task { if let u = await store.fetchLocal(full(f), name: f.name) { ops.quick = u } }
        }
    }
}

// MARK: - Files (the shared "cloud" folder on the PC)

struct FilesView: View {
    @EnvironmentObject var store: AppStore
    @State private var files: [RemoteFile] = []
    @State private var query = ""
    @State private var loading = true
    @State private var showFiles = false
    @State private var showPhotos = false
    @StateObject private var ops = FileOps()

    private var filtered: [RemoteFile] {
        query.isEmpty ? files : files.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScreenHeader(subtitle: "Transfer files between devices on your local Wi-Fi.", badge: "LAN only")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    UploadCard(title: "Upload files",
                               message: "Files are stored on the computer running the server and available to every device connected to it.",
                               showFiles: $showFiles, showPhotos: $showPhotos)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    if filtered.isEmpty {
                        Text(loading ? "Loading…" : "No files found.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20).rowGlass()
                    } else {
                        FileRows(files: filtered, path: { "/download/\(enc($0.name))" }, ops: ops, onDelete: delete)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Files")
            .toolbar { SettingsButton(store: store) }
            .searchable(text: $query, prompt: "Search files…")
            .refreshable { await load() }
            .task(id: store.generation) { await load() }
            .fileOps(ops, onDelete: delete)
            .uploadPickers(showFiles: $showFiles, showPhotos: $showPhotos) { items in
                Task { await store.upload(items, path: "/api/upload"); await load() }
            }
        }
    }

    private func load() async {
        do { files = try await store.api.listCloud() } catch { store.toast("Could not load files.") }
        loading = false
    }

    private func delete(_ f: RemoteFile) async {
        do { try await store.api.deleteCloud(f.name); await load() } catch { store.toast("Could not delete file.") }
    }
}

// MARK: - Only me (private by Cookie ID or by Local IP)

struct PrivateView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @State private var files: [RemoteFile] = []
    @State private var loading = true
    @State private var showFiles = false
    @State private var showPhotos = false
    @StateObject private var ops = FileOps()

    private var mode: String { settings.privateMode }
    private var isCookie: Bool { mode == "cookie" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScreenHeader(subtitle: isCookie
                                 ? "Files are tied to this app's Cookie ID. Only a device using the same ID can open them, whatever its IP. Change or copy the ID in Settings to move files between the web version and this app."
                                 : "Files are tied to this device's IP address. Only devices using this IP can open them. If your IP changes, you start with an empty space.",
                                 badge: isCookie ? "Cookie ID" : "Local IP",
                                 badgeIcon: isCookie ? "person.badge.key" : "wifi")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Picker("Identify me by", selection: $settings.privateMode) {
                        Label("Cookie ID", systemImage: "person.badge.key").tag("cookie")
                        Label("Local IP", systemImage: "wifi").tag("ip")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    UploadCard(title: "Add private files",
                               message: isCookie ? "Saved under this app's Cookie ID." : "Saved under your device's IP.",
                               showFiles: $showFiles, showPhotos: $showPhotos)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    if files.isEmpty {
                        Text(loading ? "Loading…" : "Nothing here yet. Add files above, or choose “Save with Exclusive ID” when someone AirDrops you a file.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 20).rowGlass()
                    } else {
                        FileRows(files: files, path: { "/private/\(mode)/\(enc($0.name))" }, ops: ops, icon: "lock.doc", onDelete: delete)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Only me")
            .toolbar { SettingsButton(store: store) }
            .refreshable { await load() }
            .task(id: "\(store.generation)-\(mode)") { loading = true; files = []; await load() }
            .fileOps(ops, onDelete: delete)
            .uploadPickers(showFiles: $showFiles, showPhotos: $showPhotos) { items in
                Task { await store.upload(items, path: "/api/private/\(mode)", verb: "Saving"); await load() }
            }
        }
    }

    private func load() async {
        do { files = try await store.api.listPrivate(mode: mode) } catch { store.toast("Could not load your private files.") }
        loading = false
    }

    private func delete(_ f: RemoteFile) async {
        do { try await store.api.deletePrivate(mode: mode, name: f.name); await load() } catch { store.toast("Could not delete file.") }
    }
}
