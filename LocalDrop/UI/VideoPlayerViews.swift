import SwiftUI
import AVKit
import Combine

// MARK: - Player model

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var hasStarted = false
    @Published var ended = false
    @Published var current = 0.0
    @Published var duration = 0.0
    @Published var buffered = 0.0
    @Published var rate: Float = 1
    @Published var muted = false
    @Published var volume: Float = 1
    @Published var boost = false
    @Published var fill = false
    @Published var failed: String?
    var isScrubbing = false
    /// Called when volume / mute change so they persist like ld_vol / ld_muted on the web.
    var onVolumeChanged: ((Double, Bool) -> Void)?

    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var loadedURL: URL?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self else { return }
                self.isPlaying = s == .playing
                self.isBuffering = s == .waitingToPlayAtSpecifiedRate
                if s == .playing { self.hasStarted = true; self.ended = false }
            }
            .store(in: &bag)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let s = t.seconds
                if s.isFinite { self.current = s }
            }
        }
    }

    func load(url: URL, headers: [String: String]) {
        guard loadedURL != url else { return }
        loadedURL = url
        itemBag.removeAll()
        failed = nil; hasStarted = false; ended = false; current = 0; duration = 0; buffered = 0
        // "AVURLAssetHTTPHeaderFieldsKey" lets AVPlayer send the ld_id cookie so private videos are reachable.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)

        item.publisher(for: \.status).receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] st in
                if st == .failed { self?.failed = item?.error?.localizedDescription ?? "This video can't be played." }
            }.store(in: &itemBag)
        item.publisher(for: \.duration).receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                let s = d.seconds
                if s.isFinite, s > 0 { self?.duration = s }
            }.store(in: &itemBag)
        item.publisher(for: \.loadedTimeRanges).receive(on: DispatchQueue.main)
            .sink { [weak self] ranges in
                guard let self else { return }
                var end = 0.0
                for v in ranges {
                    let r = v.timeRangeValue
                    if r.start.seconds <= self.current + 0.5 { end = max(end, r.end.seconds) }
                }
                self.buffered = end
            }.store(in: &itemBag)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.ended = true; self?.isPlaying = false }
            .store(in: &itemBag)

        player.replaceCurrentItem(with: item)
        player.volume = volume
        player.isMuted = muted
        player.defaultRate = rate
        if boost { applyBoost() }
    }

    func configure(volume: Double, muted: Bool) {
        self.volume = Float(volume)
        self.muted = muted
        player.volume = Float(volume)
        player.isMuted = muted
    }

    func play() {
        if ended { seek(to: 0, precise: true) }
        player.defaultRate = rate
        player.play()
    }

    func pause() { player.pause() }
    func togglePlay() { isPlaying || isBuffering ? pause() : play() }

    func seek(to t: Double, precise: Bool) {
        let clamped = max(0, duration > 0 ? min(t, duration) : t)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        current = clamped
        if precise { player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) } else { player.seek(to: target) }
        if ended && clamped < duration - 0.5 { ended = false }
    }

    func skip(_ delta: Double) { seek(to: current + delta, precise: true) }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if isPlaying { player.rate = r }
    }

    func toggleMute() {
        muted.toggle()
        if !muted && volume == 0 { volume = 0.5 }
        player.isMuted = muted
        player.volume = volume
        onVolumeChanged?(Double(volume), muted)
    }

    func setVolume(_ v: Float) {
        volume = v
        if v > 0 { muted = false }
        player.volume = v
        player.isMuted = muted
        onVolumeChanged?(Double(v), muted)
    }

    /// 200 % audio. AVPlayer.volume tops out at 1.0, so the gain goes through an AVAudioMix (best effort).
    func setBoost(_ on: Bool) {
        boost = on
        applyBoost()
    }

    private func applyBoost() {
        guard let item = player.currentItem else { return }
        let gain: Float = boost ? 2.0 : 1.0
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(gain, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }

    func teardown() {
        player.pause()
    }
}

// MARK: - Layer-backed view

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .clear
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

// MARK: - Video page (autoplays when it becomes the visible page, like the web viewer)

struct VideoPage: View {
    let item: RemoteFile
    let ctx: ViewerContext
    let active: Bool
    let onTap: () -> Void
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = PlayerModel()
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            if let msg = model.failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Can't play this video").font(.headline)
                    Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Use Download to open it in another app.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(30)
            } else if settings.customPlayer {
                CustomVideoPlayer(model: model, poster: poster, onTap: onTap)
            } else {
                VideoPlayer(player: model.player).ignoresSafeArea()
            }
        }
        .task(id: item.name) {
            model.configure(volume: settings.volume, muted: settings.muted)
            model.onVolumeChanged = { v, m in settings.volume = v; settings.muted = m }
            if let t = ctx.thumbURL(item) {
                if let cached = ImageLoader.shared.cached(t) {
                    poster = cached
                } else {
                    poster = await ImageLoader.shared.load(t)
                }
            }
            if let u = ctx.srcURL(item) {
                model.load(url: u, headers: store.api.authHeaders)
                if active { model.play() }
            }
        }
        .onChange(of: active) { _, a in if a { model.play() } else { model.pause() } }
        .onDisappear { model.teardown() }
    }
}

