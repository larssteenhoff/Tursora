import AppKit

/// What `ColumnBrowser` asks its owner. The shape follows `NSBrowserDelegate`'s
/// item-based methods, which column view was first written against.
protocol ColumnBrowserDelegate: AnyObject {
    func rootItem(for browser: ColumnBrowser) -> Any?
    func browser(_ browser: ColumnBrowser, numberOfChildrenOfItem item: Any?) -> Int
    func browser(_ browser: ColumnBrowser, child index: Int, ofItem item: Any?) -> Any
    func browser(_ browser: ColumnBrowser, isLeafItem item: Any?) -> Bool
    func browser(_ browser: ColumnBrowser, objectValueForItem item: Any?) -> Any?
    func browser(_ browser: ColumnBrowser, willDisplayCell cell: NSCell, atRow row: Int, column: Int)
    func browser(_ browser: ColumnBrowser, typeSelectStringForRow row: Int, inColumn column: Int) -> String?
    func browser(_ browser: ColumnBrowser, previewViewControllerForLeafItem item: Any) -> NSViewController?
    func browser(_ browser: ColumnBrowser, shouldEditItem item: Any?) -> Bool
    func browser(_ browser: ColumnBrowser, setObjectValue object: Any?, forItem item: Any?)
    func browser(_ browser: ColumnBrowser, shouldSizeColumn column: Int, forUserResize: Bool, toWidth width: CGFloat) -> CGFloat
    func browserColumnConfigurationDidChange(_ browser: ColumnBrowser)
    // Drag out
    func browser(_ browser: ColumnBrowser, pasteboardWriterForRow row: Int, inColumn column: Int) -> NSPasteboardWriting?
    func browser(_ browser: ColumnBrowser, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                 forRows rows: IndexSet, inColumn column: Int, from table: NSTableView)
    func browser(_ browser: ColumnBrowser, draggingSessionEndedWith operation: NSDragOperation)
    // Drop in: `row` -1 means the column's own folder.
    func browser(_ browser: ColumnBrowser, validateDrop info: NSDraggingInfo, row: inout Int, column: Int) -> NSDragOperation
    func browser(_ browser: ColumnBrowser, acceptDrop info: NSDraggingInfo, row: Int, column: Int) -> Bool
}

