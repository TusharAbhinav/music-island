import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandViewModel: ObservableObject {
    enum State { case closed, peek, expanded }

    /// Controls that light up under the pointer.
    enum HoverTarget: Hashable { case previous, playPause, next, lyrics, scrubber, artwork }

    static let openSpring = Animation.spring(response: 0.44, dampingFraction: 0.74)
    static let closeSpring = Animation.spring(response: 0.38, dampingFraction: 0.9)

    @Published private(set) var state: State = .closed
    @Published private(set) var showEars = false
    @Published private(set) var showLyrics = false
    @Published var notch = CGSize(width: 185, height: 32)
    /// Which control the pointer is over. Computed from the pointer position the app already
    /// polls, because the panel never becomes active and its enter/exit hover events are unreliable.
    @Published private(set) var hovered: HoverTarget?
    /// Each control's frame in window coordinates (top-left origin), reported by the views.
    var targetFrames: [HoverTarget: CGRect] = [:]
    /// The control currently held down, for the press-in animation.
    @Published private(set) var pressed: HoverTarget?
    /// While dragging the scrubber: where it's being dragged to, 0...1.
    @Published private(set) var scrubFraction: Double?
    /// Click counts per control, used to trigger the icon bounce.
    @Published private(set) var taps: [HoverTarget: Int] = [:]

    private let music: MusicController
    private let lyrics: LyricsController

    private var hovering = false
    private var hoverTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Extra card height for the three-line lyrics panel.
    static let lyricsHeight: CGFloat = 80

    init(music: MusicController, lyrics: LyricsController) {
        self.music = music
        self.lyrics = lyrics
        showLyrics = lyrics.enabled
        lyrics.$enabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] on in
                withAnimation(Self.openSpring) { self?.showLyrics = on }
            }
            .store(in: &cancellables)

        // Show the compact artwork whenever a song is loaded — playing or paused.
        music.$track
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] visible in
                withAnimation(Self.openSpring) { self?.showEars = visible }
            }
            .store(in: &cancellables)

        music.onTrackChange = { [weak self] in self?.peek() }
    }

    // MARK: - Geometry

    var earWidth: CGFloat { notch.height }

    var size: CGSize {
        let closedWidth = notch.width + 2 * IslandMetrics.closedTop + (showEars ? 2 * earWidth : 0)
        switch state {
        case .closed:
            return CGSize(width: closedWidth, height: notch.height)
        case .peek:
            return CGSize(width: max(closedWidth + 40, 320), height: notch.height + 42)
        case .expanded:
            return CGSize(width: max(460, closedWidth + 60), height: notch.height + 186 + (showLyrics ? Self.lyricsHeight : 0))
        }
    }

    private func target(at point: CGPoint) -> HoverTarget? {
        guard state == .expanded else { return nil }
        return targetFrames.first { $0.value.contains(point) }?.key
    }

    /// `point` is in window coordinates (top-left origin), or nil when the pointer is outside the island.
    func updatePointer(_ point: CGPoint?) {
        let target = point.flatMap(target(at:))
        guard target != hovered else { return }
        withAnimation(.easeOut(duration: 0.15)) { hovered = target }
    }

    // MARK: - Clicks
    //
    // The panel hands raw mouse events here instead of letting SwiftUI gestures handle them:
    // in this never-active window, gestures could get stuck after a click on empty space and
    // swallow every click after it. Hit-testing uses the same frames that drive the hover highlight.

    func mouseDown(at point: CGPoint) {
        guard state == .expanded else {
            expand()
            return
        }
        let target = target(at: point)
        if target == .scrubber, music.track == nil { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { pressed = target }
        if target == .scrubber { scrub(to: point) }
    }

    func mouseDragged(to point: CGPoint) {
        if pressed == .scrubber { scrub(to: point) }
    }

    func mouseUp(at point: CGPoint) {
        guard let target = pressed else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { pressed = nil }

        if target == .scrubber {
            if let fraction = scrubFraction, let duration = music.track?.duration, duration > 0 {
                music.seek(to: fraction * duration)
            }
            scrubFraction = nil
            return
        }
        // Only a release over the same control counts as a click.
        guard self.target(at: point) == target else { return }
        taps[target, default: 0] += 1
        switch target {
        case .previous: music.previous()
        case .playPause: music.playPause()
        case .next: music.next()
        case .lyrics: lyrics.enabled.toggle()
        case .artwork: music.openMusic()
        case .scrubber: break
        }
    }

    private func scrub(to point: CGPoint) {
        guard let frame = targetFrames[.scrubber], frame.width > 0 else { return }
        scrubFraction = min(max((point.x - frame.minX) / frame.width, 0), 1)
    }

    // MARK: - Transitions

    func setHovering(_ isHovering: Bool) {
        guard isHovering != hovering else { return }
        hovering = isHovering
        hoverTask?.cancel()

        if isHovering {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                transition(to: .expanded)
            }
        } else if state == .expanded {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                transition(to: .closed)
            }
        }
    }

    func expand() {
        hoverTask?.cancel()
        transition(to: .expanded)
    }

    private func peek() {
        guard state == .closed, !hovering, showEars else { return }
        transition(to: .peek)
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled, state == .peek else { return }
            transition(to: .closed)
        }
    }

    private func transition(to newState: State) {
        guard newState != state else { return }
        if newState == .expanded {
            peekTask?.cancel()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        withAnimation(newState == .closed ? Self.closeSpring : Self.openSpring) {
            state = newState
        }
    }
}
