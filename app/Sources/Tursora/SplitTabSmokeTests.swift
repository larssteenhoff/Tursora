import AppKit

/// A real window with a split tab: the tab's divider sits over the line
/// between the two panes, and follows that line when it moves.
enum SplitTabSmokeTests: SmokeSuite {
    static var checkPrefix: String { "split tab: " }

    static func run(_ completion: @escaping () -> Void) {
        print("== split tab alignment ==")
        Task { @MainActor in
            await window()
            completion()
        }
    }

    @MainActor
    private static func window() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tursora-splittab-\(UUID().uuidString)")
        try? fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let controller = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: store)
        defer { controller.close(); try? store.flush() }
        controller.window?.setContentSize(NSSize(width: 1400, height: 700))
        controller.window?.makeKeyAndOrderFront(nil)
        await expectEventually("fixture loaded") { controller.browser.model.generation > 0 }
        let tabs = controller.tabs
        // One tab: no strip, and New Tab is a toolbar button rather than a +.
        check("a window with one tab hides the tab strip", tabs.tabBar.isHidden)
        let toolbarNewTab = controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "tursora.newTab" }
        check("the toolbar carries New Tab and the strip draws no + of its own",
              toolbarNewTab != nil && !tabs.tabBar.isAddButtonVisibleForTesting
              && tabs.tabBar.layoutForTesting.addButtonFrame.width == 0)
        if let toolbarNewTab, let action = toolbarNewTab.action {
            NSApp.sendAction(action, to: toolbarNewTab.target, from: toolbarNewTab)
        }
        check("the toolbar's New Tab opens a tab and the strip appears", tabs.count == 2 && !tabs.tabBar.isHidden)
        _ = tabs.closeTab(at: 1)
        check("closing back to one tab hides the strip again", tabs.count == 1 && tabs.tabBar.isHidden)
        _ = tabs.newTab(at: root)
        tabs.selectTab(at: 1)
        tabs.toggleSplit()
        func settle() { controller.window?.contentView?.layoutSubtreeIfNeeded(); tabs.tabBar.layoutSubtreeIfNeeded() }
        settle()
        await expectEventually("the tab is split") { tabs.isSplit }
        settle()
        func paneSplitX() -> CGFloat? { tabs.tabBar.splitDividerWindowX?() }
        func tabDividerX() -> CGFloat? {
            guard let frame = tabs.tabBar.titleDividerFrameForTesting(tabs.tabBar.selectedIndex) else { return nil }
            return tabs.tabBar.convert(frame, to: nil).midX
        }
        tabs.tabBar.reload(titles: [TabTitle("one"), TabTitle(left: "Left", right: "Right")], selected: 1)
        settle()
        check("the tab's divider sits over the pane split, the tab no wider than the others",
              paneSplitX().flatMap { split in tabDividerX().map { abs($0 - split) < 1.5 } } == true
              && abs(tabs.tabBar.tabFrameForTesting(1).width - tabs.tabBar.tabFrameForTesting(0).width) < 0.5,
              "split=\(String(describing: paneSplitX())) divider=\(String(describing: tabDividerX()))")
        let page = tabs.tabBar.window.flatMap { _ in tabs.children.compactMap { $0 as? TabPage }.first { !$0.view.isHidden } }
        if let page {
            page.splitView.setPosition(page.splitView.bounds.width * 0.65, ofDividerAt: 0)
            settle()
            check("dragging the pane divider moves the tab's divider with it",
                  paneSplitX().flatMap { split in tabDividerX().map { abs($0 - split) < 1.5 } } == true,
                  "split=\(String(describing: paneSplitX())) divider=\(String(describing: tabDividerX()))")
        } else {
            check("the split page is reachable", false)
        }
        // A single click on either half of the split tab activates that pane.
        if let page, let divider = tabs.tabBar.titleDividerFrameForTesting(tabs.tabBar.selectedIndex) {
            let tab = tabs.tabBar.tabFrameForTesting(tabs.tabBar.selectedIndex)
            tabs.tabBar.clickTabForTesting(tabs.tabBar.selectedIndex, atX: (tab.minX + divider.minX) / 2)
            let leftActive = page.activeIndex == 0
            tabs.tabBar.clickTabForTesting(tabs.tabBar.selectedIndex, atX: (divider.maxX + tab.maxX) / 2)
            let rightActive = page.activeIndex == 1
            tabs.tabBar.clickTabForTesting(tabs.tabBar.selectedIndex, atX: (tab.minX + divider.minX) / 2)
            check("clicking either half of a split tab activates that pane",
                  leftActive && rightActive && page.activeIndex == 0,
                  "left=\(leftActive) right=\(rightActive) now=\(page.activeIndex)")
        } else {
            check("the split tab has a divider to click beside", false)
        }
        tabs.toggleSplit()
        settle()
        check("closing the split puts the tabs back to equal widths", tabs.tabBar.layoutForTesting.stretch == nil)
    }
}
