import SwiftUI
import UIKit

struct MediaViewer: View {
    let ctx: ViewerContext
    let ns: Namespace.ID?

    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RemoteFile]
    @State private var selection: String
    @State private var chrome = true
    @State private var confirmDelete = false
    @State private var shareURL: ShareItem?
    @State private var backdrop: UIImage?

    init(ctx: ViewerContext, ns: Namespace.ID?) {
        self.ctx = ctx
        self.ns = ns
        let start = ctx.items.indices.contains(ctx.start) ? ctx.start : 0
        _items = State(initialValue: ctx.items)
        _selection = State(initialValue: ctx.items.isEmpty ? "" : ctx.items[start].name)
    }

    private var current: RemoteFile? { items.first { $0.name == selection } }
    private var deleteTitleText: String { current.map { ctx.deleteTitle($0) } ?? "" }

    var body: some View {
        NavigationStack {
            ZStack {
                background
                TabView(selection: $selection) {
                    ForEach(items) { item in
                        MediaPage(item: item, ctx: ctx, active: item.name == selection) {
                            withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                        }
                        .tag(item.name)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            .toolbar { viewerToolbar }
            .toolbarVisibility(chrome ? .automatic : .hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .statusBarHidden(!chrome)
        }
        .modifier(ZoomTransition(ns: ns, id: selection))
        .preferredColorScheme(.dark)
        .task(id: selection) { await loadBackdrop() }
        .sheet(item: $shareURL) { s in ShareSheet(url: s.url).ignoresSafeArea() }
        .confirmationDialog(deleteTitleText, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(deleteTitleText.hasPrefix("Remove") ? "Remove from album" : "Delete", role: .destructive) {
                Task { await deleteCurrent() }
            }
        }
    }

    // MARK: pieces

    @ViewBuilder private var background: some View {
        ZStack {
            Color.black
            if settings.mediaBackdrop, let b = backdrop {
                Image(uiImage: b).resizable().scaledToFill().blur(radius: 50).opacity(0.55)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.12), .black], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: backdrop)
    }

    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(current?.name ?? "").font(.headline).lineLimit(1).truncationMode(.middle)
                if let c = current, let m = ctx.meta(c) {
                    Text(metaLine(c, m)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await shareCurrent() } } label: { Image(systemName: "square.and.arrow.down") }
                .accessibilityLabel("Download")
        }
        if ctx.onDelete != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .tint(.red).accessibilityLabel("Delete")
            }
        }
    }

    /// Date taken · camera · size, like the web viewer's top-left caption.
    private func metaLine(_ p: RemoteFile, _ m: MediaMeta) -> String {
        let extra = [m.cam ?? "", (m.w != nil && m.h != nil) ? "\(m.w!)×\(m.h!)" : "", m.src == "file" ? "file date" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let d = DateFmt.format(m.t, short: false)
        return extra.isEmpty ? d : d + "  ·  " + extra
    }

    private func loadBackdrop() async {
        guard settings.mediaBackdrop, let c = current, let u = ctx.thumbURL(c) else { backdrop = nil; return }
        backdrop = ImageLoader.shared.cached(u)
        if backdrop == nil { backdrop = await ImageLoader.shared.load(u) }
    }

    private func shareCurrent() async {
        guard let c = current else { return }
        // Original file, never the preview copy: the download route returns the file as uploaded.
        guard let u = ctx.srcURL(c) else { return }
        var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        comps?.queryItems = comps?.queryItems?.filter { $0.name != "inline" }
        if comps?.queryItems?.isEmpty == true { comps?.queryItems = nil }
        if let local = await store.fetchLocal(comps?.url ?? u, name: c.name) { shareURL = ShareItem(url: local) }
    }

    private func deleteCurrent() async {
        guard let c = current, let del = ctx.onDelete else { return }
        guard await del(c) else { return }
        if let i = items.firstIndex(of: c) {
            items.remove(at: i)
            if items.isEmpty { dismiss(); return }
            selection = items[min(i, items.count - 1)].name
        }
    }
}

/// Zoom transition from the tapped grid tile (iOS 18+), skipped when there is no source tile.
struct ZoomTransition: ViewModifier {
    let ns: Namespace.ID?
    let id: String
    func body(content: Content) -> some View {
        if let ns {
            content.navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            content
        }
    }
}

// MARK: - One page of the pager

struct MediaPage: View {
    let item: RemoteFile
    let ctx: ViewerContext
    let active: Bool
    let onTap: () -> Void

    var body: some View {
        if item.isVideo {
            VideoPage(item: item, ctx: ctx, active: active, onTap: onTap)
        } else {
            ImagePage(item: item, ctx: ctx, onTap: onTap)
        }
    }
}

struct ImagePage: View {
    let item: RemoteFile
    let ctx: ViewerContext
    let onTap: () -> Void
    @State private var thumb: UIImage?
    @State private var full: UIImage?

    var body: some View {
        ZStack {
            if let img = full ?? thumb {
                ZoomableImageView(image: img, onSingleTap: onTap).ignoresSafeArea()
            }
            if full == nil && thumb == nil { ProgressView().controlSize(.large).tint(.white) }
        }
        .task(id: item.name) {
            if let t = ctx.thumbURL(item) { thumb = ImageLoader.shared.cached(t) ?? (await ImageLoader.shared.load(t)) }
            if let s = ctx.srcURL(item) { full = await ImageLoader.shared.load(s, animatedGIF: item.ext == "gif") }
        }
    }
}

// MARK: - Pinch / double-tap / pan zoom (UIScrollView is the only thing that gets all three right)

final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 { imageView.frame = bounds }
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let sv = ZoomScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 6
        sv.bouncesZoom = true
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        sv.imageView.contentMode = .scaleAspectFit
        sv.imageView.isUserInteractionEnabled = true
        sv.addSubview(sv.imageView)
        context.coordinator.scrollView = sv

        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)
        let one = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        one.require(toFail: dbl)
        sv.addGestureRecognizer(one)
        return sv
    }

    func updateUIView(_ sv: ZoomScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        if sv.imageView.image !== image {
            sv.imageView.image = image      // keeps current zoom when the full-size image replaces the thumbnail
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: ZoomScrollView?
        var onSingleTap: () -> Void = {}

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ZoomScrollView)?.imageView }

        @objc func singleTap() { onSingleTap() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = scrollView else { return }
            if sv.zoomScale > 1.05 {
                sv.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: sv.imageView)
                let s: CGFloat = 2.5
                let w = sv.bounds.width / s, h = sv.bounds.height / s
                sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}
