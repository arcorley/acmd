import AppKit
import ACMDCore

/// User-facing selection information derived from AppKit's UTF-16 ranges.
struct MarkdownEditorTextMetrics: Equatable {
    let line: Int
    let column: Int
    let selectedCharacterCount: Int

    static func measure(
        text: String,
        selection: NSRange,
        focusLocation requestedFocusLocation: Int? = nil
    ) -> Self {
        let source = text as NSString
        let selection = clamped(selection, toUTF16Length: source.length)
        let focusLocation = min(
            max(requestedFocusLocation ?? selection.location, 0),
            source.length
        )
        let lineStarts = EditorSourceMapper.lineStarts(in: text)
        let lineIndex = EditorSourceMapper.lineIndex(
            atUTF16Location: focusLocation,
            lineStarts: lineStarts
        )
        let lineStart = lineStarts[min(lineIndex, lineStarts.count - 1)]

        return Self(
            line: lineIndex + 1,
            column: characterCount(
                in: NSRange(location: lineStart, length: focusLocation - lineStart),
                of: text
            ) + 1,
            selectedCharacterCount: characterCount(in: selection, of: text)
        )
    }

    /// Returns the UTF-16 insertion point for a one-based line number. Values
    /// outside the document are clamped to the first or last logical line.
    static func location(ofLine line: Int, in text: String) -> Int {
        let starts = EditorSourceMapper.lineStarts(in: text)
        let index = min(max(line, 1), starts.count) - 1
        return starts[index]
    }

    private static func characterCount(in range: NSRange, of text: String) -> Int {
        guard range.length > 0 else { return 0 }
        if let stringRange = Range(range, in: text) {
            return text[stringRange].count
        }

        // NSTextView normally places selections on composed-character
        // boundaries. Keep metrics safe for programmatic, malformed ranges.
        return range.length
    }

    private static func clamped(_ range: NSRange, toUTF16Length length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), length - location)
        )
    }
}

/// Computes smart Markdown list indentation as a single text replacement so
/// NSTextView can validate and undo it atomically.
enum MarkdownListIndentation {
    enum Direction {
        case indent
        case outdent
    }

    struct Edit: Equatable {
        let replacementRange: NSRange
        let replacement: String
        let selection: NSRange

        func changes(_ originalText: String) -> Bool {
            (originalText as NSString).substring(with: replacementRange) != replacement
        }
    }

    private struct Mutation {
        let range: NSRange
        let replacement: String
    }

    private enum BaseListStyle: Equatable {
        case ordered(delimiter: String)
        case unordered(marker: String)
    }

    private struct ListStyle: Equatable {
        let base: BaseListStyle
        let isTask: Bool
    }

    private struct ListItemMarker {
        let structuralPrefix: String
        let style: ListStyle
        let number: Int?
        let numberRange: NSRange?
        let markerSyntaxRange: NSRange
        let markerSpacing: String
        let taskState: String?
        let taskSpacing: String?
    }

    private struct DestinationSequence {
        let style: ListStyle
        let markerSpacing: String
        let taskSpacing: String?
        var nextOrdinal: Int
    }

    private struct StructuralPosition: Hashable {
        let quotePath: String
        let quoteDepth: Int
        let indentation: Int
    }

    private struct SelectedRoot {
        let lineRange: NSRange
        let marker: ListItemMarker
        let subtreeRange: NSRange
    }

