import SwiftUI

enum EditorLayoutMode: String, CaseIterable, Identifiable {
    case editor
    case split
    case preview

    var id: Self { self }

    var title: String {
        switch self {
        case .editor: "Editor"
        case .split: "Split"
        case .preview: "Preview"
        }
    }

    var symbolName: String {
        switch self {
        case .editor: "square.and.pencil"
        case .split: "rectangle.split.2x1"
        case .preview: "doc.richtext"
        }
    }
}

private struct EditorLayoutModeFocusedKey: FocusedValueKey {
    typealias Value = Binding<EditorLayoutMode>
}

extension FocusedValues {
    var editorLayoutMode: Binding<EditorLayoutMode>? {
        get { self[EditorLayoutModeFocusedKey.self] }
        set { self[EditorLayoutModeFocusedKey.self] = newValue }
    }
}
