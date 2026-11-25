import SwiftUI

// MARK: - Grid (day sections, selection, zoom transition into the viewer)

struct MediaGrid: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var model: PhotosModel
    let items: [RemoteFile]
    var grouped = true
    var album: Album? = nil
    @Binding var selecting: Bool
    @Binding var selection: Set<String>
    @Namespace private var ns
    @State private var session: ViewerSession?

    private var days: [(day: String, items: [RemoteFile])] {
        let g = Dictionary(grouping: items) { $0.day }
        return g.keys.sorted(by: >).map { (day: $0, items: g[$0] ?? []) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if grouped {
                ForEach(days, id: \.day) { d in
                    Text(DateFmt.dayLabel(d.day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 16).padding(.bottom, 6).padding(.horizontal, 4)
                    grid(d.items)
                }
            } else {
                grid(items)
            }
        }
        .fullScreenCover(item: $session) { s in MediaViewer(ctx: s.ctx, ns: ns) }
    }

    private func grid(_ list: [RemoteFile]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 2)], spacing: 2) {
            ForEach(list) { p in
                Button { tap(p) } label: { tile(p) }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: p.id, in: ns)
            }
        }
    }

    private func tile(_ p: RemoteFile) -> some View {
        let isSel = selection.contains(p.name)
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteThumb(url: model.thumbURL(p), isVideo: p.isVideo).scaleEffect(isSel ? 0.86 : 1) }
            .clipShape(RoundedRectangle(cornerRadius: isSel ? 10 : 4))
            .overlay(alignment: .topTrailing) {
                if p.isVideo {
                    Image(systemName: "video.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if settings.showDates {
                    Text(DateFmt.format(model.metaOf(p).t, short: true))
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 7)).padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if selecting {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(isSel ? Color.white : Color.white.opacity(0.9))
                        .shadow(radius: 2).padding(6)
                }
            }
            .animation(.spring(duration: 0.25), value: isSel)
            .contentShape(Rectangle())
    }

    private func tap(_ p: RemoteFile) {
        if selecting {
            if selection.contains(p.name) { selection.remove(p.name) } else { selection.insert(p.name) }
            return
        }
        session = ViewerSession(ctx: model.context(items: items, start: items.firstIndex(of: p) ?? 0, album: album))
    }
}

// MARK: - Photos tab

private enum PhotoMode: String { case library, albums }