    private struct OrderedRunImpact {
        let prefix: String
        let style: ListStyle
        var nextOrdinal: Int
        var scanStart: Int
    }

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)(?:(?:([-+*]))|(?:([0-9]+)([.)])))([ \t]+)(?:\[([ xX])\]([ \t]+))?"#
    )
    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)"#
    )

    static func edit(
        text: String,
        selection requestedSelection: NSRange,
        direction: Direction
    ) -> Edit? {
        let source = text as NSString
        let selection = clamped(requestedSelection, toUTF16Length: source.length)
        let initialAffectedRange = logicalLineRange(in: source, selection: selection)
        let initialLineRanges = logicalLines(in: source, range: initialAffectedRange)
        let recognizedListMarkers = MarkdownSyntaxTokenizer.spans(in: text).filter {
            $0.kind == .listMarker || $0.kind == .taskMarker
        }
        let selectedMarkers: [(range: NSRange, marker: ListItemMarker)] = initialLineRanges.compactMap {
            let line = content(of: $0, source: source)
            guard let marker = listItemMarker(in: line) else { return nil }
            if direction == .indent,
               !containsRecognizedListMarker($0, markers: recognizedListMarkers) {
                return nil
            }
            return ($0, marker)
        }
        guard !selectedMarkers.isEmpty else { return nil }

        var selectedRoots: [SelectedRoot] = []
        for selected in selectedMarkers {
            if selectedRoots.contains(where: { existing in
                let containsSelectedLine = selected.range.location > existing.lineRange.location
                    && selected.range.location < NSMaxRange(existing.subtreeRange)
                guard containsSelectedLine else { return false }

                // Indenting an ancestor moves its whole subtree. During
                // outdent, however, a top-level selected ancestor is fixed in
                // place and must not suppress explicitly selected descendants
                // that can still move toward the margin.
                return direction == .indent
                    || removableIndent(
                        in: existing.marker.structuralPrefix as NSString
                    ) != nil
            }) {
                continue
            }
            selectedRoots.append(SelectedRoot(
                lineRange: selected.range,
                marker: selected.marker,
                subtreeRange: rangeIncludingDescendants(of: selected.range, in: source)
            ))
        }
        let affectedEnd = selectedRoots.reduce(NSMaxRange(initialAffectedRange)) { end, root in
            max(end, NSMaxRange(root.subtreeRange))
        }
        let affectedRange = NSRange(
            location: initialAffectedRange.location,
            length: affectedEnd - initialAffectedRange.location
        )
        let lineRanges = logicalLines(in: source, range: affectedRange)
        let movingRoots = selectedRoots.filter { root in
            switch direction {
            case .indent:
                return true
            case .outdent:
                return removableIndent(in: root.marker.structuralPrefix as NSString) != nil
            }
        }

        // A recognized top-level list consumes Shift-Tab as a safe no-op.
        guard !movingRoots.isEmpty else {
            return Edit(
                replacementRange: affectedRange,
                replacement: source.substring(with: affectedRange),
                selection: selection
            )
        }

        let movingLineLocations = Set(lineRanges.compactMap { lineRange in
            movingRoots.contains(where: {
                lineRange.location >= $0.subtreeRange.location
                    && lineRange.location < NSMaxRange($0.subtreeRange)
            }) ? lineRange.location : nil
        })
        let rootLineLocations = Set(movingRoots.map { $0.lineRange.location })
        let rootByLineLocation = Dictionary(
            uniqueKeysWithValues: movingRoots.map { ($0.lineRange.location, $0) }
        )

        var mutations: [Mutation] = []
        var destinationSequences: [StructuralPosition: DestinationSequence] = [:]
        var targetSequenceSnapshots: [StructuralPosition: DestinationSequence] = [:]
        var targetPrefixes: [StructuralPosition: String] = [:]
        var targetScanStarts: [StructuralPosition: Int] = [:]
        var sourceImpacts: [OrderedRunImpact] = []

        for root in movingRoots {
            guard case .ordered = root.marker.style.base else { continue }
            let scanStart = NSMaxRange(root.subtreeRange)
            sourceImpacts.append(OrderedRunImpact(
                prefix: root.marker.structuralPrefix,
                style: root.marker.style,
                nextOrdinal: orderedContinuationOrdinal(
                    in: source,
                    before: root.lineRange.location,
                    prefix: root.marker.structuralPrefix,
                    style: root.marker.style,
                    fallbackOrdinal: 1,
                    ignoringLineLocations: movingLineLocations
                ),
                scanStart: scanStart
            ))
        }

        for lineRange in lineRanges {
            guard let owningRoot = movingRoots.first(where: {
                lineRange.location >= $0.subtreeRange.location
                    && lineRange.location < NSMaxRange($0.subtreeRange)
            }) else {
                if content(of: lineRange, source: source).length > 0 {
                    destinationSequences.removeAll()
                }
                continue
            }
            let line = content(of: lineRange, source: source)
            guard line.length > 0 else { continue }
            let marker = rootLineLocations.contains(lineRange.location)
                ? listItemMarker(in: line)
                : nil
            guard let prefixLength = blockPrefixLength(in: line) else { continue }

            switch direction {
            case .indent:
                let prefix = line.substring(to: prefixLength) as NSString
                let insertionOffset = indentInsertionOffset(
                    in: prefix,
                    afterQuoteDepth: structuralPosition(
                        of: owningRoot.marker.structuralPrefix
                    ).quoteDepth
                )
                mutations.append(Mutation(
                    range: NSRange(
                        location: lineRange.location + insertionOffset,
                        length: 0
                    ),
                    replacement: "    "
                ))
                if let marker {
                    let targetPrefix = marker.structuralPrefix + "    "
                    let targetPosition = structuralPosition(of: targetPrefix)
                    targetPrefixes[targetPosition] = targetPrefix
                    if let root = rootByLineLocation[lineRange.location] {
                        targetScanStarts[targetPosition] = max(
                            targetScanStarts[targetPosition] ?? 0,
                            NSMaxRange(root.subtreeRange)
                        )
                    }
                    clearSequencesDeeper(
                        than: targetPosition,
                        sequences: &destinationSequences
                    )
                    var sequence = destinationSequences[targetPosition]
                        ?? destinationSequence(
                            in: source,
                            before: lineRange.location,
                            targetPrefix: targetPrefix,
                            boundaryPrefix: marker.structuralPrefix,
                            fallback: marker,
                            restartsOrderedFallback: true,
                            ignoringLineLocations: movingLineLocations
                        )
                    let replacement = markerSyntax(
                        for: sequence,
                        sourceMarker: marker
                    )
                    if line.substring(with: marker.markerSyntaxRange) != replacement {
                        mutations.append(Mutation(
                            range: NSRange(
                                location: lineRange.location + marker.markerSyntaxRange.location,
                                length: marker.markerSyntaxRange.length
                            ),
                            replacement: replacement
                        ))
                    }
                    advance(&sequence)
                    destinationSequences[targetPosition] = sequence
                    targetSequenceSnapshots[targetPosition] = sequence
                }

            case .outdent:
                let prefix = line.substring(to: prefixLength) as NSString
                if let removal = removableIndent(
                    in: prefix,
                    afterQuoteDepth: structuralPosition(
                        of: owningRoot.marker.structuralPrefix
                    ).quoteDepth
                ) {
                    mutations.append(Mutation(
                        range: NSRange(
                            location: lineRange.location + removal.location,
                            length: removal.length
                        ),
                        replacement: ""
                    ))
                    if let marker {
                        let targetPrefix = removing(
                            removal,
                            from: marker.structuralPrefix
                        )
                        let targetPosition = structuralPosition(of: targetPrefix)
                        targetPrefixes[targetPosition] = targetPrefix
                        if let root = rootByLineLocation[lineRange.location] {
                            targetScanStarts[targetPosition] = max(
                                targetScanStarts[targetPosition] ?? 0,
                                NSMaxRange(root.subtreeRange)
                            )
                        }
                        clearSequencesDeeper(
                            than: targetPosition,
                            sequences: &destinationSequences
                        )
                        var sequence = destinationSequences[targetPosition]
                            ?? destinationSequence(
                                in: source,
                                before: lineRange.location,
                                targetPrefix: targetPrefix,
                                boundaryPrefix: nil,
                                fallback: marker,
                                restartsOrderedFallback: false,
                                ignoringLineLocations: movingLineLocations
                            )
                        let replacement = markerSyntax(
                            for: sequence,
                            sourceMarker: marker
                        )
                        if line.substring(with: marker.markerSyntaxRange) != replacement {
                            mutations.append(Mutation(
                                range: NSRange(
                                    location: lineRange.location
                                        + marker.markerSyntaxRange.location,
                                    length: marker.markerSyntaxRange.length
                                ),
                                replacement: replacement
                            ))
                        }
                        advance(&sequence)
                        destinationSequences[targetPosition] = sequence
                        targetSequenceSnapshots[targetPosition] = sequence
                    }
                }
            }
        }

        var sourceRenumberMutations: [Mutation] = []
        for impact in sourceImpacts {
            appendUnique(
                orderedRunMutations(
                    in: source,
                    startingAt: impact.scanStart,
                    impact: impact,
                    ignoringLineLocations: movingLineLocations
                ),
                to: &sourceRenumberMutations
            )
        }
        var targetRenumberMutations: [Mutation] = []
        for (position, prefix) in targetPrefixes {
            guard let sequence = targetSequenceSnapshots[position],
                  case .ordered = sequence.style.base else { continue }
            appendUnique(
                orderedRunMutations(
                    in: source,
                    startingAt: targetScanStarts[position] ?? affectedEnd,
                    impact: OrderedRunImpact(
                        prefix: prefix,
                        style: sequence.style,
                        nextOrdinal: sequence.nextOrdinal,
                        scanStart: targetScanStarts[position] ?? affectedEnd
                    ),
                    ignoringLineLocations: movingLineLocations
                ),
                to: &targetRenumberMutations
            )
        }
        let targetRenumberRanges = Set(targetRenumberMutations.map(\.range))
        mutations.append(contentsOf: sourceRenumberMutations.filter {
            !targetRenumberRanges.contains($0.range)
        })
        mutations.append(contentsOf: targetRenumberMutations)

        let orderedMutations = mutations.sorted(by: mutationPrecedes)
        let replacementEnd = orderedMutations.reduce(NSMaxRange(affectedRange)) { end, mutation in
            max(end, NSMaxRange(mutation.range))
        }
        let replacementRange = NSRange(
            location: affectedRange.location,
            length: replacementEnd - affectedRange.location
        )
        let mutable = NSMutableString(string: source.substring(with: replacementRange))
        for mutation in orderedMutations.reversed() {
            let localRange = NSRange(
                location: mutation.range.location - replacementRange.location,
                length: mutation.range.length
            )
            mutable.replaceCharacters(in: localRange, with: mutation.replacement)
        }

        let start = mapped(selection.location, through: orderedMutations)
        let end = mapped(NSMaxRange(selection), through: orderedMutations)
        return Edit(
            replacementRange: replacementRange,
            replacement: mutable as String,
            selection: NSRange(location: start, length: max(0, end - start))
        )
    }

    private static func logicalLineRange(in source: NSString, selection: NSRange) -> NSRange {
        guard selection.length > 0 else {
            return source.lineRange(for: selection)
        }

        // Exclude the following line when a selection ends exactly at its
        // beginning, matching standard multi-line editor behavior.
        return source.lineRange(for: NSRange(
            location: selection.location,
            length: max(0, selection.length - 1)
        ))
    }

    private static func logicalLines(in source: NSString, range: NSRange) -> [NSRange] {
        guard range.length > 0 else { return [range] }
        var lines: [NSRange] = []
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            lines.append(line)
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
        return lines
    }

    private static func content(of lineRange: NSRange, source: NSString) -> NSString {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let unit = source.character(at: end - 1)
            guard unit == 10 || unit == 13 else { break }
            end -= 1
        }
        return source.substring(with: NSRange(
            location: lineRange.location,
            length: end - lineRange.location
        )) as NSString
    }

    private static func listMarkerPrefixLength(in line: NSString) -> Int? {
        let range = NSRange(location: 0, length: line.length)
        guard let match = listPrefix.firstMatch(in: line as String, range: range) else {
            return nil
        }
        return match.range(at: 1).length
    }

    private static func listItemMarker(in line: NSString) -> ListItemMarker? {
        let range = NSRange(location: 0, length: line.length)
        guard let match = listPrefix.firstMatch(
            in: line as String,
            range: range
        ) else { return nil }
        let prefixRange = match.range(at: 1)
        let bulletRange = match.range(at: 2)
        let numberRange = match.range(at: 3)
        let delimiterRange = match.range(at: 4)
        let markerSpacingRange = match.range(at: 5)
        let taskStateRange = match.range(at: 6)
        let taskSpacingRange = match.range(at: 7)

        let baseStyle: BaseListStyle
        let number: Int?
        if numberRange.location != NSNotFound {
            baseStyle = .ordered(delimiter: line.substring(with: delimiterRange))
            number = Int(line.substring(with: numberRange))
        } else {
            baseStyle = .unordered(marker: line.substring(with: bulletRange))
            number = nil
        }

        let markerStart = NSMaxRange(prefixRange)
        return ListItemMarker(
            structuralPrefix: line.substring(with: prefixRange),
            style: ListStyle(
                base: baseStyle,
                isTask: taskStateRange.location != NSNotFound
            ),
            number: number,
            numberRange: numberRange.location == NSNotFound ? nil : numberRange,
            markerSyntaxRange: NSRange(
                location: markerStart,
                length: NSMaxRange(match.range) - markerStart
            ),
            markerSpacing: line.substring(with: markerSpacingRange),
            taskState: taskStateRange.location == NSNotFound
                ? nil
                : line.substring(with: taskStateRange),
            taskSpacing: taskSpacingRange.location == NSNotFound
                ? nil
                : line.substring(with: taskSpacingRange)
        )
    }

    private static func destinationSequence(
        in source: NSString,
        before lineStart: Int,
        targetPrefix: String,
        boundaryPrefix: String?,
        fallback: ListItemMarker,
        restartsOrderedFallback: Bool,
        ignoringLineLocations: Set<Int>
    ) -> DestinationSequence {
        let targetPosition = structuralPosition(of: targetPrefix)
        var searchEnd = lineStart
        while searchEnd > 0 {
            let previousRange = source.lineRange(for: NSRange(
                location: searchEnd - 1,
                length: 0
            ))
            guard previousRange.location < searchEnd else { break }
            if ignoringLineLocations.contains(previousRange.location) {
                searchEnd = previousRange.location
                continue
            }
            let previousLine = content(of: previousRange, source: source)

            if let marker = listItemMarker(in: previousLine) {
                if structuralPosition(of: marker.structuralPrefix) == targetPosition {
                    return sequence(after: marker)
                }
                if marker.structuralPrefix == boundaryPrefix {
                    break
                }

                let position = structuralPosition(of: marker.structuralPrefix)
                if position.quotePath != targetPosition.quotePath,
                   !targetPosition.quotePath.isEmpty {
                    break
                }
                if position.quotePath == targetPosition.quotePath,
                   position.indentation < targetPosition.indentation {
                    break
                }
            } else if previousLine.length > 0,
                      let previousPrefix = blockPrefixString(in: previousLine) {
                let position = structuralPosition(of: previousPrefix)
                if position.quotePath != targetPosition.quotePath
                    || position.indentation <= targetPosition.indentation {
                    break
                }
            }
            searchEnd = previousRange.location
        }
        return sequence(
            startingWith: fallback,
            restartsOrdered: restartsOrderedFallback
        )
    }

    private static func sequence(after marker: ListItemMarker) -> DestinationSequence {
        let nextOrdinal: Int
        switch marker.style.base {
        case .ordered:
            nextOrdinal = incrementingOrdinal(max(0, marker.number ?? 0))
        case .unordered:
            nextOrdinal = 1
        }
        return DestinationSequence(
            style: marker.style,
            markerSpacing: marker.markerSpacing,
            taskSpacing: marker.taskSpacing,
            nextOrdinal: nextOrdinal
        )
    }

    private static func sequence(
        startingWith marker: ListItemMarker,
        restartsOrdered: Bool
    ) -> DestinationSequence {
        let nextOrdinal: Int
        switch marker.style.base {
        case .ordered:
            nextOrdinal = restartsOrdered ? 1 : max(1, marker.number ?? 1)
        case .unordered:
            nextOrdinal = 1
        }
        return DestinationSequence(
            style: marker.style,
            markerSpacing: marker.markerSpacing,
            taskSpacing: marker.taskSpacing,
            nextOrdinal: nextOrdinal
        )
    }

    private static func markerSyntax(
        for sequence: DestinationSequence,
        sourceMarker: ListItemMarker
    ) -> String {
        let base: String
        switch sequence.style.base {
        case .ordered(let delimiter):
            base = "\(sequence.nextOrdinal)\(delimiter)"
        case .unordered(let marker):
            base = marker
        }

        if sequence.style.isTask {
            return base
                + sequence.markerSpacing
                + "[\(sourceMarker.taskState ?? " ")]"
                + (sequence.taskSpacing ?? " ")
        }
        return base + sequence.markerSpacing
    }

    private static func advance(_ sequence: inout DestinationSequence) {
        if case .ordered = sequence.style.base {
            sequence.nextOrdinal = incrementingOrdinal(sequence.nextOrdinal)
        }
    }

    private static func orderedContinuationOrdinal(
        in source: NSString,
        before lineStart: Int,
        prefix: String,
        style: ListStyle,
        fallbackOrdinal: Int,
        ignoringLineLocations: Set<Int>
    ) -> Int {
        let targetPosition = structuralPosition(of: prefix)
        var searchEnd = lineStart
        while searchEnd > 0 {
            let previousRange = source.lineRange(for: NSRange(
                location: searchEnd - 1,
                length: 0
            ))
            guard previousRange.location < searchEnd else { break }
            if ignoringLineLocations.contains(previousRange.location) {
                searchEnd = previousRange.location
                continue
            }
            let previousLine = content(of: previousRange, source: source)

            if previousLine.length == 0 {
                searchEnd = previousRange.location
                continue
            }
            if let marker = listItemMarker(in: previousLine) {
                if structuralPosition(of: marker.structuralPrefix) == targetPosition {
                    guard belongsToSameOrderedRun(marker.style, style) else {
                        return max(1, fallbackOrdinal)
                    }
                    return incrementingOrdinal(max(0, marker.number ?? 0))
                }

                let position = structuralPosition(of: marker.structuralPrefix)
                if position.quotePath != targetPosition.quotePath
                    || position.indentation < targetPosition.indentation {
                    break
                }
            } else if let linePrefix = blockPrefixString(in: previousLine) {
                let position = structuralPosition(of: linePrefix)
                if position.quotePath != targetPosition.quotePath
                    || position.indentation <= targetPosition.indentation {
                    break
                }
            }
            searchEnd = previousRange.location
        }
        return max(1, fallbackOrdinal)
    }

    private static func orderedRunMutations(
        in source: NSString,
        startingAt start: Int,
        impact: OrderedRunImpact,
        ignoringLineLocations: Set<Int>
    ) -> [Mutation] {
        let targetPosition = structuralPosition(of: impact.prefix)
        var mutations: [Mutation] = []
        var nextOrdinal = impact.nextOrdinal
        var location = start

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            guard lineRange.location == location, lineRange.length > 0 else { break }
            if ignoringLineLocations.contains(lineRange.location) {
                location = NSMaxRange(lineRange)
                continue
            }
            let line = content(of: lineRange, source: source)
            defer { location = NSMaxRange(lineRange) }

            if line.length == 0 { continue }
            if let marker = listItemMarker(in: line) {
                if structuralPosition(of: marker.structuralPrefix) == targetPosition {
                    guard belongsToSameOrderedRun(marker.style, impact.style),
                          let numberRange = marker.numberRange else { break }
                    let replacement = String(nextOrdinal)
                    if line.substring(with: numberRange) != replacement {
                        mutations.append(Mutation(
                            range: NSRange(
                                location: lineRange.location + numberRange.location,
                                length: numberRange.length
                            ),
                            replacement: replacement
                        ))
                    }
                    nextOrdinal = incrementingOrdinal(nextOrdinal)
                    continue
                }

                let position = structuralPosition(of: marker.structuralPrefix)
                guard position.quotePath == targetPosition.quotePath,
                      position.indentation > targetPosition.indentation else { break }
                continue
            }

            guard let linePrefix = blockPrefixString(in: line) else { break }
            let position = structuralPosition(of: linePrefix)
            guard position.quotePath == targetPosition.quotePath,
                  position.indentation > targetPosition.indentation else { break }
        }
        return mutations
    }

    private static func incrementingOrdinal(_ ordinal: Int) -> Int {
        ordinal == Int.max ? ordinal : ordinal + 1
    }

    private static func belongsToSameOrderedRun(
        _ lhs: ListStyle,
        _ rhs: ListStyle
    ) -> Bool {
        guard case .ordered(let lhsDelimiter) = lhs.base,
              case .ordered(let rhsDelimiter) = rhs.base else { return false }
        return lhsDelimiter == rhsDelimiter
    }

    private static func appendUnique(
        _ candidates: [Mutation],
        to mutations: inout [Mutation]
    ) {
        for candidate in candidates where !mutations.contains(where: {
            $0.range == candidate.range
        }) {
            mutations.append(candidate)
        }
    }

    private static func clearSequencesDeeper(
        than targetPosition: StructuralPosition,
        sequences: inout [StructuralPosition: DestinationSequence]
    ) {
        for key in Array(sequences.keys)
        where key != targetPosition
            && (key.quoteDepth > targetPosition.quoteDepth
                || (key.quoteDepth == targetPosition.quoteDepth
                    && key.indentation > targetPosition.indentation)) {
            sequences.removeValue(forKey: key)
        }
    }

    private static func removing(_ range: NSRange, from prefix: String) -> String {
        let mutable = NSMutableString(string: prefix)
        guard NSMaxRange(range) <= mutable.length else { return prefix }
        mutable.deleteCharacters(in: range)
        return mutable as String
    }

    private static func mutationPrecedes(_ lhs: Mutation, _ rhs: Mutation) -> Bool {
        if lhs.range.location != rhs.range.location {
            return lhs.range.location < rhs.range.location
        }
        // Insertions precede replacements so reverse application rewrites the
        // original marker before inserting indentation at the same location.
        return lhs.range.length < rhs.range.length
    }

    private static func rangeIncludingDescendants(
        of lineRange: NSRange,
        in source: NSString
    ) -> NSRange {
        let line = content(of: lineRange, source: source)
        guard let rootMarker = listItemMarker(in: line) else { return lineRange }

        var end = NSMaxRange(lineRange)
        var candidateEnd = end
        while candidateEnd < source.length {
            let nextRange = source.lineRange(for: NSRange(location: candidateEnd, length: 0))
            guard nextRange.location == candidateEnd, nextRange.length > 0 else { break }
            let nextLine = content(of: nextRange, source: source)
            if nextLine.length == 0 {
                candidateEnd = NSMaxRange(nextRange)
                continue
            }

            let nextPrefix: String?
            if let marker = listItemMarker(in: nextLine) {
                nextPrefix = marker.structuralPrefix
            } else {
                nextPrefix = blockPrefixString(in: nextLine)
            }
            guard let nextPrefix,
                  isStructurallyDeeper(nextPrefix, than: rootMarker.structuralPrefix) else {
                break
            }
            end = NSMaxRange(nextRange)
            candidateEnd = end
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    private static func structuralPosition(of prefix: String) -> StructuralPosition {
        var quoteDepth = 0
        var whitespaceWidth = 0
        for character in prefix {
            if character == ">" {
                quoteDepth += 1
            } else if character == "\t" {
                whitespaceWidth += 4
            } else {
                whitespaceWidth += 1
            }
        }
        return StructuralPosition(
            quotePath: String(repeating: ">", count: quoteDepth),
            quoteDepth: quoteDepth,
            indentation: max(0, whitespaceWidth - quoteDepth)
        )
    }

    private static func isStructurallyDeeper(_ prefix: String, than parent: String) -> Bool {
        let position = structuralPosition(of: prefix)
        let parentPosition = structuralPosition(of: parent)
        return position.quoteDepth >= parentPosition.quoteDepth
            && position.indentation > parentPosition.indentation
    }

    private static func blockPrefixString(in line: NSString) -> String? {
        let range = NSRange(location: 0, length: line.length)
        guard let match = blockPrefix.firstMatch(in: line as String, range: range) else {
            return nil
        }
        return line.substring(with: match.range(at: 1))
    }

    private static func containsRecognizedListMarker(
        _ lineRange: NSRange,
        markers: [MarkdownSyntaxSpan]
    ) -> Bool {
        markers.contains { marker in
            marker.range.location >= lineRange.location
                && marker.range.location < NSMaxRange(lineRange)
        }
    }

    private static func blockPrefixLength(in line: NSString) -> Int? {
        let range = NSRange(location: 0, length: line.length)
        return blockPrefix.firstMatch(in: line as String, range: range)?.range(at: 1).length
    }

    /// Removes indentation nearest the list/content while preserving one
    /// separator character after a blockquote marker.
    private static func indentInsertionOffset(
        in prefix: NSString,
        afterQuoteDepth quoteDepth: Int
    ) -> Int {
        guard quoteDepth > 0 else {
            var cursor = 0
            while cursor < prefix.length,
                  isIndentUnit(prefix.character(at: cursor)) {
                cursor += 1
            }
            return cursor
        }

        var cursor = 0
        var consumedQuotes = 0
        while cursor < prefix.length, consumedQuotes < quoteDepth {
            if prefix.character(at: cursor) == 62 { // `>`
                consumedQuotes += 1
            }
            cursor += 1
        }
        if consumedQuotes == quoteDepth,
           cursor < prefix.length,
           isIndentUnit(prefix.character(at: cursor)) {
            cursor += 1
        }
        return cursor
    }

    private static func removableIndent(
        in prefix: NSString,
        afterQuoteDepth quoteDepth: Int? = nil
    ) -> NSRange? {
        let effectiveQuoteDepth = quoteDepth ?? prefix
            .substring(with: NSRange(location: 0, length: prefix.length))
            .filter { $0 == ">" }
            .count
        var start = 0
        var consumedQuotes = 0
        while start < prefix.length, consumedQuotes < effectiveQuoteDepth {
            if prefix.character(at: start) == 62 { // `>`
                consumedQuotes += 1
            }
            start += 1
        }
        if effectiveQuoteDepth > 0,
           consumedQuotes == effectiveQuoteDepth,
           start < prefix.length,
           isIndentUnit(prefix.character(at: start)) {
            start += 1
        }
        guard start < prefix.length else { return nil }

        if prefix.character(at: start) == 9 {
            return NSRange(location: start, length: 1)
        }

        var length = 0
        while start + length < prefix.length,
              length < 4,
              prefix.character(at: start + length) == 32 {
            length += 1
        }
        if length > 0 {
            return NSRange(location: start, length: length)
        }

        // Tolerate mixed whitespace without removing any visible content.
        let tab = prefix.range(of: "\t", options: [], range: NSRange(
            location: start,
            length: prefix.length - start
        ))
        return tab.location == NSNotFound ? nil : tab
    }

    private static func mapped(_ position: Int, through mutations: [Mutation]) -> Int {
        var delta = 0
        for mutation in mutations {
            let start = mutation.range.location
            let end = NSMaxRange(mutation.range)
            let insertedLength = (mutation.replacement as NSString).length
            if position < start { break }

            if mutation.range.length == 0 {
                delta += insertedLength
            } else if position == start {
                return start + delta
            } else if position <= end {
                return start + delta + insertedLength
            } else {
                delta += insertedLength - mutation.range.length
            }
        }
        return position + delta
    }

    private static func isIndentUnit(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9
    }

    private static func clamped(_ range: NSRange, toUTF16Length length: Int) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), length - location)
        )
    }
}

