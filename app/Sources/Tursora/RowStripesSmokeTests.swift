import AppKit

/// List view stripes follow the Alternating Row Colors slider: rendered rows
/// match at 0 and differ more as the slider moves right.
enum RowStripesSmokeTests: SmokeSuite {
    static var checkPrefix: String { "row stripes: " }

    static func run(completion: @escaping () -> Void) {
        print("== alternating row colors ==")
        defer { Task { @MainActor in await listedRows(); completion() } }
        let domain = "com.tursora.stripes-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppPreferences.Store(defaults: defaults, notificationCenter: NotificationCenter())
        check("the default is a soft stripe", store.rowStripeStrength == AppPreferences.Store.defaultRowStripeStrength)
        store.rowStripeStrength = 3
        check("the strength is clamped to 0...1", store.rowStripeStrength == 1)

        let settings = SettingsWindowController(preferences: store, workspaceStore: WorkspaceSessionStore(fileURL: nil))
        _ = settings.window
        settings.rowStripeSlider.doubleValue = 0
        check("the Settings slider dispatches its real action",
              settings.rowStripeSlider.sendAction(settings.rowStripeSlider.action, to: settings.rowStripeSlider.target)
              && store.rowStripeStrength == 0)
        settings.close()

        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
            let none = difference(strength: 0, appearance: appearance)
            let soft = difference(strength: 0.25, appearance: appearance)
            let strong = difference(strength: 1, appearance: appearance)
            check("\(appearance.name.rawValue): all the way left, every row is the same color", none == 0, "diff=\(none)")
            check("\(appearance.name.rawValue): moving right makes the rows differ more",
                  soft > 0 && strong > soft, "soft=\(soft) strong=\(strong)")
        }
    }

    /// The real List view with files in it: row views must not paint over
    /// the stripes.
    @MainActor
    static func listedRows() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tursora-stripes-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d", "e", "f"] { fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data()) }
        defer { try? fm.removeItem(at: root) }
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let controller = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: store)
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 900, height: 600))
        controller.window?.makeKeyAndOrderFront(nil)
        await expectEventually("fixture listed") { controller.browser.model.generation > 0 }
        controller.browser.setViewMode(.details)
        let table = controller.browser.fileList.tableView
        await expectEventually("rows are on screen") { table.numberOfRows >= 6 }
        table.deselectAll(nil)
        func rowDifference(_ strength: CGFloat) -> Int {
            table.stripeStrength = strength
            guard let scroll = table.enclosingScrollView else { return -1 }
            scroll.layoutSubtreeIfNeeded()
            guard let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { return -1 }
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
            let scale = max(1, rep.pixelsWide / Int(scroll.bounds.width))
            // Two pixels inside the top of rows 2 and 3, away from any text.
            func sample(_ row: Int) -> [Int] {
                let rect = scroll.convert(table.rect(ofRow: row), from: table)
                let y = scroll.isFlipped ? rect.minY + 2 : scroll.bounds.height - rect.maxY + 2
                guard let c = rep.colorAt(x: Int(rect.midX) * scale, y: Int(y) * scale) else { return [] }
                return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
            }
            let a = sample(2), b = sample(3)
            guard a.count == 3, b.count == 3 else { return -1 }
            return zip(a, b).map { abs($0 - $1) }.reduce(0, +)
        }
        let none = rowDifference(0), strong = rowDifference(1)
        check("in the real List view, rows match at 0 and stripe at full strength",
              none == 0 && strong > 0, "none=\(none) strong=\(strong)")
        table.stripeStrength = CGFloat(AppPreferences.shared.rowStripeStrength)
    }

    /// Renders an empty list and returns how far apart the first two rows are.
    private static func difference(strength: CGFloat, appearance: NSAppearance) -> Int {
        let table = FileOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        table.appearance = appearance
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.rowHeight = 24
        table.headerView = nil
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.stripeStrength = strength
        // In a scroll view, as in the app, so the empty rows below fill the clip.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        scroll.appearance = appearance
        scroll.documentView = table
        scroll.layoutSubtreeIfNeeded()
        let bounds = scroll.bounds
        guard let rep = scroll.bitmapImageRepForCachingDisplay(in: bounds) else { return -1 }
        scroll.cacheDisplay(in: bounds, to: rep)
        // Row 0 spans y 0–24 and row 1 y 24–48 from the top.
        func pixel(_ y: Int) -> [Int] {
            let scale = max(1, rep.pixelsHigh / Int(bounds.height))
            guard let c = rep.colorAt(x: 100 * scale, y: y * scale) else { return [] }
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        let a = pixel(12), b = pixel(36)
        guard a.count == 3, b.count == 3 else { return -1 }
        return zip(a, b).map { abs($0 - $1) }.reduce(0, +)
    }
}
