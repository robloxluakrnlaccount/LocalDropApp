import SwiftUI
import UIKit

// MARK: - AirDrop

struct AirDropView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @State private var target: Device?
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var sending: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ScreenHeader(subtitle: "Pick a device on this network to send a file straight to it. They choose what happens to it.",
                                 badge: "Live")
                    HStack(spacing: 8) {
                        Text("You are").foregroundStyle(.secondary)
                        Text(store.myIP.isEmpty ? "…" : store.myIP).font(.system(.body, design: .monospaced))
                        Text("as").foregroundStyle(.secondary)
                        TextField("Device name", text: $settings.deviceName)
                            .submitLabel(.done)
                            .onSubmit { Task { await store.poll() } }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .font(.subheadline)

                    RadarView().padding(.vertical, 6)

                    if store.devices.isEmpty {
                        Text("No other devices online. Open LocalDrop on another device on this Wi-Fi.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.vertical, 24)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(store.devices) { d in
                                Menu {
                                    Button { target = d; showPhotos = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
                                    Button { target = d; showFiles = true } label: { Label("Files", systemImage: "folder") }
                                } label: {
                                    DeviceCard(device: d, sending: sending.contains(d.ip))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppBackground())
            .navigationTitle("AirDrop")
            .toolbar { SettingsButton(store: store) }
            .uploadPickers(showFiles: $showFiles, showPhotos: $showPhotos) { items in
                guard let d = target else { return }
                Task {
                    sending.insert(d.ip)
                    await store.sendAirDrop(items, to: d)
                    sending.remove(d.ip)
                }
            }
        }
    }
}

// MARK: - Shared folders

struct SharedView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @State private var newName = ""
    @State private var ckShown = false

    private var folders: [SharedFolder] { store.folders.filter { !$0.photos } }
    private var maskedCookie: String { ckShown ? settings.cookieID : "••••••••••••" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScreenHeader(subtitle: "Share a folder with specific devices by Cookie ID, Local IP, or both (both means the device must match both).",
                                 badge: "Members only", badgeIcon: "shield")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section("Your identity") {
                    HStack {
                        Text("Local IP").foregroundStyle(.secondary)
                        Spacer()
                        Text(store.myIP.isEmpty ? "…" : store.myIP).font(.system(.body, design: .monospaced))
                        Button { copy(store.myIP) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    }.rowGlass()
                    HStack {
                        Text("Cookie ID").foregroundStyle(.secondary)
                        Spacer()
                        Text(maskedCookie).font(.system(.footnote, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                        Button { ckShown.toggle() } label: { Image(systemName: ckShown ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                        Button { copy(settings.cookieID) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    }.rowGlass()
                    Button { store.sheet = .cookie } label: { Label("Use a different Cookie ID…", systemImage: "person.badge.key") }.rowGlass()
                }
                Section("New folder") {
                    HStack {
                        TextField("New shared folder name…", text: $newName)
                        Button("Create") { create() }.buttonStyle(.lgProminent).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }.rowGlass()
                }
                Section("Folders") {
                    if folders.isEmpty {
                        Text("No shared folders yet. Create one above.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16).rowGlass()
                    } else {
                        ForEach(folders) { f in
                            NavigationLink(value: f.id) {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.name).font(.body.weight(.semibold))
                                        Text("\(f.owner ? "Owned by you" : "Shared with you") · \(f.count) file\(f.count == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.rowGlass()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Shared")
            .toolbar { SettingsButton(store: store) }
            .navigationDestination(for: String.self) { id in FolderDetailView(folderID: id) }
            .refreshable { await store.refreshFolders() }
            .task(id: store.generation) { await store.refreshFolders() }
        }
    }

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
        store.toast("Copied")
    }

    private func create() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            do { try await store.api.createFolder(name: n); newName = ""; await store.refreshFolders() }
            catch { store.toast((error as? APIError)?.errorDescription ?? "Something went wrong") }
        }
    }
}

struct FolderDetailView: View {
    let folderID: String
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var files: [RemoteFile] = []
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var confirmFolder = false
    @StateObject private var ops = FileOps()

    private var folder: SharedFolder? { store.folders.first { $0.id == folderID } }

    var body: some View {
        List {
            Section {
                UploadCard(title: "Add files to share",
                           message: "Everyone with access can add, download and delete files here.",
                           showFiles: $showFiles, showPhotos: $showPhotos)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section {
                if files.isEmpty {
                    Text("Empty folder.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16).rowGlass()
                } else {
                    FileRows(files: files, path: { "/shared/\(folderID)/\(enc($0.name))" }, ops: ops, onDelete: delete)
                }
            }
            if let f = folder, f.owner {
                Section { MembersSection(folder: f).listRowBackground(Color.clear).listRowSeparator(.hidden) }
                Section {
                    Button("Delete folder", role: .destructive) { confirmFolder = true }.rowGlass()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(folder?.name ?? "Folder")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .fileOps(ops, onDelete: delete)
        .confirmationDialog("Delete this folder and all its files?", isPresented: $confirmFolder, titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                Task {
                    if (try? await store.api.deleteFolder(id: folderID)) != nil { await store.refreshFolders(); dismiss() }
                    else { store.toast("Something went wrong") }
                }
            }
        }
        .uploadPickers(showFiles: $showFiles, showPhotos: $showPhotos) { items in
            Task { await store.upload(items, path: "/api/shared/\(folderID)/files"); await load(); await store.refreshFolders() }
        }
    }

    private func load() async {
        files = (try? await store.api.listFolderFiles(id: folderID)) ?? files
    }

    private func delete(_ f: RemoteFile) async {
        do { try await store.api.deleteFolderFile(id: folderID, name: f.name); await load(); await store.refreshFolders() }
        catch { store.toast("Could not delete file.") }
    }
}

// MARK: - "Who has access" + invite a device (used for shared folders and the private photo library)

struct MembersSection: View {
    let folder: SharedFolder
    @EnvironmentObject var store: AppStore
    @State private var mode = "both"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who has access").font(.headline)
            let members = folder.members ?? []
            if members.isEmpty {
                Text("Only you. Pick a device below to share.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(members.enumerated()), id: \.offset) { i, m in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name ?? m.ip ?? "Device").font(.body.weight(.semibold))
                            Text(m.kind + (m.ip.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { Task { await store.removeMember(folder: folder.id, index: i) } }
                            .buttonStyle(.lgDanger).font(.footnote)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }

            Text("Share with an active device. They get a request and must accept. Identify them by:")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
            Picker("Identify by", selection: $mode) {
                Text("Cookie ID").tag("cookie")
                Text("Local IP").tag("ip")
                Text("Both").tag("both")
            }
            .pickerStyle(.segmented)

            if store.devices.isEmpty {
                Text("No other devices online right now.").font(.footnote).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    ForEach(store.devices) { d in
                        Button { Task { await store.sendInvite(folder: folder.id, device: d, mode: mode) } } label: { DeviceCard(device: d) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
