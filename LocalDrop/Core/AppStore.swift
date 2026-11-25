import SwiftUI
import UIKit

enum AppTab: Hashable { case files, photos, airdrop, priv, shared }

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Everything that can be presented as a sheet from the root view.
enum ActiveSheet: Identifiable {
    case settings, cookie
    case incoming(Transfer)
    case invite(Invite)
    case share(ShareItem)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .cookie: return "cookie"
        case .incoming(let t): return "in-" + t.id
        case .invite(let i): return "inv-" + i.id
        case .share(let s): return "share-" + s.id.uuidString
        }
    }
}

enum IncomingAction { case download, exclusive, cloud, ignore }

@MainActor
final class AppStore: ObservableObject {
    let settings: AppSettings
    let api = APIClient()
    let photos: PhotosModel

    @Published var tab: AppTab = .files
    @Published var sheet: ActiveSheet?
    @Published var isConnected = true
    @Published var myIP = ""
    @Published var serverCookie: String?
    @Published var devices: [Device] = []
    @Published var folders: [SharedFolder] = []
    @Published var toastText: String?
    /// Bumped whenever the server or Cookie ID changes so every screen reloads.
    @Published var generation = 0

    private var pollTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var handledTransfers = Set<String>()
    private var handledInvites = Set<String>()
    private var seenOutgoing: [String: String] = [:]
    private var seenResults = Set<String>()

    init(settings: AppSettings) {
        self.settings = settings
        self.photos = PhotosModel(api: api)
        photos.store = self
        ImageLoader.shared.api = api
        applyConfig()
    }

    var deviceType: String { UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone" }
    var myLibrary: SharedFolder? { folders.first { $0.photos && $0.owner } }
    var hasServer: Bool { !settings.serverAddress.isEmpty }

    // MARK: Configuration

    /// "192.168.1.20:8000", "http://pc.local:8000" ... -> base URL. A bare host gets server.py's default port 8000.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let hadScheme = s.contains("://")
        if !hadScheme { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
        if !hadScheme && c.port == nil { c.port = 8000 }
        c.path = ""
        c.query = nil
        return c.url
    }

    func applyConfig() {
        api.baseURL = AppStore.normalize(settings.serverAddress)
        api.cookieID = settings.cookieID
    }

    /// First-run / Settings: test the address, then save it. Returns an error message or nil on success.
    func connect(address: String, cookie: String? = nil) async -> String? {
        guard let url = AppStore.normalize(address) else { return "Enter an address like 192.168.1.20:8000" }
        var newCookie: String?
        if let c = cookie, !c.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let n = AppSettings.normalizeCookie(c) else { return "A Cookie ID is exactly 32 characters (0-9, a-f)." }
            newCookie = n
        }
        let oldBase = api.baseURL, oldCookie = api.cookieID
        api.baseURL = url
        if let n = newCookie { api.cookieID = n }
        do {
            let j = try await api.poll(name: settings.deviceName, type: deviceType)
            if let n = newCookie { settings.setCookie(n) }
            settings.serverAddress = url.absoluteString
            applyConfig()
            ImageLoader.shared.clear(); api.clearCaches()
            photos.reset(); folders = []
            myIP = j.you; isConnected = true; generation += 1
            startPolling()
            return nil
        } catch {
            api.baseURL = oldBase; api.cookieID = oldCookie
            return "Couldn't reach the server. Check the address, that server.py is running, that this device is on the same Wi-Fi, and that Local Network access is allowed for LocalDrop in Settings → Privacy & Security."
        }
    }

    func disconnect() {
        stopPolling()
        settings.serverAddress = ""
        api.baseURL = nil
        photos.reset(); folders = []; devices = []; isConnected = true
    }

