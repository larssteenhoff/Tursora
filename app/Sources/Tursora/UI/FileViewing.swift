import AppKit

/// What BrowserViewController needs from a file view, so the details list and
/// the icon grid are interchangeable. Selection, rename, drag & drop and the
/// context menu are the view's; navigation, file operations and Quick Look
/// are the browser's.
protocol FileViewing: AnyObject {
    var viewController: NSViewController { get }
    /// The view that should have keyboard focus.
    var focusView: NSView { get }

    var onOpen: ((FileItem) -> Void)? { get set }
    var onOpenInNewTab: ((FileItem) -> Void)? { get set }
    var onRenameCommitted: ((FileItem, String) -> Void)? { get set }
    var onSelectionChanged: (() -> Void)? { get set }
    var onFocus: (() -> Void)? { get set }
    var onQuickLook: (() -> Void)? { get set }
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)? { get set }
    /// Spring-loaded folders: a drag hovered over this folder long enough that
    /// the pane should open it. Never a file mutation.
    var onSpringLoad: ((URL) -> Void)? { get set }
    /// +1 / -1 from ⌘- or ⌃-scroll, or pinch.
    var onZoomGesture: ((Int) -> Void)? { get set }

    var contextMenu: NSMenu? { get set }
    /// Archive locations allow navigation and copying out, never edits or drops in.
    var isReadOnly: Bool { get set }
    /// False inside the Trash: Finder renames nothing there, but dragging an
    /// item out is still an ordinary same-volume move.
    var allowsRenaming: Bool { get set }
    var cutURLs: Set<URL> { get set }
    var selectedItems: [FileItem] { get }
    /// The displayed selection domain: list rows, icon entries or the current
    /// browser column. Group headings never become selectable files.
    var selectionScopeItems: [FileItem] { get }
    func deselectAllItems()
    /// Targets of a context-menu action: the selection if the clicked item is
    /// in it, else the clicked item alone, else nothing (background).
    var clickedItems: [FileItem] { get }
    var scrollOffset: CGFloat { get set }

    func reloadData()
    func select(name: String?)
    func select(names: [String])
    func select(urls: [URL])
    func openSelection()
    /// Open the item's name for editing. The item may have appeared in a
    /// listing that arrived in this run-loop pass, so an implementation forces
    /// whatever layout it needs before it looks for the cell. It is a no-op
    /// when no editor can be opened (no key window, item filtered out).
    func beginRename(item: FileItem)
    /// True while an inline rename is open.
    var isRenaming: Bool { get }
    /// End an open inline rename, applying the typed name or discarding it.
    /// Every `reloadData()` discards it: the view that owns the field editor
    /// is dropped by the reload, and letting the edit end by itself would
    /// commit whatever was half-typed.
    func endRename(commit: Bool)
    /// The item after the last selected one (what to select after a delete).
    func itemAfterSelection() -> FileItem?
    func setIconSize(_ size: CGFloat, showPreviews: Bool)
    func frameOnScreen(for url: URL) -> NSRect
    /// Forward a key event (Quick Look's arrow keys) to the view.
    func forwardKey(_ event: NSEvent)

    /// Folders the view shows beyond the pane's own, so a change broadcast
    /// for one of them is not filtered out. Only the column view has any.
    var displayedDirectoryURLs: [URL] { get }
}

extension FileViewing {
    var displayedDirectoryURLs: [URL] { [] }
    func deselectAllItems() { select(urls: []) }
}

/// An inline rename caught by a listing reload. Every view drops the cell that
/// owns the field editor when it reloads, so the edit cannot simply be left
/// alone: ending it would run `controlTextDidEndEditing` and commit whatever
/// was half-typed. The views capture it, end it without committing, and re-open
/// it on the item's new row once the reload and the caller's selection restore
/// have both finished (D88).
struct InlineRenameState {
    let url: URL
    let text: String
    let selection: NSRange
}

extension NSRange {
    /// A captured selection may not fit the text it is restored into.
    func clamped(toLength length: Int) -> NSRange {
        let start = min(max(location, 0), length)
        return NSRange(location: start, length: min(max(self.length, 0), length - start))
    }
}

/// ⌘- or ⌃-scroll and pinch all zoom by the status bar slider's steps
/// (Dolphin's Ctrl-wheel); shared by the list, the grid and the columns.
struct ZoomGestureAccumulator {
    private var wheel: CGFloat = 0
    private var magnification: CGFloat = 0

    /// A scroll with ⌘ or ⌃ held zooms instead of scrolling. ⌃ is Dolphin's
    /// own modifier; ⌘ is the Mac's. macOS can claim ⌃-scroll first for
    /// Accessibility zoom (System Settings → Accessibility → Zoom → "Use
    /// scroll gesture with modifier keys to zoom"), and then no window sees it.
    static func isZoomScroll(_ flags: NSEvent.ModifierFlags) -> Bool {
        let held = flags.intersection(.deviceIndependentFlagsMask)
        return held.contains(.command) || held.contains(.control)
    }

    /// One zoom step for a zoom scroll, or nil while a smooth scroll is still
    /// accumulating. A mouse wheel moves in whole notches of about one point
    /// each (`hasPreciseScrollingDeltas == false`), so each notch is one step,
    /// as a click on the slider is; a trackpad's continuous deltas accumulate.
    mutating func step(scrollingDeltaY delta: CGFloat, precise: Bool) -> Int? {
        guard !precise else { return step(scrollingDeltaY: delta) }
        guard delta != 0 else { return nil }
        wheel = 0
        return delta > 0 ? 1 : -1
    }

    mutating func step(scroll event: NSEvent) -> Int? {
        step(scrollingDeltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
    }

    /// +1 / -1 once the accumulated smooth zoom scroll reaches 8 pt, else nil.
    mutating func step(scrollingDeltaY delta: CGFloat) -> Int? { Self.step(&wheel, delta, threshold: 8) }
    /// +1 / -1 once the accumulated pinch reaches 0.12, else nil.
    mutating func step(magnification delta: CGFloat) -> Int? { Self.step(&magnification, delta, threshold: 0.12) }

    private static func step(_ total: inout CGFloat, _ delta: CGFloat, threshold: CGFloat) -> Int? {
        total += delta
        guard abs(total) >= threshold else { return nil }
        defer { total = 0 }
        return total > 0 ? 1 : -1
    }
}

/// Remembers the window's backing scale so previews re-render only when it changes.
struct BackingScaleTracker {
    private var scale: CGFloat = 2

    /// True when `window` reports a different scale than last time.
    mutating func update(from window: NSWindow?) -> Bool {
        guard let current = window?.backingScaleFactor, current != scale else { return false }
        scale = current
        return true
    }
}
