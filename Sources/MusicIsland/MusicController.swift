import AppKit
import SwiftUI

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
}

/// Talks to Music.app via AppleScript and its `playerInfo` distributed notification.
@MainActor
final class MusicController: NSObject, ObservableObject {
    static let bundleID = "com.apple.Music"

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white

    /// Fired when the song changes (not on first load).
    var onTrackChange: (() -> Void)?

    private let runner = ScriptRunner()
    private var basePosition: Double = 0
    private var baseDate = Date()
    private var generation = 0
    private var pollTimer: Timer?
    private var artworkTask: Task<Void, Never>?

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfoChanged(_:)),
            name: Notification.Name("com.apple.Music.playerInfo"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        pollTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(poll),
                                         userInfo: nil, repeats: true)
        refresh()
    }

    // MARK: - Position

    /// Playback position interpolated locally so the scrubber moves smoothly between polls.
    func position(at date: Date) -> Double {
        guard isPlaying else { return basePosition }
        let p = basePosition + date.timeIntervalSince(baseDate)
        if let d = track?.duration, d > 0 { return min(p, d) }
        return p
    }

    private func freezePosition() {
        let now = Date()
        basePosition = position(at: now)
        baseDate = now
    }

    // MARK: - Commands

    func playPause() {
        freezePosition()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isPlaying.toggle() }
        command(#"tell application "Music" to playpause"#)
    }

    func next() {
        command(#"tell application "Music" to next track"#)
    }

    func previous() {
        command(#"tell application "Music" to back track"#)
    }

    func seek(to seconds: Double) {
        basePosition = seconds
        baseDate = Date()
        command(#"tell application "Music" to set player position to "# + String(format: "%.2f", seconds),
                cache: false)
    }

    func openMusic() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Music.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    private func command(_ source: String, cache: Bool = true) {
        // Bump the generation so any status poll already in flight can't undo the optimistic update.
        generation += 1
        Task {
            _ = await runner.run(source, cache: cache)
            try? await Task.sleep(for: .milliseconds(250))
            refresh()
        }
    }

    // MARK: - State sync

    private var musicIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func refresh() {
        guard musicIsRunning else { clear(); return }
        let gen = generation
        Task {
            let status = await runner.status()
            guard gen == generation else { return }
            apply(status)
        }
    }

    @objc private func poll() {
        refresh()
    }

    @objc private func playerInfoChanged(_ note: Notification) {
        refresh()
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Self.bundleID { clear() }
    }

    private func apply(_ status: ScriptRunner.Status?) {
        guard let status, status.state != "stopped", !status.id.isEmpty else { clear(); return }

        let playing = status.state == "playing"
            || status.state.contains("forward") || status.state.contains("rewind")
        let newTrack = Track(id: status.id, title: status.title, artist: status.artist,
                             album: status.album, duration: status.duration)
        let changed = newTrack.id != track?.id
        let hadTrack = track != nil

        // Only resync the clock when we've drifted, so the scrubber never jitters.
        let predicted = position(at: Date())
        if changed || playing != isPlaying || abs(predicted - status.position) > 0.75 {
            basePosition = status.position
            baseDate = Date()
        }

        withAnimation(.smooth(duration: 0.4)) {
            if track != newTrack { track = newTrack }
            if isPlaying != playing { isPlaying = playing }
        }

        if changed {
            loadArtwork(for: newTrack)
            if hadTrack { onTrackChange?() }
        }
    }

    private func clear() {
        guard track != nil || isPlaying else { return }
        artworkTask?.cancel()
        basePosition = 0
        withAnimation(.smooth(duration: 0.4)) {
            track = nil
            isPlaying = false
            artwork = nil
            accent = .white
        }
    }

    // MARK: - Artwork

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        artworkTask = Task {
            var data: Data?
            // Streamed tracks sometimes need a moment before Music exposes their artwork.
            for attempt in 0..<3 {
                data = await runner.artworkData()
                if data != nil || Task.isCancelled { break }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(600)) }
            }
            var image = data.flatMap(NSImage.init(data:))
            if image == nil, !Task.isCancelled {
                image = await ArtworkFetcher.fetch(title: track.title, artist: track.artist)
            }
            guard !Task.isCancelled, self.track?.id == track.id else { return }

            let color = image?.accentColor().map(Color.init(nsColor:)) ?? .white
            withAnimation(.smooth(duration: 0.5)) {
                artwork = image
                accent = color
            }
        }
    }
}