/// Column view's columns, built from ordinary table views — one per column,
/// side by side in a horizontal scroll view — plus a preview column for a
/// single selected file. It replaces `NSBrowser`, whose item-mode columns are
/// tables owned by private AppKit code: they turned a vertical drag into a
/// multi-selection, never started the drag they agreed to, and never asked
/// for a drag image (measured in the running app). These tables drag exactly
/// as the list view does. The API mirrors the part of `NSBrowser` column view
/// used, so the controller and its checks read the same.
final class ColumnBrowser: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: ColumnBrowserDelegate?
    weak var target: AnyObject?
    var action: Selector?
    var doubleAction: Selector?
    var onZoomScroll: ((NSEvent) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    /// Escape aborted an inline rename; the controller clears its flag.
    var onRenameAborted: (() -> Void)?

    var rowHeight: CGFloat = 22 { didSet { columns.forEach { $0.table?.rowHeight = rowHeight } } }
    var minColumnWidth: CGFloat = 100
    var defaultColumnWidth: CGFloat = 245
    var menu_: NSMenu?
    override var menu: NSMenu? {
        get { menu_ }
        set { menu_ = newValue; columns.forEach { $0.table?.menu = newValue } }
    }

    private final class Column {
        let parent: Any
        let pane: NSView
        let scroll: NSScrollView?
        let table: ColumnTable?
        let preview: NSViewController?
        var width: CGFloat
        init(parent: Any, pane: NSView, scroll: NSScrollView?, table: ColumnTable?, preview: NSViewController?, width: CGFloat) {
            self.parent = parent; self.pane = pane; self.scroll = scroll; self.table = table; self.preview = preview; self.width = width
        }
    }
    private var columns: [Column] = []
    private let scrollView = NSScrollView()
    private let container = FlippedView()
    private var isSelectingProgrammatically = false
    private var previewGeneration = 0
    private var clickedTable: ColumnTable?
    private var localDragMask: NSDragOperation = [.copy, .move, .generic]
    private var remoteDragMask: NSDragOperation = [.copy, .move, .link, .generic]
    private static let resizeHandleWidth: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = container
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Events

    override func scrollWheel(with event: NSEvent) {
        if ZoomGestureAccumulator.isZoomScroll(event.modifierFlags) { onZoomScroll?(event) }
        else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) { onMagnify?(event.magnification) }

    /// Escape while renaming cancels the edit; otherwise it continues up the
    /// chain (the pane clears its filter on Escape).
    override func cancelOperation(_ sender: Any?) {
        let owner = window?.fieldEditor(false, for: nil)?.delegate as? NSControl
        if owner?.abortEditing() == true {
            onRenameAborted?()
            window?.makeFirstResponder(focusTable ?? self)
        } else {
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let table = focusTable { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(table) } }
        return true
    }

    /// The table that should have the keyboard: the deepest column holding a
    /// selection, or the first.
    var focusTable: NSTableView? {
        let column = selectedColumn
        return (column >= 0 ? columns[column].table : nil) ?? columns.first?.table
    }

    override func keyDown(with event: NSEvent) {
        if let table = (window?.firstResponder as? ColumnTable).flatMap({ t in columns.contains { $0.table === t } ? t : nil }) ?? focusTable as? ColumnTable {
            table.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Columns

    func loadColumnZero() {
        let keptWidths = columns.map(\.width)
        truncate(after: -1)
        guard let root = delegate?.rootItem(for: self) else { return }
        appendColumn(parent: root, preferredWidth: keptWidths.first)
        layoutColumns()
    }

    func reloadColumn(_ column: Int) {
        guard columns.indices.contains(column), let table = columns[column].table else { return }
        isSelectingProgrammatically = true
        table.reloadData()
        isSelectingProgrammatically = false
    }

    var lastColumn: Int { columns.count - 1 }

    /// The deepest column with a selected row, or -1.
    var selectedColumn: Int {
        for index in columns.indices.reversed() {
            if let table = columns[index].table, !table.selectedRowIndexes.isEmpty { return index }
        }
        return -1
    }

    func parentForItems(inColumn column: Int) -> Any? {
        columns.indices.contains(column) ? columns[column].parent : nil
    }

    func item(atRow row: Int, inColumn column: Int) -> Any? {
        guard columns.indices.contains(column), let delegate, row >= 0,
              row < delegate.browser(self, numberOfChildrenOfItem: columns[column].parent) else { return nil }
        return delegate.browser(self, child: row, ofItem: columns[column].parent)
    }

    func selectedRowIndexes(inColumn column: Int) -> IndexSet? {
        columns.indices.contains(column) ? columns[column].table?.selectedRowIndexes : nil
    }

    /// One path per selected row of the deepest selected column, through the
    /// selected folder of every column before it.
    var selectionIndexPaths: [IndexPath] {
        let column = selectedColumn
        guard column >= 0 else { return [] }
        var prefix = IndexPath()
        for index in 0..<column {
            guard let row = columns[index].table?.selectedRowIndexes.first else { return [] }
            prefix.append(row)
        }
        return (columns[column].table?.selectedRowIndexes ?? IndexSet()).map { prefix.appending($0) }
    }

    func selectRow(_ row: Int, inColumn column: Int) { selectRowIndexes(IndexSet(integer: row), inColumn: column) }

    /// Selects rows in a column and opens what follows from it, as a click
    /// would, without sending the action.
    func selectRowIndexes(_ rows: IndexSet, inColumn column: Int) {
        guard columns.indices.contains(column), let table = columns[column].table else { return }
        isSelectingProgrammatically = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        isSelectingProgrammatically = false
        selectionDidChange(inColumn: column)
    }

    var clickedRow: Int { clickedTable?.clickedRow ?? -1 }
    var clickedColumn: Int {
        guard let clickedTable else { return -1 }
        return columns.firstIndex { $0.table === clickedTable } ?? -1
    }

    func width(ofColumn column: Int) -> CGFloat { columns.indices.contains(column) ? columns[column].width : defaultColumnWidth }

    func setWidth(_ width: CGFloat, ofColumn column: Int) {
        guard columns.indices.contains(column), columns[column].table != nil else { return }
        columns[column].width = max(minColumnWidth, width)
        layoutColumns()
    }

    func frame(ofColumn column: Int) -> NSRect {
        guard columns.indices.contains(column) else { return .zero }
        layoutSubtreeIfNeeded()
        return convert(columns[column].pane.frame, from: container)
    }

    func frame(ofRow row: Int, inColumn column: Int) -> NSRect {
        guard columns.indices.contains(column), let table = columns[column].table else { return .zero }
        layoutSubtreeIfNeeded()
        return convert(table.rect(ofRow: row), from: table)
    }

    func scrollColumnToVisible(_ column: Int) {
        guard columns.indices.contains(column) else { return }
        layoutColumns()
        container.scrollToVisible(columns[column].pane.frame)
    }

    func scrollRowToVisible(_ row: Int, inColumn column: Int) {
        guard columns.indices.contains(column) else { return }
        columns[column].table?.scrollRowToVisible(row)
    }

    func loadedCell(atRow row: Int, column: Int) -> Any? {
        guard columns.indices.contains(column), let table = columns[column].table,
              row >= 0, row < table.numberOfRows else { return nil }
        return table.preparedCell(atColumn: 0, row: row)
    }

    /// Opens the item's name for editing in its column.
    func editItem(at path: IndexPath, with event: NSEvent?, select: Bool) {
        guard let row = path.last, columns.indices.contains(path.count - 1),
              let table = columns[path.count - 1].table else { return }
        table.scrollRowToVisible(row)
        window?.makeFirstResponder(table)
        table.editColumn(0, row: row, with: event, select: select)
    }

    func setDraggingSourceOperationMask(_ mask: NSDragOperation, forLocal isLocal: Bool) {
        if isLocal { localDragMask = mask } else { remoteDragMask = mask }
        columns.forEach { $0.table?.setDraggingSourceOperationMask(mask, forLocal: isLocal) }
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        draggedTypes = newTypes
        columns.forEach { $0.table?.registerForDraggedTypes(newTypes) }
    }
    private var draggedTypes: [NSPasteboard.PasteboardType] = []

    private func appendColumn(parent: Any, preferredWidth: CGFloat? = nil) {
        let index = columns.count
        // Asked before the column counts as open, as NSBrowser does: the
        // owner lists a folder afresh when its column is not open yet, and
        // serves its snapshot once it is.
        _ = delegate?.browser(self, numberOfChildrenOfItem: parent)
        let table = ColumnTable()
        table.owner = self
        let column = NSTableColumn(identifier: .init("name"))
        let cell = ColumnRowCell(textCell: "")
        cell.isEditable = true
        cell.lineBreakMode = .byTruncatingMiddle
        column.dataCell = cell
        column.isEditable = true
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = rowHeight
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.backgroundColor = .controlBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked(_:))
        table.doubleAction = #selector(tableDoubleClicked(_:))
        table.menu = menu_
        table.verticalMotionCanBeginDrag = true
        table.setDraggingSourceOperationMask(localDragMask, forLocal: true)
        table.setDraggingSourceOperationMask(remoteDragMask, forLocal: false)
        if !draggedTypes.isEmpty { table.registerForDraggedTypes(draggedTypes) }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        let pane = NSView()
        pane.addSubview(scroll)
        let handle = ColumnResizeHandle()
        handle.owner = self
        handle.columnPane = pane
        pane.addSubview(handle)
        container.addSubview(pane)
        let suggested = preferredWidth ?? defaultColumnWidth
        let width = delegate?.browser(self, shouldSizeColumn: index, forUserResize: false, toWidth: suggested) ?? suggested
        columns.append(Column(parent: parent, pane: pane, scroll: scroll, table: table, preview: nil, width: width))
        isSelectingProgrammatically = true
        table.reloadData()
        isSelectingProgrammatically = false
    }

    private func appendPreview(parent: Any, controller: NSViewController) {
        let pane = NSView()
        let view = controller.view
        view.removeFromSuperview()
        view.autoresizingMask = [.width, .height]
        pane.addSubview(view)
        container.addSubview(pane)
        columns.append(Column(parent: parent, pane: pane, scroll: nil, table: nil, preview: controller, width: 300))
    }

    private func truncate(after column: Int) {
        while columns.count > column + 1 {
            let removed = columns.removeLast()
            if let table = removed.table, window?.firstResponder === table, column >= 0, let previous = columns[column].table {
                window?.makeFirstResponder(previous)
            }
            removed.preview?.view.removeFromSuperview()
            removed.pane.removeFromSuperview()
        }
    }

    private func selectionDidChange(inColumn column: Int) {
        guard columns.indices.contains(column), let table = columns[column].table, let delegate else { return }
        previewGeneration &+= 1
        truncate(after: column)
        let rows = table.selectedRowIndexes
        if rows.count == 1, let row = rows.first, let item = item(atRow: row, inColumn: column) {
            if delegate.browser(self, isLeafItem: item) {
                // The preview column is filled on the next pass, as NSBrowser
                // fills it when it next draws: asking for the preview starts
                // fetching a ZIP entry's bytes, which a selection alone must not.
                let generation = previewGeneration &+ 1
                previewGeneration = generation
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.previewGeneration == generation, self.columns.indices.contains(column),
                          self.columns.count == column + 1,
                          self.columns[column].table?.selectedRowIndexes == IndexSet(integer: row),
                          let controller = self.delegate?.browser(self, previewViewControllerForLeafItem: item) else { return }
                    self.appendPreview(parent: item, controller: controller)
                    self.layoutColumns()
                }
            } else {
                appendColumn(parent: item)
            }
        }
        layoutColumns()
    }

    override func layout() {
        super.layout()
        layoutColumns()
    }

    private func layoutColumns() {
        let height = max(0, scrollView.contentSize.height)
        var x: CGFloat = 0
        let visible = scrollView.contentSize.width
        for (index, column) in columns.enumerated() {
            var width = column.width
            if column.preview != nil {
                // The preview takes the rest of the visible width, at least 260 pt.
                width = max(260, visible - x)
                columns[index].width = width
            }
            column.pane.frame = NSRect(x: x, y: 0, width: width, height: height)
            if let scroll = column.scroll {
                scroll.frame = NSRect(x: 0, y: 0, width: width - 1, height: height)
            }
            column.preview?.view.frame = column.pane.bounds
            for case let handle as ColumnResizeHandle in column.pane.subviews {
                handle.frame = NSRect(x: width - Self.resizeHandleWidth, y: 0, width: Self.resizeHandleWidth, height: height)
            }
            x += width
        }
        container.frame = NSRect(x: 0, y: 0, width: max(x, visible), height: height)
        for column in columns { column.pane.needsDisplay = true }
    }

    /// A user dragged a column's right edge.
    fileprivate func resize(pane: NSView, to width: CGFloat, finished: Bool) {
        guard let index = columns.firstIndex(where: { $0.pane === pane }), columns[index].table != nil else { return }
        let allowed = delegate?.browser(self, shouldSizeColumn: index, forUserResize: true, toWidth: width) ?? width
        columns[index].width = max(minColumnWidth, allowed)
        layoutColumns()
        if finished { delegate?.browserColumnConfigurationDidChange(self) }
    }
    fileprivate func width(ofPane pane: NSView) -> CGFloat { columns.first { $0.pane === pane }?.width ?? defaultColumnWidth }

    // MARK: - Keyboard between columns

    fileprivate func moveRight(from table: ColumnTable) -> Bool {
        guard let index = columns.firstIndex(where: { $0.table === table }), index + 1 < columns.count,
              let next = columns[index + 1].table, next.numberOfRows > 0 else { return false }
        window?.makeFirstResponder(next)
        selectRowIndexes(IndexSet(integer: max(0, next.selectedRow)), inColumn: index + 1)
        sendAction()
        return true
    }

    fileprivate func moveLeft(from table: ColumnTable) -> Bool {
        guard let index = columns.firstIndex(where: { $0.table === table }), index > 0,
              let previous = columns[index - 1].table else { return false }
        window?.makeFirstResponder(previous)
        // The folder stays selected; the column to its right stays open with
        // nothing selected in it, as in Finder.
        selectRowIndexes(previous.selectedRowIndexes, inColumn: index - 1)
        sendAction()
        return true
    }

    fileprivate func noteClick(on table: ColumnTable) { clickedTable = table }

    private func sendAction() {
        if let action, let target { NSApp.sendAction(action, to: target, from: self) }
    }

    @objc private func tableClicked(_ sender: NSTableView) {
        clickedTable = sender as? ColumnTable
        sendAction()
    }

    @objc private func tableDoubleClicked(_ sender: NSTableView) {
        clickedTable = sender as? ColumnTable
        guard sender.clickedRow >= 0, let doubleAction, let target else { return }
        NSApp.sendAction(doubleAction, to: target, from: self)
    }

    private func column(of tableView: NSTableView) -> Int { columns.firstIndex { $0.table === tableView } ?? -1 }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        let index = column(of: tableView)
        guard index >= 0, let delegate else { return 0 }
        return delegate.browser(self, numberOfChildrenOfItem: columns[index].parent)
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let index = column(of: tableView)
        return delegate?.browser(self, objectValueForItem: item(atRow: row, inColumn: index))
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        let index = column(of: tableView)
        guard let cell = cell as? NSCell, let item = item(atRow: row, inColumn: index), let delegate else { return }
        (cell as? NSBrowserCell)?.isLeaf = delegate.browser(self, isLeafItem: item)
        delegate.browser(self, willDisplayCell: cell, atRow: row, column: index)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        delegate?.browser(self, typeSelectStringForRow: row, inColumn: column(of: tableView))
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        delegate?.browser(self, shouldEditItem: item(atRow: row, inColumn: column(of: tableView))) ?? false
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        delegate?.browser(self, setObjectValue: object, forItem: item(atRow: row, inColumn: column(of: tableView)))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, let table = notification.object as? NSTableView else { return }
        let index = column(of: table)
        guard index >= 0 else { return }
        selectionDidChange(inColumn: index)
        // A click sends the action itself; arrows and type-select do it here.
        if NSApp.currentEvent?.type == .keyDown { sendAction() }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        delegate?.browser(self, pasteboardWriterForRow: row, inColumn: column(of: tableView))
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        delegate?.browser(self, draggingSession: session, willBeginAt: screenPoint, forRows: rowIndexes,
                          inColumn: column(of: tableView), from: tableView)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        delegate?.browser(self, draggingSessionEndedWith: operation)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let index = column(of: tableView)
        var target = dropOperation == .on ? row : -1
        let operation = delegate?.browser(self, validateDrop: info, row: &target, column: index) ?? []
        // Highlight where the drop lands: a folder row, or the whole column.
        tableView.setDropRow(target, dropOperation: .on)
        return operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        delegate?.browser(self, acceptDrop: info, row: dropOperation == .on ? row : -1, column: column(of: tableView)) ?? false
    }
}

