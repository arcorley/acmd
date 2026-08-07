import AppKit
import Combine
import ACMDCore

/// The command-facing state for the currently active Markdown text view.
///
/// The controller deliberately does not own the text view. SwiftUI owns the
/// editor's lifetime and attaches/detaches it as views are created and removed.
@MainActor
final class MarkdownEditorController: ObservableObject {
    static let defaultFontSize: CGFloat = 14
    static let minimumFontSize: CGFloat = 9
    static let maximumFontSize: CGFloat = 32
    static let fontSizeStep: CGFloat = 1

    private struct State: Equatable {
        var isEditorAvailable: Bool
        var isEditable: Bool
        var selectedRange: NSRange
        var caretLine: Int
        var caretColumn: Int
        var totalLineCount: Int
        var selectedCharacterCount: Int
        var canUndo: Bool
        var canRedo: Bool

        static let unavailable = State(
            isEditorAvailable: false,
            isEditable: false,
            selectedRange: NSRange(location: 0, length: 0),
            caretLine: 1,
            caretColumn: 1,
            totalLineCount: 1,
            selectedCharacterCount: 0,
            canUndo: false,
            canRedo: false
        )
    }

    @Published private var state = State.unavailable
    @Published private(set) var fontSize = MarkdownEditorController.defaultFontSize
    @Published private(set) var isWordWrapEnabled = true
    @Published private(set) var showsLineNumbers = true

    var isEditorAvailable: Bool { state.isEditorAvailable }
    var isEditable: Bool { state.isEditable }
    var selectedRange: NSRange { state.selectedRange }
    var hasSelection: Bool { state.selectedRange.length > 0 }
    var caretLine: Int { state.caretLine }
    var caretColumn: Int { state.caretColumn }
    var currentLine: Int { state.caretLine }
    var currentColumn: Int { state.caretColumn }
    var totalLineCount: Int { state.totalLineCount }
    var selectedCharacterCount: Int { state.selectedCharacterCount }
    var canUndo: Bool { state.canUndo }
    var canRedo: Bool { state.canRedo }

    var canZoomIn: Bool { fontSize < Self.maximumFontSize }
    var canZoomOut: Bool { fontSize > Self.minimumFontSize }
    var isDefaultZoom: Bool { fontSize == Self.defaultFontSize }
    var zoomPercentage: Int {
        Int((fontSize / Self.defaultFontSize * 100).rounded())
    }

    var canEdit: Bool { isEditorAvailable && isEditable }
    var canApplyFormatting: Bool { canEdit }

    private weak var textView: NSTextView?
    private var rememberedSelection = NSRange(location: 0, length: 0)
    private var hasRememberedSelection = false
    private var pendingState: State?
    private var isStateUpdateScheduled = false
    private var cachedLineStarts: [Int]?
    private var textStorageObserver: NSObjectProtocol?

    /// Exposed to regression tests so caret-only updates cannot silently
    /// regress to scanning the entire document again.
    private(set) var lineStartScanCount = 0

    private struct EditorSnapshot {
        let text: String
        let selection: NSRange
    }

    deinit {
        if let textStorageObserver {
            NotificationCenter.default.removeObserver(textStorageObserver)
        }
    }

