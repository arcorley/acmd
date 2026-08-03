import AppKit
import Combine
import ACMDCore

/// The command-facing state for the currently active Markdown text view.
///
/// The controller deliberately does not own the text view. SwiftUI owns the
/// editor's lifetime and attaches/detaches it as views are created and removed.
@MainActor
final class MarkdownEditorController: ObservableObject {
    private struct State: Equatable {
        var isEditorAvailable: Bool
        var isEditable: Bool
        var selectedRange: NSRange
        var canUndo: Bool
        var canRedo: Bool

        static let unavailable = State(
            isEditorAvailable: false,
            isEditable: false,
            selectedRange: NSRange(location: 0, length: 0),
            canUndo: false,
            canRedo: false
        )
    }

    @Published private var state = State.unavailable

    var isEditorAvailable: Bool { state.isEditorAvailable }
    var isEditable: Bool { state.isEditable }
    var selectedRange: NSRange { state.selectedRange }
    var hasSelection: Bool { state.selectedRange.length > 0 }
    var canUndo: Bool { state.canUndo }
    var canRedo: Bool { state.canRedo }

    var canEdit: Bool { isEditorAvailable && isEditable }
    var canApplyFormatting: Bool { canEdit }

    private weak var textView: NSTextView?
    private var rememberedSelection = NSRange(location: 0, length: 0)
    private var hasRememberedSelection = false
    private var pendingState: State?
    private var isStateUpdateScheduled = false

    private struct EditorSnapshot {
        let text: String
        let selection: NSRange
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
            self.textView = textView
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
        self.textView = nil
        scheduleState(State(
            isEditorAvailable: false,
            isEditable: false,
            selectedRange: rememberedSelection,
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
        let range = Self.clamped(
            textView.selectedRange(),
            toUTF16Length: (textView.string as NSString).length
        )
        scheduleState(State(
            isEditorAvailable: true,
            isEditable: textView.isEditable,
            selectedRange: range,
            canUndo: textView.undoManager?.canUndo ?? false,
            canRedo: textView.undoManager?.canRedo ?? false
        ))
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
