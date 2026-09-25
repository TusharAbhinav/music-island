import AppKit
import ApplicationServices
import Combine
import CoreImage
import QuartzCore

/// Tints the Dock with the current album's colors.
///
/// Inspired by Orb (https://github.com/nithish6541/orbdock, MIT): apps can't draw inside the Dock, but the
/// Dock's glass blurs whatever sits behind it. So a click-through window one level below the Dock paints a
/// slowly drifting, blurred wash of the artwork twice: as a soft floor of light along the Dock's screen edge,
/// fading out before the Dock's top, and a little brighter directly behind the Dock's glass.
///
/// The Dock's frame comes from the Accessibility API, polled quickly when the Dock auto-hides so the glow
/// follows it in and out. Without that permission, a Dock that doesn't auto-hide is found from the space
/// macOS reserves for it; an auto-hiding one can't be located, so nothing is drawn.
@MainActor
final class DockGlow {
    static let enabledKey = "tintDock"

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { requestAccessIfNeeded() }
            restartTracking()
            updateVisibility(fast: false)
        }
    }

    private enum Edge { case bottom, left, right }

    private let music: MusicController
    private let window: NSWindow
    private let floorLayer = CALayer()
    private let floorMask = CAGradientLayer()
    private let pillLayer = CALayer()
    private let locator = DockLocator()
    private var cancellables = Set<AnyCancellable>()
    private var trackTimer: Timer?
    private var dockFrame: CGRect?
    private var edge: Edge = .bottom
    private var shownAlpha: CGFloat = 0

    /// Floor strength at the screen edge (it fades to nothing at the Dock's top) and behind the glass.
    private let floorIntensity: CGFloat = 0.7
    private let dockIntensity: Float = 0.85
    /// Overall strength while playing and while paused.
    private let playingAlpha: CGFloat = 1
    private let pausedAlpha: CGFloat = 0.5

    init(music: MusicController) {
        self.music = music
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true

        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Directly beneath the Dock, so its glass blurs this rather than whatever window is behind it.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.alphaValue = 0

        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        for layer in [floorLayer, pillLayer] {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            view.layer?.addSublayer(layer)
        }
        floorMask.colors = [NSColor.black.withAlphaComponent(floorIntensity).cgColor,
                            NSColor.black.withAlphaComponent(floorIntensity * 0.4).cgColor,
                            NSColor.black.withAlphaComponent(0).cgColor]
        floorMask.locations = [0, 0.45, 1]
        floorLayer.mask = floorMask
        pillLayer.opacity = dockIntensity
        pillLayer.masksToBounds = true
        window.contentView = view

        music.$artwork
            .sink { [weak self] image in self?.setArtwork(image) }
            .store(in: &cancellables)
        music.$isPlaying.combineLatest(music.$track.map { $0 != nil }.removeDuplicates())
            .sink { [weak self] _ in
                // Published values arrive before the properties update; read them on the next turn.
                Task { @MainActor in self?.updateVisibility(fast: false) }
            }
            .store(in: &cancellables)

        if enabled { requestAccessIfNeeded() }
        restartTracking()
    }

    // MARK: - Finding the Dock

    private func requestAccessIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func restartTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        guard enabled else { return }
        relocate()
        // An auto-hiding Dock slides in and out on its own; follow it closely.
        let autohide = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        let timer = Timer(timeInterval: autohide ? 1.0 / 30.0 : 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    private func relocate() {
        // Nothing to show: skip the Accessibility round trip.
        guard music.track != nil else { return }
        let frame = locator.dockFrame() ?? Self.reservedDockFrame()
        guard frame != dockFrame else { return }
        let wasVisible = dockFrame != nil
        dockFrame = frame

        guard let dock = frame, let screen = NSScreen.screens.first(where: { $0.frame.intersects(dock) }),
              screen.frame.intersection(dock).height > dock.height * 0.3 else {
            // Hidden (slid off screen) or not found.
            dockFrame = nil
            if wasVisible { updateVisibility(fast: true) }
            return
        }

        let f = screen.frame
        let gaps: [(Edge, CGFloat)] = [(.bottom, dock.minY - f.minY), (.left, dock.minX - f.minX),
                                       (.right, f.maxX - dock.maxX)]
        edge = gaps.min { $0.1 < $1.1 }!.0
        let floor: CGRect
        switch edge {
        case .bottom: floor = CGRect(x: f.minX, y: f.minY, width: f.width, height: dock.maxY - f.minY)
        case .left: floor = CGRect(x: f.minX, y: f.minY, width: dock.maxX - f.minX, height: f.height)
        case .right: floor = CGRect(x: dock.minX, y: f.minY, width: f.maxX - dock.minX, height: f.height)
        }
        window.setFrame(floor, display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: floor.size)
        floorLayer.frame = bounds
        floorMask.frame = bounds
        switch edge {
        case .bottom: floorMask.startPoint = CGPoint(x: 0.5, y: 0); floorMask.endPoint = CGPoint(x: 0.5, y: 1)
        case .left: floorMask.startPoint = CGPoint(x: 0, y: 0.5); floorMask.endPoint = CGPoint(x: 1, y: 0.5)
        case .right: floorMask.startPoint = CGPoint(x: 1, y: 0.5); floorMask.endPoint = CGPoint(x: 0, y: 0.5)
        }
        // Behind the glass, slightly inset so the color never shows past the Dock's rounded edge.
        let pill = dock.offsetBy(dx: -floor.minX, dy: -floor.minY).insetBy(dx: 2, dy: 2)
        pillLayer.frame = pill
        pillLayer.cornerRadius = min(pill.height, pill.width) / 2 > 24 ? 24 : min(pill.height, pill.width) / 2
        CATransaction.commit()

        if floorLayer.animation(forKey: "drift") == nil { startDrift() }
        if !wasVisible { updateVisibility(fast: true) }
    }

    /// Without Accessibility access: a Dock that doesn't auto-hide reserves a strip on one edge of a screen.
    private static func reservedDockFrame() -> CGRect? {
        var best: (CGRect, CGFloat)?
        for s in NSScreen.screens {
            let f = s.frame, v = s.visibleFrame
            let strips = [CGRect(x: f.minX, y: f.minY, width: f.width, height: v.minY - f.minY),
                          CGRect(x: f.minX, y: f.minY, width: v.minX - f.minX, height: f.height),
                          CGRect(x: v.maxX, y: f.minY, width: f.maxX - v.maxX, height: f.height)]
            for r in strips {
                let depth = min(r.width, r.height)
                if depth >= 12, depth > (best?.1 ?? 0) { best = (r, depth) }
            }
        }
        return best?.0
    }

    // MARK: - Content

    /// Slowly slides a band of the cover past the Dock, so different parts of the artwork surface over time.
    private func startDrift() {
        let horizontal = edge == .bottom
        let band: CGFloat = 0.4
        func rect(_ offset: CGFloat) -> CGRect {
            horizontal ? CGRect(x: 0, y: offset, width: 1, height: band)
                       : CGRect(x: offset, y: 0, width: band, height: 1)
        }
        for layer in [floorLayer, pillLayer] {
            let drift = CABasicAnimation(keyPath: "contentsRect")
            drift.fromValue = NSValue(rect: rect(0.05))
            drift.toValue = NSValue(rect: rect(1 - band - 0.05))
            drift.duration = 28
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.contentsRect = rect(0.05)
            layer.add(drift, forKey: "drift")
        }
    }

    private func setArtwork(_ image: NSImage?) {
        guard let image, let wash = Self.wash(from: image) else { return }
        for layer in [floorLayer, pillLayer] {
            // Melt from the previous album into the new one.
            let fade = CABasicAnimation(keyPath: "contents")
            fade.duration = 1.8
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "contents")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = wash
            CATransaction.commit()
        }
        updateVisibility(fast: false)
    }

    /// `fast` follows the Dock sliding in and out; otherwise it's a gentle music-state fade.
    private func updateVisibility(fast: Bool) {
        let target: CGFloat
        if !enabled || dockFrame == nil || music.track == nil || floorLayer.contents == nil {
            target = 0
        } else {
            target = music.isPlaying ? playingAlpha : pausedAlpha
        }
        guard target != shownAlpha else { return }
        shownAlpha = target
        if target > 0 { window.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fast ? 0.2 : 1.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = target
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownAlpha == 0 else { return }
                self.window.orderOut(nil)
            }
        })
    }

    private static let context = CIContext()

    /// A small, heavily blurred and slightly more vivid copy of the cover. The Dock's glass softens it further.
    private static func wash(from image: NSImage) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let source = CIImage(cgImage: cg)
        let side: CGFloat = 48
        let scaled = source.transformed(by: CGAffineTransform(scaleX: side / source.extent.width,
                                                              y: side / source.extent.height))
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let soft = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: 5)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35,
                                                            kCIInputBrightnessKey: 0.03])
            .cropped(to: extent)
        return context.createCGImage(soft, from: extent)
    }
}

/// Finds the Dock's frame through the Accessibility API.
final class DockLocator {
    private var list: AXUIElement?

    /// The Dock's frame in Cocoa screen coordinates, or nil without Accessibility access.
    func dockFrame() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        if list == nil || frame(of: list!) == nil { list = findList() }
        return list.flatMap(frame(of:))
    }

    private func findList() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return nil }
        return children.first { element in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            return (role as? String) == kAXListRole
        }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        // Accessibility uses a top-left origin anchored to the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height).integral
    }
}
