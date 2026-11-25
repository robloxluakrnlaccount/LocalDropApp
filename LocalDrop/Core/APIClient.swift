import Foundation

// MARK: - Errors

enum APIError: LocalizedError {
    case notConfigured
    case badURL
    case server(String)      // {"error": "..."} body from server.py
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No server address set."
        case .badURL: return "That address isn't valid."
        case .server(let m): return m
        case .http(let c): return "Server returned HTTP \(c)."
        case .network(let m): return m
        }
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters only (ASCII), the equivalent of JS encodeURIComponent for file names.
    static let ldUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .ldUnreserved) ?? s }

// MARK: - Client

/// Swift counterpart of server.py. The server identifies a device by its IP *and* by the `ld_id` cookie, so every request
/// carries a hand-built `Cookie: ld_id=<id>` header (URLSession's own cookie jar is disabled so nothing can override it).
final class APIClient: @unchecked Sendable {
    private let lock = NSLock()
    private var _base: URL?
    private var _cookie = ""
    let session: URLSession

    init() {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 600 * 1024 * 1024)
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    var baseURL: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _base }
        set { lock.lock(); _base = newValue; lock.unlock() }
    }

    var cookieID: String {
        get { lock.lock(); defer { lock.unlock() }; return _cookie }
        set { lock.lock(); _cookie = newValue; lock.unlock() }
    }

    func clearCaches() { session.configuration.urlCache?.removeAllCachedResponses() }

    /// Headers needed by things that bypass URLSession (AVPlayer).
    var authHeaders: [String: String] {
        let c = cookieID
        return c.isEmpty ? [:] : ["Cookie": "ld_id=\(c)"]
    }

    // MARK: URL + request building

    func url(_ path: String, query: [(String, String)] = []) -> URL? {
        guard let base = baseURL else { return nil }
        var s = base.absoluteString + path
        if !query.isEmpty {
            s += "?" + query.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&")
        }
        return URL(string: s)
    }

    func request(_ path: String, query: [(String, String)] = [], method: String = "GET", timeout: TimeInterval = 30) throws -> URLRequest {
        guard baseURL != nil else { throw APIError.notConfigured }
        guard let u = url(path, query: query) else { throw APIError.badURL }
        return authorized(URLRequest(url: u, timeoutInterval: timeout), method: method)
    }

    func authorized(_ r: URLRequest, method: String = "GET") -> URLRequest {
        var req = r
        req.httpMethod = method
        let c = cookieID
        if !c.isEmpty { req.setValue("ld_id=\(c)", forHTTPHeaderField: "Cookie") }
        return req
    }

    // MARK: Core calls

    private func check(_ data: Data, _ resp: URLResponse) throws {
        guard let h = resp as? HTTPURLResponse else { throw APIError.network("Bad response") }
        if !(200..<300).contains(h.statusCode) {
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let m = o["error"] as? String {
                throw APIError.server(m)
            }
            throw APIError.http(h.statusCode)
        }
    }

    private func wrap<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch let e as APIError { throw e }
        catch let e as URLError where e.code == .cancelled { throw e }
        catch { throw APIError.network(error.localizedDescription) }
    }

    @discardableResult
    func send(_ path: String, method: String = "GET", query: [(String, String)] = [], json: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var req = try request(path, query: query, method: method, timeout: timeout)
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await wrap {
            let (d, r) = try await self.session.data(for: req)
            try self.check(d, r)
            return d
        }
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [(String, String)] = [], timeout: TimeInterval = 30) async throws -> T {
        let d = try await send(path, query: query, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: d) }
        catch { throw APIError.network("Unexpected reply from the server.") }
    }

    /// Raw bytes for an absolute URL built by `url(...)` (thumbnails, full images).
    func rawData(url: URL) async throws -> Data {
        let req = authorized(URLRequest(url: url, timeoutInterval: 60))
        return try await wrap {
            let (d, r) = try await self.session.data(for: req)
            try self.check(d, r)
            return d
        }
    }

    /// POST the raw file body with an X-Filename header, exactly like the web version's XMLHttpRequest uploads.
    func upload(path: String, file: URL, filename: String, headers: [String: String] = [:],
                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var req = try request(path, method: "POST", timeout: 3600)
        req.setValue(enc(filename), forHTTPHeaderField: "X-Filename")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let delegate = UploadProgress(progress)
        try await wrap {
            let (d, r) = try await self.session.upload(for: req, fromFile: file, delegate: delegate)
            try self.check(d, r)
        }
    }

    /// Downloads to a temp folder (keeping the real file name) so it can be shared, previewed or saved.
    func download(url: URL, filename: String) async throws -> URL {
        var req = authorized(URLRequest(url: url, timeoutInterval: 3600))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return try await wrap {
            let (tmp, resp) = try await self.session.download(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                try? FileManager.default.removeItem(at: tmp)
                throw APIError.http(h.statusCode)
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let dest = dir.appendingPathComponent(safe.isEmpty ? "file" : safe)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let cb: (@Sendable (Double) -> Void)?
    init(_ cb: (@Sendable (Double) -> Void)?) { self.cb = cb }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        cb?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - Where a photo space lives on the server

/// "shared" is the open library; any other id is a private/shared photo folder (see shared_route in server.py).
struct SpacePaths {
    let space: String
    var isShared: Bool { space == "shared" }
    var list: String { isShared ? "/api/photos" : "/api/shared/\(space)/files" }
    var upload: String { list }
    func src(_ n: String) -> String { isShared ? "/photos/\(enc(n))" : "/shared/\(space)/\(enc(n))" }
    func del(_ n: String) -> String { isShared ? "/api/photos/\(enc(n))" : "/api/shared/\(space)/files/\(enc(n))" }
    var albums: String { "/api/albums/\(space)" }
    var meta: String { "/api/meta/\(space)" }
}

// MARK: - Endpoints (one function per route in server.py)

extension APIClient {
    // /api/poll
    func poll(name: String, type: String) async throws -> PollResponse {
        try await get(PollResponse.self, "/api/poll", query: [("type", type), ("name", name)], timeout: 5)
    }

    // /api/files, /api/upload, /download/<name>
    func listCloud() async throws -> [RemoteFile] { try await get(FilesResponse.self, "/api/files").files }
    func deleteCloud(_ name: String) async throws { try await send("/api/files/\(enc(name))", method: "DELETE") }
    func cloudURL(_ name: String, thumb: Bool = false) -> URL? {
        url("/download/\(enc(name))", query: thumb ? [("inline", "1"), ("thumb", "1")] : [])
    }

    // /api/private?mode=, /api/private/<mode>, /private/<mode>/<name>
    func listPrivate(mode: String) async throws -> [RemoteFile] {
        try await get(FilesResponse.self, "/api/private", query: [("mode", mode)]).files
    }
    func deletePrivate(mode: String, name: String) async throws { try await send("/api/private/\(mode)/\(enc(name))", method: "DELETE") }

    // /api/airdrop/<id>/action
    func airdropAction(id: String, action: String, mode: String) async throws {
        try await send("/api/airdrop/\(id)/action", method: "POST", json: ["action": action, "mode": mode])
    }

    // /api/shared ...
    func listFolders() async throws -> [SharedFolder] { try await get(FoldersResponse.self, "/api/shared").folders }
    func createFolder(name: String) async throws { try await send("/api/shared", method: "POST", json: ["name": name]) }
    func deleteFolder(id: String) async throws { try await send("/api/shared/\(id)", method: "DELETE") }
    func listFolderFiles(id: String) async throws -> [RemoteFile] { try await get(FilesResponse.self, "/api/shared/\(id)/files").files }
    func deleteFolderFile(id: String, name: String) async throws { try await send("/api/shared/\(id)/files/\(enc(name))", method: "DELETE") }
    func invite(folder: String, toIP: String, mode: String) async throws {
        try await send("/api/shared/\(folder)/invite", method: "POST", json: ["to_ip": toIP, "mode": mode])
    }
    func removeMember(folder: String, index: Int) async throws { try await send("/api/shared/\(folder)/members/\(index)", method: "DELETE") }
    func respond(invite: String, accept: Bool) async throws { try await send("/api/invites/\(invite)/\(accept ? "accept" : "decline")", method: "POST") }

    // /api/photos/mine  (get-or-create this identity's private photo library)
    func createMyLibrary(name: String) async throws -> String? {
        let d = try await send("/api/photos/mine", method: "POST", json: ["name": name])
        return (try? JSONDecoder().decode(IDResponse.self, from: d))?.id
    }

    // /api/albums/<space>[/<id>], /api/meta/<space>
    func albums(space: String) async throws -> [Album] { try await get(AlbumsResponse.self, SpacePaths(space: space).albums).albums }
    func albumPost(space: String, id: String?, body: [String: Any]) async throws -> String? {
        let p = SpacePaths(space: space).albums + (id.map { "/\($0)" } ?? "")
        let d = try await send(p, method: "POST", json: body)
        return (try? JSONDecoder().decode(IDResponse.self, from: d))?.id
    }
    func albumDelete(space: String, id: String) async throws { try await send(SpacePaths(space: space).albums + "/\(id)", method: "DELETE") }
    func meta(space: String) async throws -> [String: MediaMeta] { try await get(MetaResponse.self, SpacePaths(space: space).meta).meta }

    /// Full-size URL for a media file. Videos AVPlayer can't decode ask the server for its MP4 transcode (?inline=1).
    func mediaURL(path: String, file: RemoteFile) -> URL? {
        let needsTranscode = file.isVideo && !MediaKind.playsNatively(file.name)
        return url(path, query: needsTranscode ? [("inline", "1")] : [])
    }

    /// Small cached JPEG for grids (?thumb=1&inline=1), versioned by modification time like the web version.
    func thumbURL(path: String, file: RemoteFile) -> URL? {
        url(path, query: [("inline", "1"), ("thumb", "1"), ("v", file.modified)])
    }
}