// MARK: - Custom Liquid Glass controls

struct CustomVideoPlayer: View {
    @ObservedObject var model: PlayerModel
    let poster: UIImage?
    let onTap: () -> Void
    @Environment(\.accent) private var accent
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        ZStack {
            if let poster, !model.hasStarted {
                Image(uiImage: poster).resizable().scaledToFit().ignoresSafeArea()
            }
            PlayerLayerView(player: model.player, fill: model.fill).ignoresSafeArea()

            Color.clear.contentShape(Rectangle())
                .onTapGesture { surfaceTapped() }

            if model.isBuffering {
                ProgressView().controlSize(.large).tint(.white)
            } else if !model.isPlaying {
                Button { model.togglePlay(); showControls() } label: {
                    Image(systemName: model.ended ? "arrow.counterclockwise" : "play.fill")
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            }

            VStack {
                Spacer()
                controlBar
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 14)
                    .allowsHitTesting(controlsVisible)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .onChange(of: model.isPlaying) { _, _ in showControls() }
        .onAppear { showControls() }
    }

    private var controlBar: some View {
        VStack(spacing: 6) {
            SeekBar(current: model.current, duration: model.duration, buffered: model.buffered, accent: accent) { t, finished in
                model.isScrubbing = !finished
                model.seek(to: t, precise: finished)
                showControls()
            }
            HStack(spacing: 4) {
                barButton(model.isPlaying ? "pause.fill" : "play.fill", key: .space) { model.togglePlay() }
                barButton("gobackward.10", key: "j") { model.skip(-10) }
                barButton("goforward.10", key: "l") { model.skip(10) }
                barButton(muteIcon, key: "m") { model.toggleMute() }
                if hSize == .regular {
                    Slider(value: Binding(get: { Double(model.muted ? 0 : model.volume) },
                                          set: { model.setVolume(Float($0)) }), in: 0...1)
                        .frame(width: 84).tint(.white)
                }
                Text("\(formatTime(model.current)) / \(formatTime(model.duration))")
                    .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.white).padding(.leading, 6)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Menu {
                    ForEach(speeds, id: \.self) { r in
                        Button { model.setRate(r); showControls() } label: {
                            if model.rate == r { Label(r == 1 ? "Normal" : "\(r.formatted())×", systemImage: "checkmark") }
                            else { Text(r == 1 ? "Normal" : "\(r.formatted())×") }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                        Text("\(model.rate.formatted())×").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(.white).frame(minWidth: 38, minHeight: 38).padding(.horizontal, 6)
                }
                barButton("headphones", on: model.boost) {
                    model.setBoost(!model.boost)
                }
                barButton(model.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", key: "f") {
                    model.fill.toggle()
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private var muteIcon: String {
        if model.muted { return "speaker.slash.fill" }
        if model.volume == 0 { return "speaker.fill" }
        return model.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    private func barButton(_ icon: String, on: Bool = false, key: KeyEquivalent? = nil, action: @escaping () -> Void) -> some View {
        let b = Button { action(); showControls() } label: {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? accent : .white).frame(width: 38, height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        return Group {
            if let key { b.keyboardShortcut(key, modifiers: []) } else { b }
        }
    }

    private func surfaceTapped() {
        // Like the web player: the first touch only reveals the controls, a touch while they are showing toggles playback.
        if controlsVisible { onTap(); model.togglePlay() } else { showControls() }
    }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled, model.isPlaying, !model.isScrubbing { controlsVisible = false }
        }
    }
}

/// Seek bar with a buffered track, like .v-seek-container on the web.
struct SeekBar: View {
    let current: Double
    let duration: Double
    let buffered: Double
    let accent: Color
    let onScrub: (Double, Bool) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            let p = duration > 0 ? min(max(current / duration, 0), 1) : 0
            let b = duration > 0 ? min(max(buffered / duration, 0), 1) : 0
            let knob: CGFloat = dragging ? 18 : 12
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: dragging ? 8 : 5)
                Capsule().fill(.white.opacity(0.22)).frame(width: w * b, height: dragging ? 8 : 5)
                Capsule().fill(accent).frame(width: w * p, height: dragging ? 8 : 5)
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: w * p - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        onScrub(min(max(v.location.x / w, 0), 1) * duration, false)
                    }
                    .onEnded { v in
                        dragging = false
                        onScrub(min(max(v.location.x / w, 0), 1) * duration, true)
                    }
            )
            .animation(.spring(duration: 0.2), value: dragging)
        }
        .frame(height: 28)
    }
}