    /// Applies a Markdown formatting command using the text view's native edit
    /// path, so the change participates in AppKit undo and redo.
    func perform(_ command: MarkdownFormatCommand) {
        guard let textView, textView.isEditable else { return }

        let originalText = textView.string
        let originalSelection = Self.clamped(
            textView.selectedRange(),
            toUTF16Length: (originalText as NSString).length
        )
        let result = MarkdownFormatter.apply(
            command: command,
            to: originalText,
            selection: originalSelection
        )
        let resultSelection = Self.clamped(
            result.selection,
            toUTF16Length: (result.text as NSString).length
        )

        let before = EditorSnapshot(text: originalText, selection: originalSelection)
        let after = EditorSnapshot(text: result.text, selection: resultSelection)
        let actionName = command.undoActionName

        textView.breakUndoCoalescing()
        guard apply(after, to: textView) else { return }

        if result.text != originalText, let undoManager = textView.undoManager {
            undoManager.registerUndo(withTarget: self) { controller in
                controller.restore(before, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }

        rememberedSelection = resultSelection
        focus()
        refreshState(from: textView)
    }

    /// A named variant that reads naturally from command/menu implementations.
    func perform(command: MarkdownFormatCommand) {
        perform(command)
    }

    /// Compatibility spelling for toolbar call sites.
    func apply(_ command: MarkdownFormatCommand) {
        perform(command)
    }

    func focus() {
        guard let textView else { return }
        if let window = textView.window {
            window.makeFirstResponder(textView)
        } else {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    /// Removes keyboard focus when the editor is visually collapsed, avoiding
    /// invisible edits while the rendered preview is the only visible pane.
    func resignFocus() {
        guard let textView, let window = textView.window,
              window.firstResponder === textView else { return }
        window.makeFirstResponder(nil)
    }

    func showFind() {
        guard let textView else { return }
        focus()

        // NSTextFinder reads its action from the sender's tag.
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        DispatchQueue.main.async { [weak textView] in
            textView?.performTextFinderAction(item)
        }
    }

    func find() {
        showFind()
    }

    // MARK: - Editor display

    func zoomIn() {
        setFontSize(fontSize + Self.fontSizeStep)
    }

    func zoomOut() {
        setFontSize(fontSize - Self.fontSizeStep)
    }

    func resetZoom() {
        setFontSize(Self.defaultFontSize)
    }

    func setFontSize(_ requestedSize: CGFloat) {
        let size = min(max(requestedSize, Self.minimumFontSize), Self.maximumFontSize)
        guard fontSize != size else { return }
        fontSize = size
    }

    func toggleWordWrap() {
        isWordWrapEnabled.toggle()
    }

    func setWordWrapEnabled(_ enabled: Bool) {
        guard isWordWrapEnabled != enabled else { return }
        isWordWrapEnabled = enabled
    }

    func toggleLineNumbers() {
        showsLineNumbers.toggle()
    }

    func setShowsLineNumbers(_ showsLineNumbers: Bool) {
        guard self.showsLineNumbers != showsLineNumbers else { return }
        self.showsLineNumbers = showsLineNumbers
    }

    /// Moves the insertion point to a one-based logical line, reveals it, and
    /// focuses the editor. Out-of-range values select the nearest valid line.
    @discardableResult
    func goToLine(_ line: Int) -> Bool {
        guard let textView else { return false }

        let location = MarkdownEditorTextMetrics.location(ofLine: line, in: textView.string)
        let range = NSRange(location: location, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        rememberedSelection = range
        hasRememberedSelection = true
        focus()
        refreshState(from: textView)
        return true
    }

    func undo() {
        guard let textView, let undoManager = textView.undoManager, undoManager.canUndo else { return }
        undoManager.undo()
        rememberSelection(from: textView)
        refreshState(from: textView)
    }

    func redo() {
        guard let textView, let undoManager = textView.undoManager, undoManager.canRedo else { return }
        undoManager.redo()
        rememberSelection(from: textView)
        refreshState(from: textView)
    }

    /// Stores the editor selection for view recreation or temporary focus loss.
    func preserveSelection() {
        guard let textView else { return }
        rememberSelection(from: textView)
    }

    /// Restores the most recently observed selection and focuses the editor.
    func restoreSelection() {
        guard let textView else { return }
        restoreSelection(in: textView)
        focus()
    }

    // MARK: - View lifecycle

    func attach(to textView: NSTextView) {
        if self.textView !== textView {
            if let current = self.textView {
                rememberSelection(from: current)
            }
            stopObservingTextStorage()
            self.textView = textView
            cachedLineStarts = nil
            observeTextStorage(of: textView)
            if hasRememberedSelection {
                restoreSelection(in: textView)
            } else {
                rememberSelection(from: textView)
            }
        }
        refreshState(from: textView)
    }

    func detach(from textView: NSTextView) {
        guard self.textView === textView else { return }
        rememberSelection(from: textView)
        let text = textView.string
        let lineStarts = lineStarts(for: textView, text: text)
        let metrics = MarkdownEditorTextMetrics.measure(
            text: text,
            selection: rememberedSelection,
            lineStarts: lineStarts
        )
        stopObservingTextStorage()
        self.textView = nil
        cachedLineStarts = nil
        scheduleState(State(
            isEditorAvailable: false,
            isEditable: false,
            selectedRange: rememberedSelection,
            caretLine: metrics.line,
            caretColumn: metrics.column,
            totalLineCount: lineStarts.count,
            selectedCharacterCount: metrics.selectedCharacterCount,
            canUndo: false,
            canRedo: false
        ))
    }

    func editorStateDidChange(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        rememberSelection(from: textView)
        refreshState(from: textView)
    }

    private func rememberSelection(from textView: NSTextView) {
        let range = Self.clamped(
            textView.selectedRange(),
            toUTF16Length: (textView.string as NSString).length
        )
        rememberedSelection = range
        hasRememberedSelection = true
    }

    private func restoreSelection(in textView: NSTextView) {
        let range = Self.clamped(
            rememberedSelection,
            toUTF16Length: (textView.string as NSString).length
        )
        textView.setSelectedRange(range)
        rememberedSelection = range
        hasRememberedSelection = true
    }

    private func refreshState(from textView: NSTextView) {
        let text = textView.string
        let range = Self.clamped(
            textView.selectedRange(),
            toUTF16Length: (text as NSString).length
        )
        let lineStarts = lineStarts(for: textView, text: text)
        let metrics = MarkdownEditorTextMetrics.measure(
            text: text,
            selection: range,
            focusLocation: (textView as? MarkdownNavigationTextView)?
                .selectionFocusLocation,
            lineStarts: lineStarts
        )
        scheduleState(State(
            isEditorAvailable: true,
            isEditable: textView.isEditable,
            selectedRange: range,
            caretLine: metrics.line,
            caretColumn: metrics.column,
            totalLineCount: lineStarts.count,
            selectedCharacterCount: metrics.selectedCharacterCount,
            canUndo: textView.undoManager?.canUndo ?? false,
            canRedo: textView.undoManager?.canRedo ?? false
        ))
    }

    private func lineStarts(for textView: NSTextView, text: String) -> [Int] {
        if self.textView === textView, let cachedLineStarts {
            return cachedLineStarts
        }

        let lineStarts = EditorSourceMapper.lineStarts(in: text)
        if self.textView === textView {
            cachedLineStarts = lineStarts
        }
        lineStartScanCount += 1
        return lineStarts
    }

    private func observeTextStorage(of textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        textStorageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: .main
        ) { [weak self, weak textView] notification in
            guard let textStorage = notification.object as? NSTextStorage,
                  textStorage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                guard let self, let textView, self.textView === textView else { return }
                self.cachedLineStarts = nil
            }
        }
    }

    private func stopObservingTextStorage() {
        guard let textStorageObserver else { return }
        NotificationCenter.default.removeObserver(textStorageObserver)
        self.textStorageObserver = nil
    }

    /// NSViewRepresentable lifecycle methods run during SwiftUI updates. Defer
    /// and coalesce publication to avoid recursive view-update cycles.
    private func scheduleState(_ newState: State) {
        if pendingState == newState || (pendingState == nil && state == newState) {
            return
        }
        pendingState = newState
        guard !isStateUpdateScheduled else { return }
        isStateUpdateScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStateUpdateScheduled = false
            guard let pendingState = self.pendingState else { return }
            self.pendingState = nil
            if self.state != pendingState {
                self.state = pendingState
            }
        }
    }

    /// Restores both text and selection as one undo-manager operation. AppKit's
    /// stock insertion undo restores text but not a formatter's semantic
    /// selection, so formatting commands keep their own compact snapshots.
    private func restore(_ snapshot: EditorSnapshot, actionName: String) {
        guard let textView else { return }
        let inverse = EditorSnapshot(
            text: textView.string,
            selection: Self.clamped(
                textView.selectedRange(),
                toUTF16Length: (textView.string as NSString).length
            )
        )
        guard apply(snapshot, to: textView) else { return }

        if let undoManager = textView.undoManager {
            undoManager.registerUndo(withTarget: self) { controller in
                controller.restore(inverse, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
        rememberedSelection = snapshot.selection
        refreshState(from: textView)
    }

    /// Applies a snapshot through NSTextView's validated edit hooks while
    /// suppressing its default text-only undo registration.
    private func apply(_ snapshot: EditorSnapshot, to textView: NSTextView) -> Bool {
        let currentText = textView.string
        let targetSelection = Self.clamped(
            snapshot.selection,
            toUTF16Length: (snapshot.text as NSString).length
        )

        guard currentText != snapshot.text else {
            textView.setSelectedRange(targetSelection)
            rememberedSelection = targetSelection
            return true
        }

        let change = Self.minimalReplacement(from: currentText, to: snapshot.text)
        guard let textStorage = textView.textStorage else { return false }
        let undoManager = textView.undoManager
        let registrationWasEnabled = undoManager?.isUndoRegistrationEnabled ?? false
        if registrationWasEnabled {
            undoManager?.disableUndoRegistration()
        }

        guard textView.shouldChangeText(in: change.range, replacementString: change.replacement) else {
            if registrationWasEnabled {
                undoManager?.enableUndoRegistration()
            }
            return false
        }

        textStorage.replaceCharacters(in: change.range, with: change.replacement)
        textView.didChangeText()

        if registrationWasEnabled {
            undoManager?.enableUndoRegistration()
        }

        textView.setSelectedRange(targetSelection)
        rememberedSelection = targetSelection
        return true
    }

    private static func clamped(_ range: NSRange, toUTF16Length length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }
        let location = min(max(0, range.location), length)
        let available = length - location
        return NSRange(location: location, length: min(max(0, range.length), available))
    }

    /// Produces one replacement bounded on `Character` boundaries. Formatting
    /// changes are usually tiny; keeping the native edit tiny improves undo,
    /// spell-checking, and layout behavior for large documents.
    private static func minimalReplacement(from old: String, to new: String) -> (range: NSRange, replacement: String) {
        var oldPrefixEnd = old.startIndex
        var newPrefixEnd = new.startIndex

        while oldPrefixEnd < old.endIndex,
              newPrefixEnd < new.endIndex,
              old[oldPrefixEnd] == new[newPrefixEnd] {
            old.formIndex(after: &oldPrefixEnd)
            new.formIndex(after: &newPrefixEnd)
        }

        var oldSuffixStart = old.endIndex
        var newSuffixStart = new.endIndex
        while oldSuffixStart > oldPrefixEnd, newSuffixStart > newPrefixEnd {
            let previousOld = old.index(before: oldSuffixStart)
            let previousNew = new.index(before: newSuffixStart)
            guard old[previousOld] == new[previousNew] else { break }
            oldSuffixStart = previousOld
            newSuffixStart = previousNew
        }

        return (
            NSRange(oldPrefixEnd..<oldSuffixStart, in: old),
            String(new[newPrefixEnd..<newSuffixStart])
        )
    }
}

private extension MarkdownEditorTextMetrics {
    static func measure(
        text: String,
        selection requestedSelection: NSRange,
        focusLocation requestedFocusLocation: Int? = nil,
        lineStarts: [Int]
    ) -> Self {
        let source = text as NSString
        let selectionLocation = requestedSelection.location == NSNotFound
            ? 0
            : min(max(requestedSelection.location, 0), source.length)
        let selection = NSRange(
            location: selectionLocation,
            length: min(max(requestedSelection.length, 0), source.length - selectionLocation)
        )
        let focusLocation = min(
            max(requestedFocusLocation ?? selection.location, 0),
            source.length
        )
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

    static func characterCount(in range: NSRange, of text: String) -> Int {
        guard range.length > 0 else { return 0 }
        guard let stringRange = Range(range, in: text) else { return range.length }
        return text[stringRange].count
    }
}

private extension MarkdownFormatCommand {
    var undoActionName: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Inline Code"
        case .link: "Insert Link"
        case .image: "Insert Image"
        case .heading(let level): "Heading \(level)"
        case .unorderedList: "Bulleted List"
        case .orderedList: "Numbered List"
        case .taskList: "Task List"
        case .blockQuote: "Block Quote"
        case .codeBlock: "Code Block"
        case .horizontalRule: "Horizontal Rule"
        }
    }
}
