import SwiftUI
import UIKit
import QuickLook

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

extension EnvironmentValues {
    @Entry var accent: Color = Color(hex: "#5b9dff")
    @Entry var buttonFX: Bool = false
}

// MARK: - Buttons (iOS 26 Liquid Glass; "Button effects" adds the 3D press + glow from the web version)

struct LGButtonStyle: ButtonStyle {
    enum Kind { case regular, prominent, danger }
    var kind: Kind = .regular
    @Environment(\.accent) private var accent
    @Environment(\.buttonFX) private var fx

    func makeBody(configuration: Configuration) -> some View {
        let glass: Glass = {
            switch kind {
            case .regular: return .regular.interactive()
            case .prominent: return .regular.tint(accent).interactive()
            case .danger: return .regular.tint(.red.opacity(0.55)).interactive()
            }
        }()
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(glass, in: .capsule)
            .scaleEffect(configuration.isPressed ? (fx ? 0.94 : 0.98) : 1)
            .rotation3DEffect(.degrees(fx && configuration.isPressed ? 7 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .shadow(color: fx && configuration.isPressed ? accent.opacity(0.7) : .clear, radius: 16)
            .animation(.spring(duration: 0.28, bounce: 0.35), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LGButtonStyle {
    static var lg: LGButtonStyle { LGButtonStyle() }
    static var lgProminent: LGButtonStyle { LGButtonStyle(kind: .prominent) }
    static var lgDanger: LGButtonStyle { LGButtonStyle(kind: .danger) }
}

// MARK: - Background

struct AppBackground: View {
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color(hex: "#0e0f11") : Color(hex: "#f4f5f7"))
            RadialGradient(colors: [accent.opacity(scheme == .dark ? 0.30 : 0.18), .clear],
                           center: .topLeading, startRadius: 10, endRadius: 460)
            RadialGradient(colors: [accent.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                           center: .bottomTrailing, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Small components

struct SettingsButton: ToolbarContent {
    let store: AppStore
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { store.sheet = .settings } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
        }
    }
}

struct BrandTitle: View {
    @Environment(\.accent) private var accent
    var body: some View {
        HStack(spacing: 0) {
            Text("Local").foregroundStyle(.primary)
            Text("Drop").foregroundStyle(accent)
        }
        .font(.title2.weight(.heavy))
    }
}

struct InfoBadge: View {
    let text: String
    var icon: String = "circle.fill"
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Header block used at the top of each screen: the web version's subtitle + badge row.
struct ScreenHeader: View {
    let subtitle: String
    var badge: String? = nil
    var badgeIcon: String = "circle.fill"
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let badge { InfoBadge(text: badge, icon: badgeIcon) }
        }
    }
}

struct GlassChip: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(accent).interactive() : .regular.interactive(), in: .capsule)
    }
}

struct DeviceCard: View {
    let device: Device
    var sending = false
    @Environment(\.accent) private var accent
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: device.symbol).font(.system(size: 34)).foregroundStyle(accent)
            Text(device.name).font(.headline).lineLimit(1)
            Text(device.ip).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20).padding(.horizontal, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).stroke(accent, lineWidth: 2)
                .opacity(sending ? (pulse ? 0.9 : 0.2) : 0)
        }
        .onChange(of: sending) { _, s in
            if s { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } } else { pulse = false }
        }
    }
}

struct RadarView: View {
    @Environment(\.accent) private var accent
    @State private var go = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle().stroke(accent, lineWidth: 2)
                    .scaleEffect(go ? 1.5 : 0.4)
                    .opacity(go ? 0 : 0.7)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: go)
            }
            Image(systemName: "wifi").font(.system(size: 30)).foregroundStyle(accent)
        }
        .frame(width: 96, height: 96)
        .onAppear { go = true }
    }
}

struct ToastOverlay: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack {
            Spacer()
            if let t = store.toastText {
                Text(t)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: store.toastText)
        .allowsHitTesting(false)
    }
}

/// "Can't reach server" banner shown while polling fails.
struct OfflineBanner: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if !store.isConnected {
            Button { store.sheet = .settings } label: {
                Label("Can't reach the server", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.orange.opacity(0.5)).interactive(), in: .capsule)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Share sheet / Quick Look helpers

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension View {
    /// Row background used on lists so the accent glow of AppBackground shows through.
    func rowGlass() -> some View { listRowBackground(Rectangle().fill(.ultraThinMaterial)) }
}

struct FileRow: View {
    let file: RemoteFile
    var icon: String = "doc"
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.isMedia ? (file.isVideo ? "film" : "photo") : icon)
                .font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(formatSize(file.size)) · \(file.type)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Upload card, the app's version of the web "Drop files here" area.
struct UploadCard: View {
    let title: String
    let message: String
    @Binding var showFiles: Bool
    @Binding var showPhotos: Bool
    var allowPhotos = true
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "icloud.and.arrow.up").font(.system(size: 32)).foregroundStyle(accent)
            Text(title).font(.headline)
            Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }.buttonStyle(.lgProminent)
                    if allowPhotos {
                        Button { showPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }.buttonStyle(.lg)
                    }
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5])).foregroundStyle(.tertiary))
    }
}