/// One column's table: arrows step between columns, and clicks are recorded
/// so `clickedRow` / `clickedColumn` answer for the column that was clicked.
final class ColumnTable: NSTableView {
    weak var owner: ColumnBrowser?

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .rightArrow?: if owner?.moveRight(from: self) == true { return }
        case .leftArrow?: if owner?.moveLeft(from: self) == true { return }
        default: break
        }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        owner?.noteClick(on: self)
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.noteClick(on: self)
        return super.menu(for: event)
    }
    override func scrollWheel(with event: NSEvent) {
        if ZoomGestureAccumulator.isZoomScroll(event.modifierFlags), let owner { owner.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
    override func cancelOperation(_ sender: Any?) {
        if let owner { owner.cancelOperation(sender) } else { super.cancelOperation(sender) }
    }
}

/// The strip along a column's right edge that resizes it.
final class ColumnResizeHandle: NSView {
    weak var owner: ColumnBrowser?
    weak var columnPane: NSView?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        startWidth = columnPane.flatMap { owner?.width(ofPane: $0) } ?? 0
    }
    override func mouseDragged(with event: NSEvent) {
        guard let columnPane else { return }
        owner?.resize(pane: columnPane, to: startWidth + event.locationInWindow.x - startX, finished: false)
    }
    override func mouseUp(with event: NSEvent) {
        guard let columnPane else { return }
        owner?.resize(pane: columnPane, to: startWidth + event.locationInWindow.x - startX, finished: true)
    }
}
