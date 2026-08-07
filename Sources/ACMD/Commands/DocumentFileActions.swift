import SwiftUI

/// File operations supplied by the active document window.
///
/// Keeping these actions in focused values makes File-menu commands route to
/// the key window without coupling them to whichever editor or preview pane
/// currently owns keyboard focus.
struct DocumentFileActions {
    let isExporting: Bool
    let exportHTML: () -> Void
    let exportPDF: () -> Void
    let printRenderedDocument: () -> Void
    let revealInFinder: (() -> Void)?
}

private struct DocumentFileActionsFocusedKey: FocusedValueKey {
    typealias Value = DocumentFileActions
}

extension FocusedValues {
    var documentFileActions: DocumentFileActions? {
        get { self[DocumentFileActionsFocusedKey.self] }
        set { self[DocumentFileActionsFocusedKey.self] = newValue }
    }
}
