import AppKit
import SwiftUI

/// Developer utility: `MusicIsland --render-screenshots <dir>` renders the open card for the
/// current song (without and with lyrics) to PNGs, then quits. Used for README / PR images,
/// since the card normally only opens on hover.
@MainActor
enum ScreenshotRenderer {
    static var outputDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-screenshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func run(music: MusicController, lyrics: LyricsController, island: IslandViewModel, to dir: URL) {
        Task {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let lyricsWereOn = lyrics.enabled

            // Give Music time to report the song and its artwork.
            for _ in 0..<40 where music.artwork == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }

            lyrics.enabled = false
            island.expand()
            try? await Task.sleep(for: .seconds(1.2))
            render(music: music, lyrics: lyrics, island: island, to: dir.appendingPathComponent("card.png"))

            lyrics.enabled = true
            for _ in 0..<40 {
                if case .loaded = lyrics.state { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            // Jump to just after the second line so one line is lit with its neighbors around it.
            if case .loaded(.synced(let lines)) = lyrics.state, lines.count > 2 {
                music.seek(to: lines[1].time + 0.4)
            }
            try? await Task.sleep(for: .seconds(1.2))
            render(music: music, lyrics: lyrics, island: island, to: dir.appendingPathComponent("card-lyrics.png"))

            lyrics.enabled = lyricsWereOn
            NSApp.terminate(nil)
        }
    }

    private static func render(music: MusicController, lyrics: LyricsController, island: IslandViewModel, to url: URL) {
        let content = ZStack(alignment: .top) {
            // A dark desktop-like backdrop so the black island reads the way it does on screen.
            LinearGradient(colors: [Color(red: 0.13, green: 0.12, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            IslandView(vm: island, music: music, lyrics: lyrics)
        }
        .frame(width: 600, height: island.size.height + 60)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