    /// Move this app onto another Cookie ID (e.g. the one from the web version) and describe what the server holds for it.
    func changeCookie(to id: String) async -> String {
        settings.setCookie(id)
        api.cookieID = id
        ImageLoader.shared.clear(); api.clearCaches()
        photos.reset(); folders = []
        generation += 1
        await poll()
        let files = (try? await api.listPrivate(mode: "cookie")) ?? []
        await refreshFolders()
        var parts: [String] = []
        parts.append("\(files.count) private file\(files.count == 1 ? "" : "s")")
        if let lib = myLibrary { parts.append("a private photo library with \(lib.count) item\(lib.count == 1 ? "" : "s")") }
        let shared = folders.filter { !$0.photos }.count
        if shared > 0 { parts.append("\(shared) shared folder\(shared == 1 ? "" : "s")") }
        let found = files.isEmpty && myLibrary == nil && shared == 0
        let ok = serverCookie == nil || serverCookie == id
        if !ok { return "The server did not accept that ID. Try again." }
        return found ? "Switched. Nothing is stored under this ID yet." : "Switched. Found " + parts.joined(separator: ", ") + "."
    }

    // MARK: Polling (2 s, like setInterval(poll, 2000) in the web version)

    func scenePhaseChanged(_ p: ScenePhase) {
        if p == .active { if hasServer { startPolling() } } else { stopPolling() }
    }