struct PhotosView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var model: PhotosModel
    @State private var mode: PhotoMode = .library
    @State private var path: [String] = []
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var pickAlbum = false
    @State private var newAlbum = false
    @State private var albumName = ""

    private var mine: SharedFolder? { store.myLibrary }
    private var others: [SharedFolder] { store.folders.filter { $0.photos && !$0.owner } }
    private var hasMembers: Bool { !(mine?.members ?? []).isEmpty }
    private var current: SharedFolder? { store.folders.first { $0.id == model.space } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenHeader(subtitle: "Shared is open to everyone on the network. Only You is private, and you can add people to it.",
                                 badge: "Library", badgeIcon: "photo")
                    spaceChips
                    Picker("View", selection: $mode) {
                        Label("Library", systemImage: "photo").tag(PhotoMode.library)
                        Label("Albums", systemImage: "rectangle.stack").tag(PhotoMode.albums)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in exitSelection() }

                    if mode == .library { library } else { albumsGrid }
                    spaceInfo
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 40)
            }
            .background(AppBackground())
            .navigationTitle("Photos")
            .toolbar { toolbar }
            .refreshable { await model.refresh() }
            .task(id: store.generation) { await model.refresh() }
            .navigationDestination(for: String.self) { id in AlbumDetailView(model: model, albumID: id) }
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .sheet(isPresented: $pickAlbum) {
                AlbumPickerSheet(model: model, names: Array(selection)) { exitSelection() }
            }
            .alert("New album", isPresented: $newAlbum) {
                TextField("Album name…", text: $albumName)
                Button("Create") { createAlbum() }
                Button("Cancel", role: .cancel) {}
            }
            .uploadPickers(showFiles: $showFiles, showPhotos: $showPhotos) { items in
                Task { await model.upload(items) }
            }
        }
    }

    // MARK: pieces

    private var spaceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassChip(title: "Shared", icon: "cloud", selected: model.space == "shared") { select("shared") }
                    GlassChip(title: hasMembers ? "Only Members" : "Only You", icon: hasMembers ? "shield" : "lock",
                              selected: mine != nil && model.space == mine?.id) { select("mine") }
                    ForEach(others) { f in
                        GlassChip(title: f.name, icon: "person.badge.key", selected: model.space == f.id) { select(f.id) }
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    private func select(_ v: String) {
        exitSelection()
        path = []
        Task { await model.setSpace(v) }
    }

    @ViewBuilder private var library: some View {
        if model.photos.isEmpty {
            ContentUnavailableView(model.loaded ? "No photos or videos here yet" : "Loading…",
                                   systemImage: "photo.on.rectangle",
                                   description: Text(model.loaded ? "Use + to add photos and videos." : ""))
                .padding(.top, 30)
        } else {
            MediaGrid(model: model, items: model.photos, selecting: $selecting, selection: $selection)
        }
    }

    @ViewBuilder private var albumsGrid: some View {
        if model.albums.isEmpty {
            ContentUnavailableView("No albums yet", systemImage: "rectangle.stack",
                                   description: Text("Tap “New album”, or use Select in the Library to build one from photos."))
                .padding(.top, 30)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                ForEach(model.albums) { a in
                    NavigationLink(value: a.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    if let c = model.photos.first(where: { $0.name == a.items.first }) {
                                        RemoteThumb(url: model.thumbURL(c), isVideo: c.isVideo)
                                    } else {
                                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.ultraThinMaterial)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            Text(a.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("\(a.items.count) item\(a.items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var spaceInfo: some View {
        if model.space == "shared" {
            Text("Everyone on this network can see and add to these photos.").font(.footnote).foregroundStyle(.secondary).padding(.top, 14)
        } else if let c = current, c.owner {
            MembersSection(folder: c).padding(.top, 14)
        } else if current != nil {
            Text("Shared with you by its owner. They can remove your access at any time.").font(.footnote).foregroundStyle(.secondary).padding(.top, 14)
        }
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selection.count) selected").font(.subheadline.weight(.semibold))
            Spacer()
            Button("Add to album…") { pickAlbum = true }.buttonStyle(.lgProminent).disabled(selection.isEmpty)
            Button("Cancel") { exitSelection() }.buttonStyle(.lg)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        SettingsButton(store: store)
        ToolbarItem(placement: .topBarTrailing) {
            if mode == .albums {
                Button { albumName = ""; newAlbum = true } label: { Label("New album", systemImage: "rectangle.stack.badge.plus") }
            } else if !selecting {
                Menu {
                    Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                } label: { Image(systemName: "plus") }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if mode == .library && !model.photos.isEmpty {
                Button(selecting ? "Done" : "Select") {
                    if selecting { exitSelection() } else { selecting = true }
                }
            }
        }
    }

    private func exitSelection() { selecting = false; selection = [] }

    private func createAlbum() {
        let n = albumName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task { if let id = await model.createAlbum(name: n) { path = [id] } }
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @ObservedObject var model: PhotosModel
    let albumID: String
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var rename = false
    @State private var name = ""
    @State private var confirmDelete = false

    private var album: Album? { model.albums.first { $0.id == albumID } }
    private var items: [RemoteFile] {
        guard let a = album else { return [] }
        let set = Set(a.items)
        return model.photos.filter { set.contains($0.name) }
    }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("This album is empty", systemImage: "photo.on.rectangle",
                                       description: Text("Use “Add photos” to fill it.")).padding(.top, 40)
            } else {
                MediaGrid(model: model, items: items, grouped: false, album: album,
                          selecting: .constant(false), selection: .constant([]))
                    .padding(.horizontal, 12)
            }
        }
        .background(AppBackground())
        .navigationTitle(album?.name ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAdd = true } label: { Label("Add photos", systemImage: "plus") }
                    Button { name = album?.name ?? ""; rename = true } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete album", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .sheet(isPresented: $showAdd) { if let a = album { AddPhotosSheet(model: model, album: a) } }
        .alert("Rename album", isPresented: $rename) {
            TextField("Album name…", text: $name)
            Button("Save") {
                let n = name.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { Task { await model.updateAlbum(albumID, name: n) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the album “\(album?.name ?? "")”? The photos stay in your library.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete album", role: .destructive) { Task { await model.deleteAlbum(albumID); dismiss() } }
        }
    }
}

/// Pick photos that are not in the album yet.
struct AddPhotosSheet: View {
    @ObservedObject var model: PhotosModel
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()

    private var candidates: [RemoteFile] { model.photos.filter { !album.items.contains($0.name) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if candidates.isEmpty {
                    ContentUnavailableView("Nothing to add", systemImage: "checkmark.circle",
                                           description: Text("Every photo is already in this album.")).padding(.top, 40)
                } else {
                    MediaGrid(model: model, items: candidates, selecting: .constant(true), selection: $selection)
                        .padding(.horizontal, 12)
                }
            }
            .navigationTitle("Add to “\(album.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add\(selection.isEmpty ? "" : " (\(selection.count))")") {
                        let names = Array(selection)
                        Task { await model.updateAlbum(album.id, add: names); dismiss() }
                    }.disabled(selection.isEmpty)
                }
            }
        }
    }
}

/// "Add to album…" from Library selection: choose an album or create one.
struct AlbumPickerSheet: View {
    @ObservedObject var model: PhotosModel
    let names: [String]
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("\(names.count) item\(names.count == 1 ? "" : "s") selected") {
                    HStack {
                        TextField("…or create a new album", text: $newName)
                        Button("Create & add") {
                            let n = newName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            Task { await model.createAlbum(name: n, add: names); finish() }
                        }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Albums") {
                    ForEach(model.albums) { a in
                        Button {
                            Task { await model.updateAlbum(a.id, add: names); finish() }
                        } label: {
                            HStack { Text(a.name); Spacer(); Text("\(a.items.count)").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Add to album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func finish() { dismiss(); done() }
}
