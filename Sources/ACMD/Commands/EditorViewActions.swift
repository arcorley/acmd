import SwiftUI

/// View and navigation commands that belong to the active document window,
/// even when keyboard focus is currently in the rendered preview.
struct EditorViewActions {
    let fontSize: CGFloat
    let canZoomIn: Bool
    let canZoomOut: Bool
    let isDefaultZoom: Bool
    let wrapsLines: Bool
    let showsLineNumbers: Bool
    let currentLine: Int
    let totalLineCount: Int

    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let toggleLineWrapping: () -> Void
    let toggleLineNumbers: () -> Void
    let goToLine: (Int) -> Void
    let focusEditor: () -> Void
}

private struct EditorViewActionsFocusedKey: FocusedValueKey {
    typealias Value = EditorViewActions
}

extension FocusedValues {
    var editorViewActions: EditorViewActions? {
        get { self[EditorViewActionsFocusedKey.self] }
        set { self[EditorViewActionsFocusedKey.self] = newValue }
    }
}
