import Combine
import Foundation
import SwiftUI

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

enum Lyrics: Equatable {
    case synced([LyricLine])
    case plain([String])
    case instrumental
    case none
}

/// Fetches lyrics for the current song from LRCLIB (lrclib.net), only while lyrics are switched on.
@MainActor
final class LyricsController: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(Lyrics)
    }

    private static let enabledKey = "showLyrics"

    @Published private(set) var state: LoadState = .idle
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { load(music.track) }
        }
    }

    private let music: MusicController
    private var cache: [String: Lyrics] = [:]
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(music: MusicController) {
        self.music = music
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        music.$track
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                // $track publishes before the property updates, so read it on the next turn.
                Task { @MainActor in self.load(self.music.track) }
            }
            .store(in: &cancellables)
    }

    private func load(_ track: Track?) {
        loadTask?.cancel()
        guard let track else { state = .idle; return }
        guard enabled else { return }
        if let cached = cache[track.id] {
            state = .loaded(cached)
            return
        }

        state = .loading
        loadTask = Task {
            let lyrics = await LRCLib.lookup(title: track.title, artist: track.artist,
                                             album: track.album, duration: track.duration)
            guard !Task.isCancelled else { return }
            cache[track.id] = lyrics
            if music.track?.id == track.id {
                withAnimation(.smooth(duration: 0.35)) { state = .loaded(lyrics) }
            }
        }
    }
}

// MARK: - LRCLIB

enum LRCLib {
    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    static func lookup(title: String, artist: String, album: String, duration: Double) async -> Lyrics {
        // Gather every candidate (exact match plus looser searches) and pick the best, rather than
        // taking the first hit — popular Indian songs often exist both in native script and romanized.
        let short = cleaned(title)
        async let exact = get(title: title, artist: artist, album: album, duration: duration)
        async let byTitle = search(["track_name": title, "artist_name": artist])
        async let byShortTitle = short == title ? [] : search(["track_name": short, "artist_name": artist])
        async let byQuery = search(["q": "\(short) \(artist)"])

        let candidates = [await exact].compactMap { $0 } + (await byTitle) + (await byShortTitle) + (await byQuery)
        return best(candidates, duration: duration) ?? .none
    }

    private static func get(title: String, artist: String, album: String, duration: Double) async -> Record? {
        var items = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        guard let data = await fetch(path: "/api/get", items: items) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func search(_ params: [String: String]) async -> [Record] {
        let items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let data = await fetch(path: "/api/search", items: items) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func fetch(path: String, items: [URLQueryItem]) async -> Data? {
        var components = URLComponents(string: "https://lrclib.net")!
        components.path = path
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("MusicIsland/1.0 (macOS notch player)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    /// Scores candidates: matching length first, then Indian-script over romanized
    /// (only when such a version exists), then timed over plain. Ties keep the earlier, more exact match.
    private static func best(_ records: [Record], duration: Double) -> Lyrics? {
        let usable = records.filter { lyrics(from: $0) != nil }
        let nativeExists = usable.contains(where: isIndicScript)

        func score(_ r: Record) -> Int {
            var s = 0
            if duration <= 0 || abs((r.duration ?? 0) - duration) < 3 { s += 4 }
            if nativeExists, isIndicScript(r) { s += 3 }
            if !(r.syncedLyrics ?? "").isEmpty { s += 2 }
            return s
        }

        var bestRecord: Record?
        var bestScore = Int.min
        for r in usable where score(r) > bestScore {
            bestRecord = r
            bestScore = score(r)
        }
        return bestRecord.flatMap(lyrics(from:))
    }

    /// True when most letters are in an Indian script (Devanagari through Sinhala, U+0900–U+0DFF).
    private static func isIndicScript(_ record: Record) -> Bool {
        let text = record.syncedLyrics ?? record.plainLyrics ?? ""
        var indic = 0, letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if (0x0900...0x0DFF).contains(scalar.value) { indic += 1 }
        }
        return letters > 0 && Double(indic) / Double(letters) > 0.5
    }

    private static func lyrics(from record: Record) -> Lyrics? {
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        if record.instrumental == true { return .instrumental }
        return nil
    }

    /// Parses "[mm:ss.xx] text" lines. A line may carry several timestamps.
    static func parseLRC(_ source: String) -> [LyricLine] {
        var entries: [(Double, String)] = []
        for raw in source.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
                    times.append(m * 60 + s)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { entries.append((t, text.isEmpty ? "♪" : text)) }
        }
        return entries.sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// Drops "(feat. …)", "[Remastered]" and similar decorations that break matching.
    private static func cleaned(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
