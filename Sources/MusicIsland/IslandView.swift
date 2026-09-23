import SwiftUI

enum IslandMetrics {
    static let closedTop: CGFloat = 6
    static let closedBottom: CGFloat = 14
    static let peekBottom: CGFloat = 20
    static let openTop: CGFloat = 18
    static let openBottom: CGFloat = 30
}

struct IslandView: View {
    @ObservedObject var vm: IslandViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var lyrics: LyricsController
    @Namespace private var ns

    private var expanded: Bool { vm.state == .expanded }

    private var topRadius: CGFloat { expanded ? IslandMetrics.openTop : IslandMetrics.closedTop }

    private var bottomRadius: CGFloat {
        switch vm.state {
        case .closed: IslandMetrics.closedBottom
        case .peek: IslandMetrics.peekBottom
        case .expanded: IslandMetrics.openBottom
        }
    }

    var body: some View {
        let size = vm.size
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)

        ZStack(alignment: .top) {
            backdrop(size: size)
            content
                .padding(.horizontal, topRadius)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: expanded ? 22 : 0, y: 10)
        .onTapGesture { if !expanded { vm.expand() } }
        .animation(.smooth(duration: 0.45), value: music.track?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: - Backdrop

    @ViewBuilder
    private func backdrop(size: CGSize) -> some View {
        ZStack {
            Color.black
            if expanded, let art = music.artwork {
                // Ambient wash of the album art, fading to pure black at the top so it meets the notch cleanly.
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 50)
                    .saturation(1.3)
                    .opacity(0.5)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.6), location: 0.45),
                        .init(color: .black, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if expanded {
            expandedContent
                .transition(AnyTransition.asymmetric(
                    insertion: AnyTransition(.blurReplace).combined(with: .scale(scale: 0.94, anchor: .top)),
                    removal: AnyTransition(.blurReplace).animation(.easeOut(duration: 0.14))))
        } else {
            compactContent
                .transition(.blurReplace)
        }
    }

    private var compactContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if vm.showEars {
                    ArtworkView(image: music.artwork, size: vm.notch.height - 12, radius: 6)
                        .matchedGeometryEffect(id: "art", in: ns)
                        .frame(width: vm.earWidth)
                        .transition(.blurReplace.combined(with: .scale(0.5)))
                    Spacer(minLength: 0)
                    Visualizer(playing: music.isPlaying, color: music.accent,
                               bars: 4, maxHeight: vm.notch.height * 0.45)
                        .frame(width: vm.earWidth)
                        .transition(.blurReplace.combined(with: .scale(0.5)))
                }
            }
            .frame(height: vm.notch.height)

            if vm.state == .peek, let track = music.track {
                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(track.artist)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 3)
                .id(track.id)
                .transition(.blurReplace.combined(with: .offset(y: -8)))
            }
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.notch.height)

            HStack(spacing: 14) {
                ArtworkView(image: music.artwork, size: 66, radius: 15)
                    .matchedGeometryEffect(id: "art", in: ns)
                    .shadow(color: music.accent.opacity(0.45), radius: 14, y: 4)
                    .onTapGesture { music.openMusic() }
                    .help("Open Music")

                VStack(alignment: .leading, spacing: 3) {
                    Text(music.track?.title ?? "Not Playing")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(music.track.map { $0.artist.isEmpty ? $0.album : $0.artist } ?? "Open Music to start listening")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .id(music.track?.id)
                .transition(.blurReplace)

                Spacer(minLength: 8)

                Visualizer(playing: music.isPlaying, color: music.accent, bars: 5, maxHeight: 22)
            }
            .padding(.top, 8)

            Scrubber(music: music)
                .padding(.top, 14)
                .opacity(music.track == nil ? 0.35 : 1)
                .allowsHitTesting(music.track != nil)

            PlaybackControls(music: music, lyrics: lyrics)
                .padding(.top, 6)

            if vm.showLyrics {
                LyricsPanel(music: music, lyrics: lyrics)
                    .frame(height: LyricsStack.boxHeight)
                    .padding(.top, 8)
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }
}

// MARK: - Notch shape

/// The notch silhouette: concave flares at the top that melt into the screen edge,
/// rounded corners at the bottom. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = topRadius
        let br = max(0, min(bottomRadius, rect.height - tr, (rect.width - 2 * tr) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Pieces

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// Decorative level meter. Real audio levels would need Screen Recording permission,
/// so this is a layered-sine animation that settles when paused.
struct Visualizer: View {
    let playing: Bool
    let color: Color
    var bars = 4
    var maxHeight: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: 3, height: max(3, level(t, i) * maxHeight))
                }
            }
            .frame(height: maxHeight)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: playing)
    }

    private func level(_ t: Double, _ i: Int) -> CGFloat {
        guard playing else { return 0.2 }
        let d = Double(i)
        let a = sin(t * (3.3 + d * 1.7) + d * 1.3)
        let b = sin(t * (5.1 + d * 0.9) + d * 2.1)
        let c = sin(t * (1.7 + d * 0.5))
        return CGFloat(0.3 + 0.7 * abs(a * 0.5 + b * 0.3 + c * 0.2))
    }
}