    func startPolling() {
        guard pollTask == nil, hasServer else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func poll() async {
        guard api.baseURL != nil else { return }
        do {
            let name = settings.deviceName.trimmingCharacters(in: .whitespaces)
            let j = try await api.poll(name: name.isEmpty ? "Device" : String(name.prefix(32)), type: deviceType)
            isConnected = true
            myIP = j.you
            serverCookie = j.cookie
            let list = j.devices.filter { $0.ip != j.you }
            if list != devices { devices = list }

            let labels = ["ignored": "was ignored", "downloaded": "was downloaded", "cloud": "was stored in the cloud",
                          "private": "was saved with their exclusive ID"]
            for t in j.outgoing {
                guard let l = labels[t.status], seenOutgoing[t.id] != t.status else { continue }
                seenOutgoing[t.id] = t.status
                toast("\(t.name) \(l)")
            }
            updateIncoming(j.incoming)
            handleInvites(j)
        } catch {
            isConnected = false
        }
    }

    private var interruptible: Bool {
        guard let s = sheet else { return true }
        switch s {
        case .settings, .cookie: return true
        default: return false
        }
    }

    private func updateIncoming(_ list: [Transfer]) {
        if let t = list.first(where: { !handledTransfers.contains($0.id) }) {
            if case .incoming(let c)? = sheet, c.id == t.id { return }
            if interruptible { sheet = .incoming(t) }
        } else if case .incoming? = sheet {
            sheet = nil
        }
    }

    private func handleInvites(_ j: PollResponse) {
        for r in j.inviteResults where !seenResults.contains(r.id) {
            seenResults.insert(r.id)
            toast(r.toName + (r.status == "accepted" ? " accepted your share request" : " declined your share request"))
            if r.status == "accepted" { Task { await refreshFolders(); await photos.refresh() } }
        }
        if let i = j.invites.first(where: { !handledInvites.contains($0.id) }) {
            if case .invite(let c)? = sheet, c.id == i.id { return }
            if interruptible { sheet = .invite(i) }
        } else if case .invite? = sheet {
            sheet = nil
        }
    }

    // MARK: AirDrop actions

    func handleIncoming(_ t: Transfer, _ action: IncomingAction) async {
        handledTransfers.insert(t.id)
        sheet = nil
        switch action {
        case .download:
            toast("Downloading \(t.name)…")
            if let u = api.url("/api/airdrop/\(t.id)/download") {
                do { share(try await api.download(url: u, filename: t.name)) }
                catch { toast("Could not download \(t.name).") }
            }
        case .exclusive:
            do {
                try await api.airdropAction(id: t.id, action: "private", mode: settings.privateMode)
                toast("Saved with your exclusive ID"); generation += 1
            } catch { toast("Could not complete that action.") }
        case .cloud:
            do {
                try await api.airdropAction(id: t.id, action: "cloud", mode: settings.privateMode)
                toast("Stored in cloud"); generation += 1
            } catch { toast("Could not complete that action.") }
        case .ignore:
            do { try await api.airdropAction(id: t.id, action: "ignore", mode: settings.privateMode); toast("Ignored") }
            catch { toast("Could not complete that action.") }
        }
    }

    func sendAirDrop(_ items: [UploadItem], to device: Device) async {
        for it in items {
            let scoped = it.scoped && it.url.startAccessingSecurityScopedResource()
            defer {
                if scoped { it.url.stopAccessingSecurityScopedResource() }
                if it.temp { try? FileManager.default.removeItem(at: it.url.deletingLastPathComponent()) }
            }
            toast("Sending \(it.name)…")
            do {
                try await api.upload(path: "/api/airdrop", file: it.url, filename: it.name, headers: ["X-Target": device.ip]) { [weak self] p in
                    Task { @MainActor in self?.toast("Sending \(it.name) — \(Int(p * 100))%") }
                }
                toast("Sent \(it.name). Waiting for them to respond.")
            } catch {
                toast("Could not send \(it.name). Is the device still online?")
            }
        }
    }

    // MARK: Shared folders / invites

    func refreshFolders() async {
        if let f = try? await api.listFolders() { folders = f }
    }

    func respond(to invite: Invite, accept: Bool) async {
        handledInvites.insert(invite.id)
        sheet = nil
        do {
            try await api.respond(invite: invite.id, accept: accept)
            if accept { toast("Access added"); await refreshFolders(); await photos.refresh(); generation += 1 }
        } catch { toast((error as? APIError)?.errorDescription ?? "Something went wrong") }
    }

    func sendInvite(folder: String, device: Device, mode: String) async {
        do {
            try await api.invite(folder: folder, toIP: device.ip, mode: mode)
            toast("Request sent to \(device.name). Waiting for them to accept.")
        } catch { toast((error as? APIError)?.errorDescription ?? "Something went wrong") }
    }

    func removeMember(folder: String, index: Int) async {
        do { try await api.removeMember(folder: folder, index: index); await refreshFolders(); await photos.refresh() }
        catch { toast((error as? APIError)?.errorDescription ?? "Something went wrong") }
    }

    // MARK: Uploads (progress shown as a toast, like the web version)

    @discardableResult
    func upload(_ items: [UploadItem], path: String, verb: String = "Uploading") async -> Int {
        var ok = 0
        for it in items {
            let scoped = it.scoped && it.url.startAccessingSecurityScopedResource()
            defer {
                if scoped { it.url.stopAccessingSecurityScopedResource() }
                if it.temp { try? FileManager.default.removeItem(at: it.url.deletingLastPathComponent()) }
            }
            toast("\(verb) \(it.name)…")
            do {
                try await api.upload(path: path, file: it.url, filename: it.name) { [weak self] p in
                    Task { @MainActor in
                        self?.toast(p >= 1 ? "Processing \(it.name)…" : "\(verb) \(it.name) — \(Int(p * 100))%")
                    }
                }
                ok += 1
            } catch {
                toast("Failed: \(it.name) — \((error as? APIError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        if ok > 0 { toast(items.count == 1 ? "Upload complete" : "Upload finished") }
        return ok
    }

    // MARK: Downloads

    func share(_ url: URL) { sheet = .share(ShareItem(url: url)) }

    /// Downloads a server file into a temp folder. Used by Share, Quick Look and "Download".
    func fetchLocal(_ url: URL?, name: String) async -> URL? {
        guard let url else { return nil }
        toast("Downloading \(name)…")
        do {
            let u = try await api.download(url: url, filename: name)
            toastText = nil
            return u
        } catch {
            toast("Could not download \(name).")
            return nil
        }
    }

    // MARK: Toast

    func toast(_ text: String) {
        toastText = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { self?.toastText = nil }
        }
    }
}
