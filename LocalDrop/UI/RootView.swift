import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Group {
            if settings.serverAddress.isEmpty {
                ConnectView()
            } else {
                MainTabs()
            }
        }
        .overlay(alignment: .top) { OfflineBanner() }
        .overlay { ToastOverlay() }
        .animation(.spring(duration: 0.35), value: store.isConnected)
        .sheet(item: $store.sheet) { s in
            switch s {
            case .settings:
                SettingsView()
            case .cookie:
                CookieIDSheet()
            case .incoming(let t):
                IncomingSheet(transfer: t)
            case .invite(let i):
                InviteSheet(invite: i)
            case .share(let item):
                ShareSheet(url: item.url).ignoresSafeArea()
            }
        }
        .task { store.startPolling() }
    }
}

struct MainTabs: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView(selection: $store.tab) {
            Tab("Files", systemImage: "folder", value: AppTab.files) { FilesView() }
            Tab("Photos", systemImage: "photo.on.rectangle", value: AppTab.photos) { PhotosView(model: store.photos) }
            Tab("AirDrop", systemImage: "dot.radiowaves.left.and.right", value: AppTab.airdrop) { AirDropView() }
            Tab("Only me", systemImage: "lock.shield", value: AppTab.priv) { PrivateView() }
            Tab("Shared", systemImage: "person.2", value: AppTab.shared) { SharedView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

// MARK: - Incoming AirDrop (the web version's "wants to send you a file" modal)

struct IncomingSheet: View {
    let transfer: Transfer
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.accent) private var accent
    @State private var ping = false

    private var modeLabel: String { settings.privateMode == "cookie" ? "Cookie ID" : "Local IP" }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(accent, lineWidth: 2).frame(width: 64, height: 64)
                    .scaleEffect(ping ? 1.5 : 0.4).opacity(ping ? 0 : 0.7)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: ping)
                Image(systemName: "square.and.arrow.down").font(.system(size: 26)).foregroundStyle(accent)
                    .frame(width: 64, height: 64).glassEffect(.regular, in: .circle)
            }
            .padding(.top, 8)
            Text("\(transfer.fromName) (\(transfer.fromIp))").font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text("wants to send you a file").foregroundStyle(.secondary)
            Text("\(transfer.name) · \(formatSize(transfer.size))")
                .font(.body.weight(.semibold)).multilineTextAlignment(.center)

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    Button { act(.download) } label: { Label("Download", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                        .buttonStyle(.lgProminent)
                    Button { act(.exclusive) } label: { Label("Save with Exclusive ID (\(modeLabel))", systemImage: "lock").frame(maxWidth: .infinity) }
                        .buttonStyle(.lg)
                    Button { act(.cloud) } label: { Label("Store in Cloud", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.lg)
                    Button { act(.ignore) } label: { Text("Ignore").frame(maxWidth: .infinity) }
                        .buttonStyle(.lgDanger)
                }
            }
            .padding(.top, 6)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .onAppear { ping = true }
    }

    private func act(_ a: IncomingAction) {
        let t = transfer
        Task { await store.handleIncoming(t, a) }
    }
}

// MARK: - Share request (invite) sheet

struct InviteSheet: View {
    let invite: Invite
    @EnvironmentObject var store: AppStore
    @Environment(\.accent) private var accent

    private var how: String {
        switch invite.mode {
        case "cookie": return "Cookie ID"
        case "ip": return "Local IP"
        default: return "Cookie ID and Local IP"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shield").font(.system(size: 28)).foregroundStyle(accent)
                .frame(width: 64, height: 64).glassEffect(.regular, in: .circle).padding(.top, 8)
            Text("\(invite.fromName) wants to share with you").font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text((invite.photos ? "Their private photo library" : "The folder “\(invite.folder)”")
                 + ". If you accept, you get access using your \(how). They can remove your access at any time.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    Button { respond(true) } label: { Text("Accept").frame(maxWidth: .infinity) }.buttonStyle(.lgProminent)
                    Button { respond(false) } label: { Text("Decline").frame(maxWidth: .infinity) }.buttonStyle(.lgDanger)
                }
            }
            .padding(.top, 6)
        }
        .padding(24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func respond(_ accept: Bool) {
        let i = invite
        Task { await store.respond(to: i, accept: accept) }
    }
}

// MARK: - First run: connect to server.py

struct ConnectView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.accent) private var accent
    @State private var address = ""
    @State private var cookie = ""
    @State private var error: String?
    @State private var busy = false
    @State private var showCookie = false

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .glassEffect(.regular.tint(accent), in: .rect(cornerRadius: 26))
                        .padding(.top, 50)
                    BrandTitle().scaleEffect(1.3)
                    Text("Transfer files, photos and AirDrops between your devices on your own Wi-Fi.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Server address").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("192.168.1.20:8000", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 16))
                        Text("Run server.py on your PC. It prints the address next to “Network:”.")
                            .font(.caption).foregroundStyle(.secondary)

                        DisclosureGroup(isExpanded: $showCookie) {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("32-character Cookie ID (optional)", text: $cookie)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 16))
                                Text("Already use the web version? On the web, open Shared → Your Cookie ID → eye → Copy, and paste it here to bring your private files and photos along. You can also do this later in Settings.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        } label: {
                            Label("Transfer from the web version", systemImage: "person.badge.key").font(.subheadline.weight(.semibold))
                        }
                        .padding(.top, 6)
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.leading)
                    }

                    Button {
                        busy = true; error = nil
                        Task {
                            error = await store.connect(address: address, cookie: cookie)
                            busy = false
                        }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "Connecting…" : "Connect").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.lgProminent)
                    .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(24)
                .frame(maxWidth: 520)
            }
        }
    }
}
