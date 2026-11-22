import AppKit

/// List view stripes follow the Alternating Row Colors slider: rendered rows
/// match at 0 and differ more as the slider moves right.
enum RowStripesSmokeTests: SmokeSuite {
    static var checkPrefix: String { "row stripes: " }

    static func run() {
        print("== alternating row colors ==")
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
            let soft = difference(strength: 0.4, appearance: appearance)
            let strong = difference(strength: 1, appearance: appearance)
            check("\(appearance.name.rawValue): all the way left, every row is the same color", none == 0, "diff=\(none)")
            check("\(appearance.name.rawValue): moving right makes the rows differ more",
                  soft > 0 && strong > soft, "soft=\(soft) strong=\(strong)")
        }
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
