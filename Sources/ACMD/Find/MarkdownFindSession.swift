import Combine
import Foundation

/// Shared find state for the source editor and rendered preview.
///
/// A single published value makes each revision an atomic event: consumers
/// never observe a new query with an old action (or vice versa).
@MainActor
final class MarkdownFindSession: ObservableObject {
    enum Source: Equatable, Sendable {
        case editor
        case preview
    }

    enum Action: Equatable, Sendable {
        case queryChanged
        case next
        case previous
        case closed
    }

    struct State: Equatable, Sendable {
        let query: String
        let active: Bool
        let source: Source
        let action: Action
        let revision: UInt64
    }

    @Published private(set) var state = State(
        query: "",
        active: false,
        source: .editor,
        action: .closed,
        revision: 0
    )

    /// Opens find for a pane, optionally replacing the shared query.
    func activate(source: Source, query: String? = nil) {
        let query = query ?? state.query
        guard !state.active
                || state.query != query
                || state.source != source
                || state.action != .queryChanged else { return }
        publish(query: query, active: true, source: source, action: .queryChanged)
    }

    /// Publishes an incremental query change and makes the session active.
    func update(query: String, source: Source) {
        guard !state.active
                || state.query != query
                || state.source != source
                || state.action != .queryChanged else { return }
        publish(query: query, active: true, source: source, action: .queryChanged)
    }

    /// Publishes a repeatable navigation event for the current query.
    func navigate(_ action: Action, source: Source) {
        guard action == .next || action == .previous else { return }
        publish(query: state.query, active: true, source: source, action: action)
    }

    /// Closes find while retaining the query for the next activation.
    func deactivate(source: Source) {
        guard state.source == source,
              state.active || state.action != .closed else { return }
        publish(query: state.query, active: false, source: source, action: .closed)
    }

    private func publish(query: String, active: Bool, source: Source, action: Action) {
        state = State(
            query: query,
            active: active,
            source: source,
            action: action,
            revision: state.revision &+ 1
        )
    }
}

/// UTF-16 ranges used by TextKit and the shared editor find highlighting.
enum MarkdownFindMatcher {
    static func ranges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }

        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var matches: [NSRange] = []

        while searchRange.length > 0 {
            let match = source.range(
                of: query,
                options: .caseInsensitive,
                range: searchRange
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            matches.append(match)

            let nextLocation = NSMaxRange(match)
            searchRange = NSRange(
                location: nextLocation,
                length: source.length - nextLocation
            )
        }

        return matches
    }
}
