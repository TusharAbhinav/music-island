import AppKit
import SwiftUI
import ServiceManagement

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let windowSize = CGSize(width: 640, height: 400)

    let music = MusicController()
    lazy var lyrics = LyricsController(music: music)
    lazy var island = IslandViewModel(music: music, lyrics: lyrics)

    private var panel: NotchPanel!
    private var statusItem: NSStatusItem!
    private var mouseMonitor: Any?
    private var hoverTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NotchPanel()
        let host = IslandHostingView(rootView: IslandView(vm: island, music: music, lyrics: lyrics))
        host.sizingOptions = []
        panel.contentView = host
        layoutPanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }

        setupStatusItem()
        music.start()
    }

    // MARK: - Placement

    private var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func notchSize(for screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width,
                          height: screen.safeAreaInsets.top)
        }
        // No notch: draw a compact virtual one the height of the menu bar.
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return CGSize(width: 180, height: menuBar)
    }

    private func layoutPanel() {
        let s = screen
        island.notch = notchSize(for: s)
        let size = Self.windowSize
        panel.setFrame(NSRect(x: s.frame.midX - size.width / 2,
                              y: s.frame.maxY - size.height,
                              width: size.width, height: size.height),
                       display: true)
    }

    @objc private func screensChanged() {
        layoutPanel()
    }

    // MARK: - Hover / hit testing

    /// The panel ignores the mouse everywhere except over the island itself,
    /// so clicks on the transparent parts fall through to whatever is below.
    private func trackMouse() {
        let point = NSEvent.mouseLocation
        let frame = screen.frame
        let size = island.size
        let rect = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                          width: size.width, height: size.height).insetBy(dx: -4, dy: -4)

        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let inside: Bool
        if buttonDown {
            // Keep a scrub going if the pointer drifts off; ignore drags that started elsewhere.
            inside = !panel.ignoresMouseEvents
        } else {
            inside = rect.contains(point)
        }

        panel.ignoresMouseEvents = !inside
        island.setHovering(inside)

        if inside, hoverTimer == nil {
            // While we own the mouse, global monitors go quiet — poll instead.
            let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(hoverTick),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else if !inside {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    @objc private func hoverTick() {
        trackMouse()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music Island")

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Music", action: #selector(openMusic), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Music Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openMusic() {
        music.openMusic()
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MusicIsland: launch at login failed: \(error)")
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

// MARK: - Window

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Allow the window to sit over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