/// Applies the paired NSTextView/NSTextContainer/NSScrollView settings needed
/// for switching between wrapped and horizontally scrolling text.
@MainActor
enum MarkdownEditorLayout {
    static func applyWordWrap(
        _ enabled: Bool,
        to textView: NSTextView,
        in scrollView: NSScrollView
    ) {
        guard let textContainer = textView.textContainer else { return }

        scrollView.hasHorizontalScroller = !enabled
        scrollView.horizontalScrollElasticity = enabled ? .none : .automatic
        textView.isHorizontallyResizable = !enabled
        textView.autoresizingMask = [.width]
        textContainer.widthTracksTextView = enabled
        textContainer.containerSize = NSSize(
            width: enabled
                ? wrappedContainerWidth(
                    for: max(scrollView.contentSize.width, 1),
                    textView: textView
                )
                : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        if enabled {
            var frame = textView.frame
            frame.origin = .zero
            frame.size.width = max(scrollView.contentSize.width, 1)
            textView.frame = frame

            // A horizontal offset is meaningless once wrapping is restored.
            let clipView = scrollView.contentView
            let proposed = NSPoint(x: 0, y: clipView.bounds.minY)
            clipView.scroll(to: clipView.constrainBoundsRect(
                NSRect(origin: proposed, size: clipView.bounds.size)
            ).origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        if let layoutManager = textView.layoutManager {
            let fullRange = NSRange(
                location: 0,
                length: (textView.string as NSString).length
            )
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            layoutManager.ensureLayout(for: textContainer)

            if !enabled {
                let usedRect = layoutManager.usedRect(for: textContainer)
                var frame = textView.frame
                frame.size.width = max(
                    scrollView.contentSize.width,
                    ceil(usedRect.maxX + textView.textContainerInset.width * 2)
                )
                textView.frame = frame
            }
        }

        scrollView.tile()
        if enabled {
            synchronizeWrappedWidth(of: textView, in: scrollView)
        }
    }

    /// Reconciles the wrapped text container with the viewport after AppKit
    /// lays out a previously zero-sized SwiftUI representable.
    static func synchronizeWrappedWidth(
        of textView: NSTextView,
        in scrollView: NSScrollView
    ) {
        guard let textContainer = textView.textContainer,
              textContainer.widthTracksTextView else { return }

        let width = scrollView.contentSize.width
        guard width > 1 else { return }
        let containerWidth = wrappedContainerWidth(for: width, textView: textView)
        let hadDisplacedOrigin = abs(textView.frame.origin.x) > 0.5
            || abs(textView.frame.origin.y) > 0.5
        guard abs(textView.frame.width - width) > 0.5
                || abs(textContainer.containerSize.width - containerWidth) > 0.5
                || hadDisplacedOrigin else { return }

        var frame = textView.frame
        frame.origin = .zero
        frame.size.width = width
        textView.frame = frame
        textContainer.containerSize = NSSize(
            width: containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let layoutManager = textView.layoutManager {
            layoutManager.invalidateLayout(
                forCharacterRange: NSRange(
                    location: 0,
                    length: (textView.string as NSString).length
                ),
                actualCharacterRange: nil
            )
            layoutManager.ensureLayout(for: textContainer)
            layoutManager.invalidateDisplay(
                forCharacterRange: NSRange(
                    location: 0,
                    length: (textView.string as NSString).length
                )
            )
        }

        // NSTextView can preserve its old bottom edge while reflowing from a
        // wide editor into a split pane, which gives the document view a large
        // negative Y origin and leaves every glyph outside the clip view.
        if textView.frame.origin != .zero {
            textView.setFrameOrigin(.zero)
        }
        if hadDisplacedOrigin {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        let clipView = scrollView.contentView
        let proposed = NSRect(
            x: 0,
            y: clipView.bounds.minY,
            width: clipView.bounds.width,
            height: clipView.bounds.height
        )
        clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clipView)
        textView.needsDisplay = true
    }

    private static func wrappedContainerWidth(
        for viewWidth: CGFloat,
        textView: NSTextView
    ) -> CGFloat {
        max(viewWidth - (textView.textContainerInset.width * 2), 1)
    }
}
