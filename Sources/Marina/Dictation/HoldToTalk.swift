import Foundation

/// Tells a hold of Space from a tap, and decides what becomes of every key
/// event while it does. Pure — the clock and the actions belong to the
/// caller — so it can be driven with made-up events.
///
/// A hold is told from a tap by time, not by key repeat: the repeat delay is
/// each person's own macOS setting. Until the time is up the space is held
/// back, since a terminal would already have sent it to the program; it is
/// typed when the key comes up quickly, or before the next key when typing
/// fast makes keys overlap.
struct HoldToTalk {
    /// How long Space must stay down to count as a hold — the session
    /// dashboard's value, which Falk uses daily.
    static let holdDelay: TimeInterval = 0.35

    enum Event: Equatable {
        case spaceDown(isRepeat: Bool)
        case spaceUp
        case escape
        /// any other key going down
        case otherKey
        /// the timer started with `.startTimer(generation)`
        case timerFired(generation: Int)
    }

    enum Action: Equatable {
        /// type the held-back space now, before the event goes on
        case typeSpace
        /// call back with `.timerFired(generation)` after `holdDelay`
        case startTimer(generation: Int)
        case startListening
        /// Space came up: turn what was heard into text
        case stopListening
        /// Esc: throw away what was heard
        case cancelListening
    }

    struct Outcome: Equatable {
        /// false: the event is swallowed
        var passEvent: Bool
        var actions: [Action] = []
    }

    enum State: Equatable {
        case idle
        /// Space is down; tap or hold not yet known
        case pending
        case listening
        /// Esc or an interruption ended the press; Space's repeats and its
        /// coming up are swallowed until it does
        case cancelled
    }

    private(set) var state: State = .idle
    /// A timer from an earlier press must not end a later one.
    private var generation = 0

    mutating func handle(_ event: Event) -> Outcome {
        switch (state, event) {
        case (.idle, .spaceDown(isRepeat: false)):
            state = .pending
            generation += 1
            return Outcome(passEvent: false, actions: [.startTimer(generation: generation)])
        case (.idle, _):
            return Outcome(passEvent: true)

        case (.pending, .spaceDown):
            return Outcome(passEvent: false)                  // repeats before the hold
        case (.pending, .spaceUp):
            state = .idle
            return Outcome(passEvent: false, actions: [.typeSpace])
        case (.pending, .escape), (.pending, .otherKey):
            // fast typing, keys overlapping: the space first, then this key
            state = .idle
            return Outcome(passEvent: true, actions: [.typeSpace])
        case (.pending, .timerFired(let g)):
            guard g == generation else { return Outcome(passEvent: true) }
            state = .listening
            return Outcome(passEvent: true, actions: [.startListening])

        case (.listening, .spaceDown):
            return Outcome(passEvent: false)                  // key repeat
        case (.listening, .spaceUp):
            state = .idle
            return Outcome(passEvent: false, actions: [.stopListening])
        case (.listening, .escape):
            state = .cancelled
            return Outcome(passEvent: false, actions: [.cancelListening])
        case (.listening, .otherKey), (.listening, .timerFired):
            return Outcome(passEvent: true)

        case (.cancelled, .spaceDown(isRepeat: false)):
            // a new press: the release after an interruption was never seen
            state = .idle
            return handle(event)
        case (.cancelled, .spaceDown):
            return Outcome(passEvent: false)
        case (.cancelled, .spaceUp):
            state = .idle
            return Outcome(passEvent: false)
        case (.cancelled, _):
            return Outcome(passEvent: true)
        }
    }

    /// After Esc or an interruption, Space went down somewhere dictation does
    /// not happen: whatever was left of the old press is over.
    mutating func abandon() {
        if state == .cancelled { state = .idle }
    }

    /// The window lost the keyboard mid-press, or a hold ran too long, so
    /// Space may come up where it is never seen: end this press. A hold under
    /// way is turned into text, as a release would; a press not yet a hold
    /// is dropped.
    mutating func interrupt() -> Action? {
        let was = state
        guard was == .pending || was == .listening else { return nil }
        state = .cancelled
        generation += 1
        return was == .listening ? .stopListening : nil
    }
}
