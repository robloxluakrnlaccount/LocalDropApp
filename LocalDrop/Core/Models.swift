import Foundation

// MARK: - Media type tables (same sets as server.py: IMG_EXT, VID_EXT, HEIC_EXT, CONV_VID_EXT)

enum MediaKind {
    static let img: Set<String> = ["jpg", "jpeg", "jpe", "jfif", "jif", "pjpeg", "pjp", "png", "apng", "gif", "webp", "bmp", "avif"]
    static let heic: Set<String> = ["heic", "heif"]
    static let vid: Set<String> = ["mp4", "webm", "mov", "m4v", "ogv"]
    static let convVid: Set<String> = ["hevc", "h265", "265", "mkv", "avi", "wmv", "flv", "3gp", "mts", "m2ts", "mpg", "mpeg"]
    /// Containers AVPlayer plays itself. Everything else is requested with ?inline=1 so the server transcodes it to MP4.
    static let nativeVid: Set<String> = ["mp4", "mov", "m4v", "3gp"]

    static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
    static func isVideo(_ name: String) -> Bool { let e = ext(name); return vid.contains(e) || convVid.contains(e) }
    static func isImage(_ name: String) -> Bool { let e = ext(name); return img.contains(e) || heic.contains(e) }
    static func isMedia(_ name: String) -> Bool { isVideo(name) || isImage(name) }
    static func playsNatively(_ name: String) -> Bool { nativeVid.contains(ext(name)) }
}

// MARK: - Server payloads

struct RemoteFile: Decodable, Identifiable, Hashable {
    let name: String
    let size: Int64
    let modified: String          // "2025-01-31T14:05:09" (server local time)
    let type: String
    var id: String { name }
    var ext: String { MediaKind.ext(name) }
    var isVideo: Bool { MediaKind.isVideo(name) }
    var isMedia: Bool { MediaKind.isMedia(name) }
    var day: String { String(modified.prefix(10)) }
}

struct Device: Decodable, Identifiable, Hashable {
    let ip: String
    let name: String
    let type: String?
    var id: String { ip }
    var symbol: String {
        switch type ?? "computer" {
        case "phone": return "iphone"
        case "tablet": return "ipad"
        case "tv": return "tv"
        case "console": return "gamecontroller"
        default: return "desktopcomputer"
        }
    }
}

struct Transfer: Decodable, Identifiable, Hashable {
    let id: String
    let fromIp: String
    let fromName: String
    let name: String
    let size: Int64
    let status: String
    enum CodingKeys: String, CodingKey {
        case id, name, size, status
        case fromIp = "from_ip", fromName = "from_name"
    }
}

struct Invite: Decodable, Identifiable, Hashable {
    let id: String
    let fromName: String
    let mode: String
    let folder: String
    let photos: Bool
    enum CodingKeys: String, CodingKey {
        case id, mode, folder, photos
        case fromName = "from_name"
    }
}

struct InviteResult: Decodable, Identifiable, Hashable {
    let id: String
    let toName: String
    let status: String
    enum CodingKeys: String, CodingKey {
        case id, status
        case toName = "to_name"
    }
}

struct PollResponse: Decodable {
    let cookie: String?
    let https: Int?
    let you: String
    let devices: [Device]
    let incoming: [Transfer]
    let outgoing: [Transfer]
    let invites: [Invite]
    let inviteResults: [InviteResult]
    enum CodingKeys: String, CodingKey {
        case cookie, https, you, devices, incoming, outgoing, invites
        case inviteResults = "invite_results"
    }
}

struct Member: Decodable, Hashable {
    let ip: String?
    let cookie: String?
    let name: String?
    var kind: String {
        if ip != nil && cookie != nil { return "Cookie ID + Local IP (must match both)" }
        return cookie != nil ? "Cookie ID" : "Local IP"
    }
}

struct SharedFolder: Decodable, Identifiable, Hashable {
    let id: String
    let photos: Bool
    let name: String
    let owner: Bool
    let count: Int
    let members: [Member]?
}

struct Album: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let items: [String]
}

struct MediaMeta: Decodable, Hashable {
    let t: String                 // best-known capture date, ISO local time
    let src: String               // "exif" | "video" | "file"
    let w: Int?
    let h: Int?
    let cam: String?
}

struct FilesResponse: Decodable { let files: [RemoteFile] }
struct FoldersResponse: Decodable { let folders: [SharedFolder] }
struct AlbumsResponse: Decodable { let albums: [Album] }
struct MetaResponse: Decodable { let meta: [String: MediaMeta] }
struct IDResponse: Decodable { let id: String? }

// MARK: - Formatting helpers (ports of size(), fmtDate(), dayLabel() from index.html)

func formatSize(_ n: Int64) -> String {
    if n < 1024 { return "\(n) B" }
    if n < 1_048_576 { return String(format: "%.1f KB", Double(n) / 1024) }
    if n < 1_073_741_824 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
    return String(format: "%.2f GB", Double(n) / 1_073_741_824)
}

enum DateFmt {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ s: String) -> Date? { iso.date(from: String(s.prefix(19))) }

    static func format(_ s: String, short: Bool) -> String {
        guard let d = parse(s) else { return "" }
        let day = d.formatted(date: .abbreviated, time: .omitted)
        return short ? day : day + " · " + d.formatted(date: .omitted, time: .shortened)
    }

    static func dayLabel(_ day: String) -> String {
        guard let d = dayOnly.date(from: day) else { return day }
        if Calendar.current.isDateInToday(d) { return "Today" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
