import Foundation

struct EditorSnapshot {
    let annotations: [Annotation]
    let overlayImages: [OverlayImageLayer]
}

struct EditorHistory {
    private(set) var undoStack: [EditorSnapshot] = []
    private(set) var redoStack: [EditorSnapshot] = []
    private let limit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(_ snapshot: EditorSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll(keepingCapacity: true)
    }

    mutating func undo(current: EditorSnapshot) -> EditorSnapshot? {
        guard let snapshot = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return snapshot
    }

    mutating func redo(current: EditorSnapshot) -> EditorSnapshot? {
        guard let snapshot = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return snapshot
    }

    mutating func reset() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }
}
