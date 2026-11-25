import SwiftUI

@main
struct LocalDropApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: AppStore
    @Environment(\.scenePhase) private var phase

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _store = StateObject(wrappedValue: AppStore(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .environment(\.accent, settings.accent)
                .environment(\.buttonFX, settings.buttonFX)
                .tint(settings.accent)
                .preferredColorScheme(settings.theme.scheme)
                .transaction { t in
                    if !settings.animations { t.disablesAnimations = true }
                }
                .onChange(of: phase) { _, p in store.scenePhaseChanged(p) }
        }
    }
}