// MARK: - AppleScript

/// Runs AppleScript on a single serial background queue (NSAppleScript is not thread-safe).
final class ScriptRunner: @unchecked Sendable {
    struct Status: Sendable {
        var state: String
        var title = ""
        var artist = ""
        var album = ""
        var duration: Double = 0
        var position: Double = 0
        var id = ""
    }

    private let queue = DispatchQueue(label: "MusicIsland.AppleScript", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:]

    // Variable names are prefixed: short names like `st` are reserved words in AppleScript.
    private static let statusScript = """
    if application "Music" is running then
        tell application "Music"
            set pState to (player state as text)
            if pState is "stopped" then return {pState}
            set tName to ""
            set tArtist to ""
            set tAlbum to ""
            set tDuration to 0
            set tPosition to 0
            set tID to ""
            try
                set t to current track
                set tName to name of t
                set tArtist to artist of t
                set tAlbum to album of t
                set tID to persistent ID of t
                set tDuration to duration of t
            end try
            try
                set tPosition to player position
            end try
            return {pState, tName, tArtist, tAlbum, tDuration, tPosition, tID}
        end tell
    end if
    return {"stopped"}
    """

    private static let artworkScript = """
    if application "Music" is running then
        tell application "Music"
            try
                if (count of artworks of current track) > 0 then
                    return raw data of artwork 1 of current track
                end if
            end try
        end tell
    end if
    return ""
    """

    private func execute(_ source: String, cache useCache: Bool) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if useCache, let cached = cache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            var compileError: NSDictionary?
            if !s.compileAndReturnError(&compileError) {
                NSLog("MusicIsland: AppleScript compile error: \(compileError ?? [:])")
                return nil
            }
            if useCache { cache[source] = s }
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("MusicIsland: AppleScript error: \(error)")
            return nil
        }
        return result
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    @discardableResult
    func run(_ source: String, cache: Bool = true) async -> Bool {
        await onQueue { self.execute(source, cache: cache) != nil }
    }

    func status() async -> Status? {
        await onQueue {
            guard let d = self.execute(Self.statusScript, cache: true), d.numberOfItems >= 1 else { return nil }
            var s = Status(state: d.atIndex(1)?.stringValue ?? "stopped")
            guard d.numberOfItems >= 7 else { return s }
            s.title = d.atIndex(2)?.stringValue ?? ""
            s.artist = d.atIndex(3)?.stringValue ?? ""
            s.album = d.atIndex(4)?.stringValue ?? ""
            s.duration = d.atIndex(5)?.doubleValue ?? 0
            s.position = d.atIndex(6)?.doubleValue ?? 0
            s.id = d.atIndex(7)?.stringValue ?? ""
            return s
        }
    }

    func artworkData() async -> Data? {
        await onQueue {
            guard let d = self.execute(Self.artworkScript, cache: true) else { return nil }
            let data = d.data
            return data.count > 64 ? data : nil
        }
    }
}

// MARK: - Artwork fallback

/// Looks up cover art on the iTunes Search API when Music doesn't expose it (common for streamed tracks).
enum ArtworkFetcher {
    private struct Response: Decodable {
        struct Item: Decodable { let artworkUrl100: String? }
        let results: [Item]
    }

    static func fetch(title: String, artist: String) async -> NSImage? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let small = try? JSONDecoder().decode(Response.self, from: data).results.first?.artworkUrl100,
              let bigURL = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
              let (imageData, _) = try? await URLSession.shared.data(from: bigURL)
        else { return nil }
        return NSImage(data: imageData)
    }
}

// MARK: - Accent color

extension NSImage {
    /// A vivid color from the artwork, brightened enough to read on black.
    func accentColor() -> NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var best: (h: CGFloat, s: CGFloat, b: CGFloat)?
        var bestScore: CGFloat = -1
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            guard b > 0.2 else { continue }
            let score = s * 0.7 + b * 0.3
            if score > bestScore {
                bestScore = score
                best = (h, s, b)
            }
        }
        guard let best else { return .white }
        if best.s < 0.12 { return NSColor(white: 0.92, alpha: 1) }
        return NSColor(hue: best.h, saturation: min(best.s, 0.8), brightness: max(best.b, 0.85), alpha: 1)
    }
}
