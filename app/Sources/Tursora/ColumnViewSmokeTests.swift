import AppKit

/// The column view, driven through the real pane so the mode switch, the
/// browser's column chain, the preview column, the toolbar and menu, and the
/// per-folder persistence are exercised together rather than described.
enum ColumnViewSmokeTests: SmokeSuite {
    static var checkPrefix: String { "columns: " }

    static func run(_ completion: @escaping () -> Void) {
        print("== column view ==")
        modeModel()
        Task { @MainActor in
            await paneBehaviour()
            await pathBarTrail()
            completion()
        }
    }

    /// Like Finder, the path bar runs on to the column selection, file
    /// included, without moving the pane's location.
    @MainActor
    private static func pathBarTrail() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tursora-trail-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? fm.createDirectory(at: root.appendingPathComponent("Apps/Launcher"), withIntermediateDirectories: true)
        try? "x".write(to: root.appendingPathComponent("Apps/Launcher/run.txt"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: root.appendingPathComponent("Other"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let controller = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: store)
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 1200, height: 600))
        controller.window?.makeKeyAndOrderFront(nil)
        await expectEventually("trail fixture loaded") { controller.browser.model.generation > 0 }
        let pane = controller.browser
        pane.setViewMode(.columns)
        let file = root.appendingPathComponent("Apps/Launcher/run.txt")
        pane.columnView.select(urls: [file])
        await expectEventually("the file is selected three columns deep") {
            pane.columnView.selectedItems.map(\.url.lastPathComponent) == ["run.txt"]
        }
        let titles = pane.addressBar.segmentTitles
        check("the path bar runs on to the selected file, as Finder's does",
              Array(titles.suffix(4)) == [root.lastPathComponent, "Apps", "Launcher", "run.txt"], "\(titles)")
        check("showing the selection does not move the pane's location",
              pane.currentURL?.standardizedFileURL == root.standardizedFileURL
              && pane.addressBar.url?.standardizedFileURL == root.standardizedFileURL)
        pane.columnView.select(urls: [root.appendingPathComponent("Other")])
        await expectEventually("a root folder is selected") {
            pane.columnView.selectedItems.map(\.url.lastPathComponent) == ["Other"]
        }
        check("selecting a shallower folder shortens the trail",
              pane.addressBar.segmentTitles.last == "Other", "\(pane.addressBar.segmentTitles)")
        let bar = pane.addressBar
        check("path bar segments draw no outline, hovered or not", bar.controlsAreBorderlessForTesting)
        bar.usesColorIcons = true
        check("colour icons: every segment shows its own full-colour icon",
              bar.segmentIconsForTesting.allSatisfy { $0 != nil && $0?.isTemplate == false })
        bar.usesColorIcons = false
        let gray = bar.segmentIconsForTesting
        check("gray icons: only the drive or home symbol, drawn as a template",
              gray.first??.isTemplate == true && gray.dropFirst().allSatisfy { $0 == nil }, "\(gray.map { $0 != nil })")
        bar.usesColorIcons = AppPreferences.shared.pathBarColorIcons
        // List and icon views show the selection the same way.
        let top = root.appendingPathComponent("top.txt")
        try? "t".write(to: top, atomically: true, encoding: .utf8)
        pane.setViewMode(.details)
        pane.reload()
        await expectEventually("the new file is listed") { pane.model.items.contains { $0.name == "top.txt" } }
        pane.fileList.select(urls: [top])
        await expectEventually("list selection settles") { pane.fileList.selectedItems.map(\.name) == ["top.txt"] }
        check("List view: the path bar ends with the selected file",
              pane.addressBar.segmentTitles.last == "top.txt", "\(pane.addressBar.segmentTitles)")
        pane.setViewMode(.icons)
        check("Icon view keeps showing the selected file",
              pane.addressBar.segmentTitles.last == "top.txt", "\(pane.addressBar.segmentTitles)")
        pane.fileView.select(urls: [])
        check("with nothing selected the path bar shows only the location",
              pane.addressBar.segmentTitles.last == root.lastPathComponent, "\(pane.addressBar.segmentTitles)")
    }

    /// Pure model: the third mode has its own ladder, its own persisted index,
    /// and an older properties file without that index still decodes.
    private static func modeModel() {
        check("ViewMode walks all three cases",
              ViewMode.allCases == [.details, .icons, .columns])
        check("columns have their own zoom ladder and default",
              ZoomLevel.sizes(for: .columns).count == ZoomLevel.detailsSizes.count
                  && ZoomLevel.defaultIndex(for: .columns) == 1)
        var properties = DirectoryViewProperties()
        properties.viewMode = .columns
        properties.setZoomIndex(3, for: .columns)
        properties.setZoomIndex(0, for: .details)
        check("the columns zoom index is stored separately from the list's",
              properties.zoomIndex(for: .columns) == 3 && properties.zoomIndex(for: .details) == 0)
        guard let data = try? JSONEncoder().encode(properties),
              let back = try? JSONDecoder().decode(DirectoryViewProperties.self, from: data) else {
            check("view properties round-trip", false); return
        }
        check("columns mode and zoom survive a round trip",
              back.viewMode == .columns && back.zoomIndex(for: .columns) == 3)
        let legacy = Data(#"{"viewMode":"icons","detailsZoomIndex":1,"iconsZoomIndex":4}"#.utf8)
        let old = try? JSONDecoder().decode(DirectoryViewProperties.self, from: legacy)
        check("a properties file written before columns existed still decodes",
              old?.viewMode == .icons && old?.zoomIndex(for: .icons) == 4)
        check("and gets the columns default", old?.zoomIndex(for: .columns) == ZoomLevel.defaultIndex(for: .columns))
        // An unknown raw value must fall back rather than fail, as before.
        let future = Data(#"{"viewMode":"gallery"}"#.utf8)
        check("an unknown view mode falls back to the list",
              (try? JSONDecoder().decode(DirectoryViewProperties.self, from: future))?.viewMode == .details)

        check("the toolbar segment mapping is a bijection over every mode",
              ViewMode.allCases.allSatisfy { MainWindowController.mode(forSegment: MainWindowController.segment(for: $0)) == $0 })
    }

    @MainActor
    private static func paneBehaviour() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tursora-columns-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent("Docs/Notes"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try? "# Deep\n\nbody\n".write(to: root.appendingPathComponent("Docs/Notes/deep.md"), atomically: true, encoding: .utf8)
        try? "top".write(to: root.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        // A name no narrow column can fit, for the truncation check below. One
        // unbreakable word is the case that loses the name entirely.
        let longName = "quarterly-report-2026-final-draft-revision.txt"
        try? "long".write(to: root.appendingPathComponent(longName), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        // EmptyProvider lists nothing by design; columns need real folders.
        let provider = LocalFileProvider()
        let viewFile = root.appendingPathComponent("views.json")
        let store = DirectoryViewPropertiesStore(fileURL: viewFile)
        let controller = MainWindowController(provider: provider, places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: store)
        defer { controller.close(); try? store.flush() }
        controller.window?.setContentSize(NSSize(width: 1300, height: 700))
        controller.window?.makeKeyAndOrderFront(nil)
        await expectEventually("fixture loaded") { controller.browser.model.generation > 0 }
        let pane = controller.browser

        // Mode switch
        pane.setViewMode(.columns)
        check("switching to columns mounts the column view",
              pane.viewMode == .columns && pane.fileView === pane.columnView
                  && pane.columnView.view.superview != nil)
        check("the column view is the pane's focus view", pane.focusView === pane.columnView.browser)
        check("the toolbar shows the third segment selected",
              controller.selectedToolbarViewModeForTesting == .columns)
        let menuItem = menuItem(for: #selector(BrowserViewController.viewAsColumns(_:)))
        check("View ▸ as Columns exists with Finder's label and ⌥⌘3",
              menuItem?.title == "as Columns" && menuItem?.keyEquivalent == "3"
                  && menuItem?.keyEquivalentModifierMask == [.command, .option],
              "\(menuItem?.title ?? "nil") \(menuItem?.keyEquivalent ?? "")")
        if let menuItem {
            _ = pane.validateMenuItem(menuItem)
            check("the menu item is checked while columns are showing", menuItem.state == .on)
        }
        check("the mode is remembered for the folder",
              store.properties(forKey: pane.viewPropertiesKey).viewMode == .columns)

        // The root column lists the folder
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let columns = pane.columnView
        check("the root column is open", columns.openColumnCountForTesting >= 1)
        let names = Set(pane.model.nodes.map(\.item.name))
        check("the root column shows the folder's contents", names.isSuperset(of: ["Docs", "Empty", "top.txt"]), "\(names)")

        // Selecting a folder opens the next column and keeps the root put
        let docs = root.appendingPathComponent("Docs")
        columns.select(urls: [docs])
        check("selecting a folder selects it", columns.selectedItems.map(\.url.lastPathComponent) == ["Docs"],
              "\(columns.selectedItems.map(\.url.lastPathComponent))")
        check("and opens a second column", columns.openColumnCountForTesting >= 2, "\(columns.openColumnCountForTesting)")
        check("selecting never navigates the pane: the root stays the location",
              pane.currentURL?.standardizedFileURL == root.standardizedFileURL,
              pane.currentURL?.path ?? "nil")
        check("the open child folder is reported for change broadcasts",
              columns.displayedDirectoryURLs.map { $0.standardizedFileURL } == [docs.standardizedFileURL],
              "\(columns.displayedDirectoryURLs.map(\.lastPathComponent))")

        // A deeper selection walks the chain
        let deep = root.appendingPathComponent("Docs/Notes/deep.md")
        columns.select(urls: [deep])
        check("a deep file can be selected through the chain",
              columns.selectedItems.map(\.url.lastPathComponent) == ["deep.md"],
              "\(columns.selectedItems.map(\.url.lastPathComponent))")
        check("its ancestors are all open as columns",
              columns.openColumnCountForTesting >= 3, "\(columns.openColumnCountForTesting)")
        func real(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        check("the pane's selection reads through the column view",
              pane.fileView.selectedItems.map { real($0.url) } == [real(deep)],
              "\(pane.fileView.selectedItems.map(\.url.path)) vs \(deep.path)")

        // The pane's selection round-trips through the generic API
        pane.fileView.select(urls: [root.appendingPathComponent("top.txt")])
        check("select(urls:) on a top-level file works",
              pane.fileView.selectedItems.map(\.url.lastPathComponent) == ["top.txt"])
        check("itemAfterSelection walks the same column",
              pane.fileView.itemAfterSelection() == nil
                  || pane.fileView.itemAfterSelection().map { real($0.url.deletingLastPathComponent()) } == real(root))

        // Read-only folders refuse edits through the browser delegate
        columns.isReadOnly = true
        check("a read-only location refuses in-place rename",
              !columns.browser(columns.browser, shouldEditItem: pane.model.nodes.first))
        columns.isReadOnly = false

        // Zoom applies to the row height and is stored under the columns index
        let before = columns.browser.rowHeight
        pane.setZoomIndex(3)
        check("zooming columns changes the row height", columns.browser.rowHeight > before,
              "\(before) -> \(columns.browser.rowHeight)")
        check("and is remembered under the columns index, not the list's",
              store.properties(forKey: pane.viewPropertiesKey).zoomIndex(for: .columns) == 3
                  && store.properties(forKey: pane.viewPropertiesKey).zoomIndex(for: .details) == ZoomLevel.defaultIndex(for: .details))

        // Switching away and back keeps the selection
        pane.fileView.select(urls: [docs])
        pane.setViewMode(.details)
        check("switching to the list keeps the selection",
              pane.fileView.selectedItems.map(\.url.lastPathComponent) == ["Docs"])
        pane.setViewMode(.columns)
        check("and back to columns keeps it too",
              pane.fileView.selectedItems.map(\.url.lastPathComponent) == ["Docs"],
              "\(pane.fileView.selectedItems.map(\.url.lastPathComponent))")

        // A change inside an open column must show up there, not only at the root.
        pane.fileView.select(urls: [docs])
        let added = docs.appendingPathComponent("added.txt")
        try? "new".write(to: added, atomically: true, encoding: .utf8)
        let generation = pane.model.generation
        controller.reload(nil)
        await expectEventually("reload lists again") { pane.model.generation > generation }
        columns.select(urls: [added])
        check("a file created inside an open column appears there after a reload",
              columns.selectedItems.map(\.url.lastPathComponent) == ["added.txt"],
              "\(columns.selectedItems.map(\.url.lastPathComponent))")

        // NSBrowser's index paths belong to the listing it loaded; a sort must
        // not silently move the selection to whatever now sits at that index.
        columns.select(urls: [root.appendingPathComponent("top.txt")])
        pane.fileList.setSort(key: .name, ascending: false)
        check("the selection survives a sort-order change",
              pane.fileView.selectedItems.map(\.url.lastPathComponent) == ["top.txt"],
              "\(pane.fileView.selectedItems.map(\.url.lastPathComponent))")
        pane.fileList.setSort(key: .name, ascending: true)

        // Programmatic selection must reach the pane like a table's would.
        var notified = 0
        let previous = columns.onSelectionChanged
        columns.onSelectionChanged = { notified += 1; previous?() }
        columns.select(urls: [docs])
        check("select(urls:) notifies the pane", notified == 1, "\(notified)")
        columns.onSelectionChanged = previous

        // Mixed depths collapse to one column, as NSBrowser requires.
        columns.select(urls: [root.appendingPathComponent("top.txt"), deep])
        check("a selection at mixed depths keeps one column only",
              Set(columns.selectedIndexPathsForTesting().map(\.count)).count == 1,
              "\(columns.selectedIndexPathsForTesting())")

        // The preview column lets go of its item once no file is selected.
        columns.select(urls: [deep])
        columns.select(urls: [docs])
        check("selecting a folder after a file clears the preview column", columns.isPreviewColumnEmptyForTesting)
        check("the preview column has no close button", columns.isPreviewCloseButtonHiddenForTesting)

        // The drawn title follows the show-extensions preference like the other views.
        let showedExtensions = AppPreferences.showFileExtensions
        AppPreferences.showFileExtensions = false
        columns.reloadData()
        // Titles are built in willDisplayCell, which only runs on a draw pass a
        // headless window never gets; call the delegate method itself.
        let topRow = pane.model.nodes.firstIndex { $0.item.name == "top.txt" } ?? -1
        let probe = NSBrowserCell(textCell: "")
        if topRow >= 0 { columns.browser(columns.browser, willDisplayCell: probe, atRow: topRow, column: 0) }
        // The drawn title now begins with the icon attachment, so compare the
        // text after it.
        let drawnName = probe.attributedStringValue.string
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFC} "))
        check("a column title hides the extension when the preference says so",
              topRow >= 0 && drawnName == "top",
              "row=\(topRow) drawn=\(probe.attributedStringValue.string.debugDescription)")
        AppPreferences.showFileExtensions = showedExtensions
        columns.reloadData()

        // select(name: nil) is the history path with no remembered name; it
        // must release the preview and tell the pane like any deselection.
        columns.select(urls: [deep])
        var cleared = 0
        let priorHandler = columns.onSelectionChanged
        columns.onSelectionChanged = { cleared += 1; priorHandler?() }
        columns.select(name: nil)
        columns.onSelectionChanged = priorHandler
        check("select(name: nil) drops the file, releases the preview and keeps the chain open",
              cleared == 1 && columns.isPreviewColumnEmptyForTesting
                  && !columns.selectedItems.contains { !$0.isNavigable } && columns.openColumnCountForTesting >= 3,
              "notified=\(cleared) selected=\(columns.selectedItems.map(\.url.lastPathComponent)) columns=\(columns.openColumnCountForTesting)")

        // Two selected files: no preview column, so nothing must be held.
        let second = docs.appendingPathComponent("second.txt")
        try? "x".write(to: second, atomically: true, encoding: .utf8)
        let g1 = pane.model.generation
        controller.reload(nil)
        await expectEventually("second file listed") { pane.model.generation > g1 }
        columns.reloadData()
        columns.select(urls: [added, second])
        check("both files are selected", columns.selectedItems.count == 2, "\(columns.selectedItems.map(\.url.lastPathComponent))")
        check("a multiple selection holds no preview item", columns.isPreviewColumnEmptyForTesting)

        // Deleting the selected file must not collapse the chain to the root.
        columns.select(urls: [deep])
        try? fm.removeItem(at: deep)
        let g2 = pane.model.generation
        controller.reload(nil)
        await expectEventually("reload after delete") { pane.model.generation > g2 }
        columns.reloadData()
        check("deleting the selected file keeps its folder's column open",
              columns.openColumnCountForTesting >= 2 && columns.selectedItems.map(\.url.lastPathComponent) == ["Notes"],
              "columns=\(columns.openColumnCountForTesting) selected=\(columns.selectedItems.map(\.url.lastPathComponent))")

        // A column re-opened later shows what the folder holds now.
        columns.select(urls: [root.appendingPathComponent("top.txt")])
        let late = docs.appendingPathComponent("late.txt")
        try? "late".write(to: late, atomically: true, encoding: .utf8)
        columns.select(urls: [docs])
        columns.select(urls: [late])
        check("a re-opened column lists the folder afresh",
              columns.selectedItems.map(\.url.lastPathComponent) == ["late.txt"],
              "\(columns.selectedItems.map(\.url.lastPathComponent))")

        // Cut markers made while another view was showing reach columns.
        pane.setViewMode(.details)
        pane.fileList.cutURLs = [root.appendingPathComponent("top.txt")]
        pane.setViewMode(.columns)
        check("cut markers follow the switch into columns", columns.cutURLs == pane.fileList.cutURLs)
        pane.fileList.cutURLs = []
        columns.cutURLs = []

        // Navigating to an ancestor is a fresh start: the chain the user just
        // left must not be re-drilled, leaving a folder selected they never
        // clicked. indexPath finds the old chain by path, so only the root
        // check stops it.
        columns.select(urls: [deep])
        pane.navigate(to: root.deletingLastPathComponent())
        await expectEventually("parent listed") { pane.currentURL?.lastPathComponent == root.deletingLastPathComponent().lastPathComponent }
        columns.reloadData()
        check("navigating to an ancestor leaves nothing selected and one column",
              columns.selectedItems.isEmpty && columns.openColumnCountForTesting == 1,
              "selected=\(columns.selectedItems.map(\.url.lastPathComponent)) columns=\(columns.openColumnCountForTesting)")
        pane.navigate(to: root)
        await expectEventually("back at the fixture") { pane.currentURL?.standardizedFileURL == root.standardizedFileURL }

        // A PDF is the ordinary case for the preview column: not Markdown, so
        // it goes through Quick Look. The owner reported it showing nothing.
        let pdf = root.appendingPathComponent("doc.pdf")
        let page = NSMutableData()
        if let consumer = CGDataConsumer(data: page as CFMutableData) {
            var box = CGRect(x: 0, y: 0, width: 200, height: 200)
            if let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
                ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 100)); ctx.endPDFPage(); ctx.closePDF()
            }
        }
        try? page.write(to: pdf)
        let g3 = pane.model.generation
        controller.reload(nil)
        await expectEventually("pdf listed") { pane.model.generation > g3 }
        columns.reloadData()
        columns.select(urls: [pdf])
        check("selecting a PDF holds it in the preview column",
              columns.previewedURLForTesting?.lastPathComponent == "doc.pdf",
              "\(columns.previewedURLForTesting?.lastPathComponent ?? "nil")")
        check("and the PDF goes through Quick Look, not the Markdown view",
              columns.isPreviewColumnShowingMarkdownForTesting == false)
        // NSBrowser sizes a preview column through the autoresizing mask, so a
        // view laid out by constraints alone is handed a frame 0 pt high and
        // shows nothing however right its content is. Measured, then pinned.
        check("the preview column sizes itself the way NSBrowser expects",
              columns.previewAutoresizesForTesting)
        // The mask alone is not the fix: NSBrowser resizes from the frame it
        // finds, so a zero-height starting frame stays short. Both halves pinned.
        check("and starts from a real frame, not a zero-height one",
              columns.previewStartFrameForTesting.height > 0 && columns.previewStartFrameForTesting.width > 0,
              "\(columns.previewStartFrameForTesting)")
        // The delegate is what NSBrowser actually calls; drive it the same way.
        if let node = pane.model.node(for: pdf) {
            _ = columns.browser(columns.browser, previewViewControllerForLeafItem: node)
            check("the preview delegate holds the PDF after NSBrowser asks",
                  columns.previewedURLForTesting?.lastPathComponent == "doc.pdf",
                  "\(columns.previewedURLForTesting?.lastPathComponent ?? "nil")")
        }
        // A click is what the user does; its handler must not undo the preview.
        columns.simulateClickForTesting()
        check("a click on the selected PDF does not clear the preview",
              columns.previewedURLForTesting?.lastPathComponent == "doc.pdf",
              "\(columns.previewedURLForTesting?.lastPathComponent ?? "nil")")

        // Rows must draw an icon; an item-based NSBrowser uses NSTextFieldCell,
        // so a cast to NSBrowserCell silently disabled icons, displayName and
        // the dimming of a cut item all at once.
        let iconProbe = NSTextFieldCell(textCell: "")
        let topRow2 = pane.model.nodes.firstIndex { $0.item.name == "top.txt" } ?? -1
        if topRow2 >= 0 {
            columns.browser(columns.browser, willDisplayCell: iconProbe, atRow: topRow2, column: 0)
            var hasIcon = false
            let title = iconProbe.attributedStringValue
            title.enumerateAttribute(NSAttributedString.Key.attachment, in: NSRange(location: 0, length: title.length)) { value, _, _ in
                if (value as? NSTextAttachment)?.image != nil { hasIcon = true }
            }
            check("a column row draws an icon", hasIcon, title.string.debugDescription)
            check("and still carries the name", title.string.contains("top"), title.string.debugDescription)
            // Type-select defaults to the cell's own string, which now opens
            // with the attachment character — no typed letter could match it.
            check("a column row answers type-select with the real name",
                  columns.browser(columns.browser, typeSelectStringForRow: topRow2, inColumn: 0) == "top.txt",
                  columns.browser(columns.browser, typeSelectStringForRow: topRow2, inColumn: 0) ?? "nil")
            // The attachment character must not be what a screen reader reads.
            check("and reads its name to assistive clients, not U+FFFC",
                  iconProbe.accessibilityLabel() == "top.txt",
                  "label=\(iconProbe.accessibilityLabel() ?? "nil")")

            // A cell the browser owns, not a bare probe. This distinction is the
            // whole check: on a detached NSTextFieldCell the delegate's writes
            // all stick, but on a browser-owned cell `setAccessibilityValue`
            // writes through and replaces the attributed string, deleting the
            // icon. A probe-only check passed three green rounds while every
            // row on screen had lost its icon.
            if let owned = columns.browser.loadedCell(atRow: topRow2, column: 0) as? NSCell {
                let drawn = owned.attributedStringValue
                var ownedIcon = false
                drawn.enumerateAttribute(.attachment, in: NSRange(location: 0, length: drawn.length)) { value, _, _ in
                    if (value as? NSTextAttachment)?.image != nil { ownedIcon = true }
                }
                check("the cell NSBrowser actually draws still carries the icon",
                      ownedIcon, drawn.string.debugDescription)
                check("and that cell still reads its name to assistive clients",
                      owned.accessibilityLabel() == "top.txt",
                      "label=\(owned.accessibilityLabel() ?? "nil")")
            } else {
                check("the browser hands back a loaded cell to inspect", false)
            }

            // Rows are read back as the browser itself draws them, not by
            // drawing a detached cell: the row's title is centred by
            // `ColumnRowCell`, the class the browser instantiates, and only the
            // browser's own drawing proves that class is the one in use.
            check("the browser draws its rows with the centring ColumnRowCell",
                  columns.browser.loadedCell(atRow: max(0, topRow2), column: 0) is ColumnRowCell,
                  String(describing: columns.browser.loadedCell(atRow: max(0, topRow2), column: 0).map { type(of: $0) }))
            func rowPixels(row: Int) -> (rep: NSBitmapImageRep, scale: Int)? {
                let browser = columns.browser
                browser.layoutSubtreeIfNeeded()
                let frame = browser.frame(ofRow: row, inColumn: 0)
                guard frame.height > 0,
                      let rep = browser.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
                browser.cacheDisplay(in: frame, to: rep)
                return (rep, max(1, Int((CGFloat(rep.pixelsHigh) / frame.height).rounded())))
            }
            /// Pixels that differ from the row's own ground, sampled at its
            /// top-left corner where neither the icon nor the name reaches.
            func isInk(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, ground: NSColor) -> Bool {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let g = ground.usingColorSpace(.sRGB) else { return false }
                return abs(c.redComponent - g.redComponent) > 0.15
                    || abs(c.greenComponent - g.greenComponent) > 0.15
                    || abs(c.blueComponent - g.blueComponent) > 0.15
            }

            // A column narrower than the name must truncate it, not drop it.
            // The cell's default is to wrap and a filename is one unbreakable
            // word, so the line breaks after the icon and a single-line cell
            // draws only that first line — icon, no name. Drawn and counted,
            // because nothing about the string itself reveals this: the
            // attributed value is identical either way.
            func nameInk(row: Int, atColumnWidth width: CGFloat) -> Int {
                columns.browser.setWidth(width, ofColumn: 0)
                guard let (rep, scale) = rowPixels(row: row),
                      let ground = rep.colorAt(x: 0, y: 0) else { return -1 }
                let side = Int(max(12, columns.iconSize - 4))
                var ink = 0
                for y in 0..<rep.pixelsHigh {
                    for x in ((side + 4) * scale)..<rep.pixelsWide where isInk(rep, x, y, ground: ground) { ink += 1 }
                }
                return ink / (scale * scale)
            }
            // Measured against the long name: `top.txt` fits at 70 pt, so a
            // check using it passes whether or not the bug is present. That is
            // how the first version of this check failed its own mutation test.
            let longRow = pane.model.nodes.firstIndex { $0.item.name == longName } ?? -1
            if longRow >= 0 {
                let savedWidth = columns.browser.width(ofColumn: 0)
                let wide = nameInk(row: longRow, atColumnWidth: 320)
                let narrow = nameInk(row: longRow, atColumnWidth: 90)
                columns.browser.setWidth(savedWidth, ofColumn: 0)
                check("a column too narrow for the name still draws it, truncated",
                      narrow > 30 && wide > 30 && narrow < wide,
                      "ink at 320pt=\(wide), at 90pt=\(narrow)")
            } else {
                check("the fixture has a name too long for a narrow column", false)
            }

            // The icon and the name sit on the row's vertical centre, where the
            // selection highlight and the folder chevron are drawn. A single-line
            // text cell is top-anchored on its own 13 pt font, so without the
            // centring the name hugged the top of every row and a large icon
            // hung above it — clipped at the row's top edge, which is why ink
            // touching that edge fails the check as well as unequal margins.
            func inkSpan(row: Int, xRange: Range<Int>) -> (top: CGFloat, bottom: CGFloat)? {
                guard let (rep, scale) = rowPixels(row: row),
                      let ground = rep.colorAt(x: 0, y: 0) else { return nil }
                var first = -1, last = -1
                for y in 0..<rep.pixelsHigh
                where xRange.contains(where: { isInk(rep, $0 * scale, y, ground: ground) }) {
                    if first < 0 { first = y }
                    last = y
                }
                guard first >= 0 else { return nil }
                return (CGFloat(first) / CGFloat(scale),
                        CGFloat(rep.pixelsHigh - 1 - last) / CGFloat(scale))
            }
            let savedIconSize = columns.iconSize
            // The long name: "quarterly-…" has both ascenders and descenders,
            // so its ink box is close to even about the cap-height midpoint
            // (a short name like `top` has neither tall letters nor balance).
            let measuredRow = pane.model.nodes.firstIndex { $0.item.name == longName } ?? -1
            if measuredRow >= 0 {
                for size in [CGFloat(16), 22, 32] {
                    columns.setIconSize(size, showPreviews: columns.showPreviews)
                    let side = Int(max(12, size - 4))
                    // Where the row's content starts: the browser insets it,
                    // so the icon's left edge is found rather than assumed.
                    var left = 0
                    if let (rep, scale) = rowPixels(row: measuredRow), let ground = rep.colorAt(x: 0, y: 0) {
                        left = (0..<(rep.pixelsWide / scale)).first { x in
                            (0..<rep.pixelsHigh).contains { isInk(rep, x * scale, $0, ground: ground) }
                        } ?? 0
                    }
                    let icon = inkSpan(row: measuredRow, xRange: left..<(left + side - 2))
                    let name = inkSpan(row: measuredRow, xRange: (left + side + 6)..<(left + side + 70))
                    let centred = { (s: (top: CGFloat, bottom: CGFloat)?) -> Bool in
                        guard let s else { return false }
                        return s.top >= 1 && s.bottom >= 1 && abs(s.top - s.bottom) <= 2
                    }
                    // Centred on its cap height, the name's ink sits a little
                    // low: descenders reach further below the baseline than the
                    // gap left above the letters. So the top gap may exceed the
                    // bottom one by a few points, but must never be the smaller
                    // — the bug drew the name 4 pt from the top of a 34 pt row,
                    // 21 pt from its bottom.
                    let nameCentred = name.map { $0.top >= 1 && $0.bottom >= 1
                        && (-1...5).contains($0.top - $0.bottom) } ?? false
                    check("at icon size \(Int(size)) the column row's icon and name are vertically centred",
                          centred(icon) && nameCentred,
                          "rowHeight=\(columns.browser.rowHeight) icon=\(String(describing: icon)) name=\(String(describing: name))")
                }
            }
            columns.setIconSize(savedIconSize, showPreviews: columns.showPreviews)

            // Dimming was the third thing the broken cast disabled, and nothing
            // read it back: cutURLs was always empty at probe time.
            func drawnRow() -> (colour: NSColor?, icon: NSImage?) {
                let probe = NSTextFieldCell(textCell: "")
                columns.browser(columns.browser, willDisplayCell: probe, atRow: topRow2, column: 0)
                let drawn = probe.attributedStringValue
                let nameStart = drawn.string.count > 1 ? 1 : 0
                let colour = drawn.attribute(.foregroundColor, at: nameStart, effectiveRange: nil) as? NSColor
                let icon = (drawn.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
                return (colour, icon)
            }
            let plain = drawnRow()
            columns.cutURLs = [root.appendingPathComponent("top.txt").standardizedFileURL]
            let cut = drawnRow()
            columns.cutURLs = []
            check("a cut column row is dimmed and an uncut one is not",
                  plain.colour == .labelColor && cut.colour == .secondaryLabelColor,
                  "plain=\(plain.colour?.description ?? "nil") cut=\(cut.colour?.description ?? "nil")")
            // The icon fades with the text; the list view fades the whole row,
            // so a full-strength icon beside dimmed text would be half-cut.
            // Compared by drawn pixels, because the two images are distinct
            // objects either way — NSWorkspace returns a fresh one per call.
            // Drawn into a bitmap of a format we choose, so the bytes mean what
            // we think they mean; the images' own representations differ.
            func inkCoverage(_ image: NSImage?) -> Double? {
                guard let image else { return nil }
                let side = 32
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
                      let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
                NSGraphicsContext.restoreGraphicsState()
                guard let bytes = rep.bitmapData else { return nil }
                var total = 0
                for pixel in 0..<(side * side) { total += Int(bytes[pixel * 4 + 3]) }
                return Double(total) / Double(side * side * 255)
            }
            let plainInk = inkCoverage(plain.icon)
            let cutInk = inkCoverage(cut.icon)
            check("and its icon is faded too, not drawn at full strength",
                  cut.icon != nil && plainInk != nil && cutInk != nil
                      && cutInk! < plainInk! * 0.75 && cutInk! > 0,
                  "plain=\(plainInk.map { String(format: "%.3f", $0) } ?? "nil") cut=\(cutInk.map { String(format: "%.3f", $0) } ?? "nil")")
        }

        // Leaving columns must not drop keyboard focus on the floor.
        controller.window?.makeFirstResponder(columns.browser)
        pane.setViewMode(.details)
        check("keyboard focus follows the mode switch away from columns",
              controller.window?.firstResponder === pane.fileList.focusView,
              String(describing: type(of: controller.window?.firstResponder as Any)))
        pane.setViewMode(.columns)

        // A new pane on the same folder comes up in columns
        let again = BrowserViewController(provider: provider, initialURL: root, viewPropertiesStore: store)
        _ = again.view
        check("a new pane on the folder opens in columns", again.viewMode == .columns && again.fileView === again.columnView)
    }

    private static func menuItem(for action: Selector) -> NSMenuItem? {
        func find(in menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.action == action { return item }
                if let nested = find(in: item.submenu) { return nested }
            }
            return nil
        }
        return find(in: NSApp.mainMenu)
    }
}
