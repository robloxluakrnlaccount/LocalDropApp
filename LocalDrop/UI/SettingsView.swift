import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var serverMessage: String?
    @State private var testing = false
    @State private var showCookie = false
    @State private var showCookieSheet = false
    @State private var confirmReset = false
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                cookieSection
                appearanceSection
                photosSection
                interactionSection
                Section {
                    Button("Reset settings", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Theme, accent, device name, Only me mode and viewer options. Your server address and Cookie ID are kept.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("Liquid Glass comes from iOS 26 itself, so there is no separate glass setting.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { server = settings.serverAddress }
            .sheet(isPresented: $showCookieSheet) { CookieIDSheet() }
            .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { settings.resetPreferences() }
            }
            .confirmationDialog("Disconnect from this server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { dismiss(); store.disconnect() }
            } message: { Text("Your files stay on the server. Your Cookie ID is kept on this device.") }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            TextField("192.168.1.20:8000", text: $server)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { Task { await test() } }
            HStack {
                Button { Task { await test() } } label: {
                    if testing { ProgressView() } else { Text("Test & save") }
                }
                .disabled(testing || server.trimmingCharacters(in: .whitespaces).isEmpty || server == settings.serverAddress)
                Spacer()
                Label(store.isConnected ? "Connected" : "Offline", systemImage: store.isConnected ? "checkmark.circle.fill" : "wifi.exclamationmark")
                    .font(.footnote).foregroundStyle(store.isConnected ? .green : .orange)
            }
            if let m = serverMessage { Text(m).font(.footnote).foregroundStyle(.red) }
            HStack {
                Text("Device name")
                TextField("Device name", text: $settings.deviceName).multilineTextAlignment(.trailing)
            }
            Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
        } header: {
            Text("Server")
        } footer: {
            Text("The PC running server.py. Shown to other devices in AirDrop as your device name.")
        }
    }

    // MARK: Cookie ID (the transfer feature)

    private var cookieSection: some View {
        Section {
            HStack {
                Text("Cookie ID")
                Spacer()
                Text(showCookie ? settings.cookieID : "••••••••••••")
                    .font(.system(.footnote, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                Button { showCookie.toggle() } label: { Image(systemName: showCookie ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                Button { UIPasteboard.general.string = settings.cookieID; store.toast("Copied") } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
            }
            Button { showCookieSheet = true } label: { Label("Use a different Cookie ID…", systemImage: "person.badge.key") }
        } header: {
            Text("Cookie ID & transfer")
        } footer: {
            Text("This ID is how the server recognises your private files and your private photo library. To move your web photos here, paste the ID from the web version. Anyone with this ID can open your private files, so treat it like a password.")
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 10) {
                Text("Accent colour")
                Text("Buttons, highlights and icons").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ForEach(AppSettings.accents, id: \.hex) { a in
                        Button { settings.accentHex = a.hex } label: {
                            Circle().fill(Color(hex: a.hex)).frame(width: 32, height: 32)
                                .overlay(Circle().stroke(.primary, lineWidth: settings.accentHex == a.hex ? 3 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(a.name)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Photos & viewer

    private var photosSection: some View {
        Section("Photos & viewer") {
            toggleRow("Show date on photos", "Print the date taken (from the photo's metadata, or the file date if it has none) on every thumbnail. The viewer always shows it at the top.", $settings.showDates)
            toggleRow("Media backdrop", "In the viewer, use the open photo or video (blurred) as the background.", $settings.mediaBackdrop)
            toggleRow("Custom Player UI", "Use the glass video controls instead of the system player.", $settings.customPlayer)
        }
    }

    private var interactionSection: some View {
        Section("Interaction") {
            toggleRow("Button effects", "3D press with a glow on LocalDrop's buttons.", $settings.buttonFX)
            toggleRow("Animations", "Turn off for instant screens with no motion.", $settings.animations)
        }
    }

    private func toggleRow(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func test() async {
        testing = true; serverMessage = nil
        serverMessage = await store.connect(address: server)
        if serverMessage == nil { server = settings.serverAddress; store.toast("Connected") }
        testing = false
    }
}

// MARK: - Change the Cookie ID (transfer photos and private files from the web version)

struct CookieIDSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: String?
    @State private var working = false
    @State private var confirmNew = false
    @State private var showCurrent = false

    private var normalized: String? { AppSettings.normalizeCookie(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("To bring your web photos and private files into this app, copy the Cookie ID from the web version and paste it here: open the web version, go to **Shared**, tap the eye next to **Your Cookie ID**, then **Copy**.")
                        .font(.subheadline)
                }

                Section("Cookie ID from the web version") {
                    TextField("32-character ID", text: $text, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .lineLimit(1...3)
                    Button { text = UIPasteboard.general.string ?? text } label: { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                    if !text.isEmpty {
                        if normalized != nil {
                            Label(normalized == settings.cookieID ? "This is already the ID in use" : "Looks good", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(normalized == settings.cookieID ? Color.secondary : Color.green).font(.footnote)
                        } else {
                            Label("A Cookie ID is exactly 32 characters: 0–9 and a–f", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red).font(.footnote)
                        }
                    }
                }

                Section {
                    Button {
                        guard let n = normalized else { return }
                        apply(n)
                    } label: {
                        HStack { if working { ProgressView() }; Text("Use this Cookie ID") }
                    }
                    .disabled(normalized == nil || normalized == settings.cookieID || working)
                } footer: {
                    Text("The app switches immediately and then shows what the server holds under that ID. Your previous ID is remembered below, so you can switch back.")
                }

                if let result {
                    Section { Label(result, systemImage: "info.circle") }
                }

                Section("This app is currently using") {
                    HStack {
                        Text(showCurrent ? settings.cookieID : "••••••••••••")
                            .font(.system(.footnote, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                        Spacer()
                        Button { showCurrent.toggle() } label: { Image(systemName: showCurrent ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                        Button { UIPasteboard.general.string = settings.cookieID; store.toast("Copied") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                    }
                }

                if !settings.cookieHistory.isEmpty {
                    Section("Previously used on this device") {
                        ForEach(settings.cookieHistory, id: \.self) { id in
                            Button { text = id } label: {
                                Text(id).font(.system(.footnote, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
                            }
                        }
                    }
                }

                Section {
                    Button("Generate a brand-new ID…", role: .destructive) { confirmNew = true }
                } footer: {
                    Text("A new ID starts with an empty private space. Files saved under the old ID stay on the server and come back if you switch back to it.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Cookie ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Generate a new Cookie ID?", isPresented: $confirmNew, titleVisibility: .visible) {
                Button("Generate", role: .destructive) { apply(AppSettings.newCookieID()) }
            } message: { Text("You will lose access to your current private space until you switch back.") }
        }
    }

    private func apply(_ id: String) {
        working = true
        Task {
            result = await store.changeCookie(to: id)
            text = ""
            working = false
        }
    }
}
