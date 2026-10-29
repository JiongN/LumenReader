import AppKit
import SwiftUI

/// Follow measured AppKit bounds, not SwiftUI's estimated lazy scroll extent.
struct TranscriptScrollFollower: NSViewRepresentable {
    var tailID: UUID?

    func makeNSView(context: Context) -> Attachment { Attachment() }
    func updateNSView(_ view: Attachment, context: Context) {
        view.controller.setTail(tailID)
        view.scheduleAttachment()
    }
    static func dismantleNSView(_ view: Attachment, coordinator: ()) { view.controller.detach() }

    final class Attachment: NSView {
        let controller = TranscriptScrollController()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { controller.detach() } else { scheduleAttachment() }
        }
        override func layout() { super.layout(); scheduleAttachment() }
        func scheduleAttachment() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                self.controller.attach(to: scroll)
                self.controller.schedule()
            }
        }
    }
}

@MainActor
final class TranscriptScrollController {
    private(set) var followsTail = true
    private var tailID: UUID?
    private weak var scroll: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var inputMonitor: Any?
    private var queued = false
    private var applyingScroll = false
    private var layoutChangePending = false
    private var layoutRevision: UInt = 0
    private var previousBounds: CGRect?
    private var previousDocumentHeight: CGFloat?

    func setTail(_ id: UUID?) {
        guard id != tailID else { return }
        tailID = id
        followsTail = true
        schedule()
    }

    func attach(to view: NSScrollView) {
        guard scroll !== view else { return }
        detach()
        scroll = view
        previousBounds = view.contentView.bounds
        previousDocumentHeight = view.documentView?.bounds.height
        view.contentView.postsBoundsChangedNotifications = true
        view.contentView.postsFrameChangedNotifications = true
        view.documentView?.postsFrameChangedNotifications = true
        for (name, object) in [(NSView.frameDidChangeNotification, view.documentView),
                               (NSView.frameDidChangeNotification, view.contentView)] {
            guard let object else { continue }
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.layoutChangePending = true
                    self?.layoutRevision &+= 1
                    self?.schedule()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: view.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
            object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
            object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeIfAtBottom() }
            })
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let scroll = self.scroll, event.window === scroll.window,
                      scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return }
                if event.type == .leftMouseUp { self.resumeIfAtBottom() }
                else if event.type == .leftMouseDown || event.scrollingDeltaY != 0 { self.pause() }
            }
            return event
        }
        schedule()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        scroll = nil
        previousBounds = nil
        previousDocumentHeight = nil
        layoutChangePending = false
        layoutRevision &+= 1
    }

    func pause() { followsTail = false }

    func resumeIfAtBottom() {
        guard let scroll, let document = scroll.documentView else { return }
        let target = Self.bottom(document: document.bounds, viewportHeight: scroll.contentView.bounds.height,
                                 flipped: document.isFlipped)
        followsTail = abs(scroll.contentView.bounds.minY - target) <= 32
    }

    private func boundsChanged() {
        guard let scroll, let document = scroll.documentView else { return }
        let current = scroll.contentView.bounds
        let oldBounds = previousBounds, oldHeight = previousDocumentHeight
        previousBounds = current
        previousDocumentHeight = document.bounds.height
        guard !applyingScroll else { return }
        // Keyboard and accessibility scrolling can omit live-scroll phases.
        // A layout resize is not evidence that the reader scrolled upward.
        if !layoutChangePending, let oldBounds, oldHeight == document.bounds.height,
           oldBounds.size == current.size, current.minY < oldBounds.minY - 2 {
            pause()
        }
        if layoutChangePending { schedule() }
        if !followsTail { resumeIfAtBottom() }
    }

    func schedule() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false
            self.reconcile()
        }
    }

    func reconcile() {
        defer {
            if layoutChangePending {
                let revision = layoutRevision
                // SwiftUI can correct the clip origin after the document-frame
                // callback. Keep this layout transaction open until two quiet
                // main-queue turns; real wheel/drag input still pauses immediately.
                DispatchQueue.main.async { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.layoutRevision == revision else { return }
                        self.layoutChangePending = false
                    }
                }
            }
        }
        guard let scroll, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let bounds = document.bounds
        guard bounds.height.isFinite, clip.bounds.height.isFinite else { return }
        let bottom = Self.bottom(document: bounds, viewportHeight: clip.bounds.height, flipped: document.isFlipped)
        let low = bounds.minY, high = max(low, bounds.maxY - clip.bounds.height)
        let current = clip.bounds.minY
        let target = followsTail ? bottom : min(high, max(low, current.isFinite ? current : low))
        guard abs(current - target) > 0.5 else { return }
        applyingScroll = true
        clip.scroll(to: .init(x: clip.bounds.minX, y: target))
        scroll.reflectScrolledClipView(clip)
        applyingScroll = false
    }

    static func bottom(document: CGRect, viewportHeight: CGFloat, flipped: Bool) -> CGFloat {
        flipped ? max(document.minY, document.maxY - viewportHeight) : document.minY
    }
}