struct Scrubber: View {
    @ObservedObject var music: MusicController
    @ViewState private var dragPosition: Double?
    @ViewState private var hovering = false

    private var active: Bool { hovering || dragPosition != nil }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: !music.isPlaying || dragPosition != nil)) { context in
            let duration = music.track?.duration ?? 0
            let position = dragPosition ?? music.position(at: context.date)
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0

            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(.white.opacity(active ? 1 : 0.85))
                            .frame(width: max(0, geo.size.width * progress))
                    }
                    .frame(height: active ? 7 : 4.5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                            dragPosition = fraction * duration
                        }
                        .onEnded { _ in
                            if let target = dragPosition { music.seek(to: target) }
                            dragPosition = nil
                        })
                }
                .frame(height: 12)

                HStack {
                    Text(format(position))
                    Spacer()
                    Text("-" + format(max(duration - position, 0)))
                }
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(active ? 0.75 : 0.45))
            }
        }
        .onHover { h in hovering = h }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct PlaybackControls: View {
    @ObservedObject var music: MusicController
    @ObservedObject var lyrics: LyricsController

    var body: some View {
        ZStack {
            HStack(spacing: 26) {
                IconButton(symbol: "backward.fill", size: 17) { music.previous() }
                PlayPauseButton(isPlaying: music.isPlaying) { music.playPause() }
                IconButton(symbol: "forward.fill", size: 17) { music.next() }
            }

            HStack {
                Spacer()
                IconButton(symbol: lyrics.enabled ? "quote.bubble.fill" : "quote.bubble", size: 13,
                           tint: .white.opacity(lyrics.enabled ? 1 : 0.5)) {
                    lyrics.enabled.toggle()
                }
                .help(lyrics.enabled ? "Hide Lyrics" : "Show Lyrics")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct IconButton: View {
    let symbol: String
    let size: CGFloat
    var tint: Color = .white
    let action: () -> Void

    @ViewState private var hovering = false
    @ViewState private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .symbolEffect(.bounce.down, value: taps)
                // A fresh image per symbol: mutating the name under a symbol effect can leave it stale.
                .id(symbol)
                .transition(.blurReplace)
                .foregroundStyle(tint)
                .frame(width: size * 1.9, height: size * 1.9)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: symbol)
    }
}

/// Both glyphs are always present and cross-fade, so the icon can't get stuck on the old symbol.
struct PlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    private let size: CGFloat = 25
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                glyph("pause.fill", visible: isPlaying)
                glyph("play.fill", visible: !isPlaying)
            }
            .frame(width: size * 1.9, height: size * 1.9)
            .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isPlaying)
    }

    private func glyph(_ name: String, visible: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .scaleEffect(visible ? 1 : 0.45)
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 3)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

// MARK: - Lyrics

struct LyricsPanel: View {
    @ObservedObject var music: MusicController
    @ObservedObject var lyrics: LyricsController

    var body: some View {
        Group {
            if music.track == nil {
                status("Lyrics appear when a song plays")
            } else {
                switch lyrics.state {
                case .idle, .loading:
                    status("Finding lyrics…")
                case .loaded(.none):
                    status("No lyrics for this song")
                case .loaded(.instrumental):
                    status("♪  Instrumental")
                case .loaded(.plain(let lines)):
                    PlainLyrics(lines: lines)
                case .loaded(.synced(let lines)):
                    SyncedLyrics(lines: lines, music: music)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .transition(.blurReplace)
    }
}

/// Timed lyrics: the current line bright and centered, its neighbors dimmed above and below.
struct SyncedLyrics: View {
    let lines: [LyricLine]
    @ObservedObject var music: MusicController

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !music.isPlaying)) { context in
            // A small lead so each line lights up as it's sung, not just after.
            LyricsStack(lines: lines, current: index(at: music.position(at: context.date) + 0.25))
        }
    }

    private func index(at position: Double) -> Int {
        var low = 0, high = lines.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }
}

struct LyricsStack: View {
    let lines: [LyricLine]
    let current: Int

    static let lineHeight: CGFloat = 19
    static let spacing: CGFloat = 5
    static var boxHeight: CGFloat { 3 * lineHeight + 2 * spacing }

    var body: some View {
        let step = Self.lineHeight + Self.spacing
        VStack(spacing: Self.spacing) {
            ForEach(lines) { line in
                let isCurrent = line.id == current
                Text(line.text)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.3))
                    .scaleEffect(isCurrent ? 1 : 0.92)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.lineHeight)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Keep the current line in the middle row (before the first line, show it waiting there).
        .offset(y: step - CGFloat(max(current, 0)) * step)
        .frame(height: Self.boxHeight, alignment: .top)
        .clipped()
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.25),
            .init(color: .black, location: 0.75),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: current)
    }
}

/// Untimed lyrics: a quiet scrollable column.
struct PlainLyrics: View {
    let lines: [String]

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.18),
            .init(color: .black, location: 0.82),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

/// The macOS 27 SDK routes `@State` through a macro whose plugin only ships with full Xcode;
/// aliasing the underlying property wrapper lets the Command Line Tools build this.
typealias ViewState = SwiftUI.State
