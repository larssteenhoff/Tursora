import Foundation

/// Geometry shared by the tab strip and its regression checks. Tab frames use
/// document coordinates; controls and the viewport use strip coordinates.
struct TabStripLayout {
    static let minimumTabWidth: CGFloat = 120
    /// The width a tab settles at when the strip has room to spare. Browsers
    /// stop growing tabs well before the window edge; so do we (D79).
    static let preferredTabWidth: CGFloat = 240
    /// The soft cap: a tab may pass `preferredTabWidth` when its own title
    /// needs the room and the strip can spare it, but never this.
    static let maximumTabWidth: CGFloat = 480
    static let horizontalInset: CGFloat = 8
    static let controlWidth: CGFloat = 28
    static let controlGap: CGFloat = 4

    let tabCount: Int
    let tabWidth: CGFloat
    let contentWidth: CGFloat
    let viewportFrame: CGRect
    let addButtonFrame: CGRect
    let overflowButtonFrame: CGRect?
    /// True when the tabs do not fill the strip and New Tab sits right after
    /// them instead of at the trailing edge.
    let addButtonFollowsTabs: Bool
    /// Space opened before one tab, which moves that tab and every later one
    /// right by `extra`; all tabs keep the same width. Used to put a split
    /// tab's divider over the line between its two panes. Never applied while
    /// overflowing.
    let stretch: (index: Int, extra: CGFloat)?

    /// `naturalTabWidth` is the width the widest title would need with nothing
    /// truncated, measured by the view. Zero means "unmeasured", which settles
    /// every tab at `preferredTabWidth` or below.
    init(width: CGFloat, height: CGFloat = 36, tabCount: Int, naturalTabWidth: CGFloat = 0,
         stretch requested: (index: Int, extra: CGFloat)? = nil, hasAddButton: Bool = true) {
        self.tabCount = max(0, tabCount)
        let width = max(0, width), height = max(0, height)
        let inset = min(Self.horizontalInset, width / 2)
        let controlButtonWidth = min(Self.controlWidth, max(0, width - inset * 2))
        // Without a New Tab button (the window has one in its toolbar) the
        // strip gives that room back to the tabs.
        let buttonWidth = hasAddButton ? controlButtonWidth : 0
        let addGap = hasAddButton ? Self.controlGap : 0
        let buttonY = max(0, (height - 28) / 2)
        let buttonHeight = min(28, height)
        // Widest the tab area could be: New Tab pinned to the trailing edge.
        let pinnedX = max(inset, width - inset - buttonWidth)
        let pinnedViewport = max(0, pinnedX - addGap - inset)
        let overflowing = CGFloat(self.tabCount) * Self.minimumTabWidth > pinnedViewport
        if overflowing {
            let overflowWidth = min(controlButtonWidth, pinnedViewport)
            overflowButtonFrame = CGRect(x: pinnedX - addGap - overflowWidth,
                                         y: buttonY, width: overflowWidth, height: buttonHeight)
        } else {
            overflowButtonFrame = nil
        }
        let available = max(0, (overflowButtonFrame.map { $0.minX - Self.controlGap } ?? (pinnedX - addGap)) - inset)
        if self.tabCount == 0 {
            tabWidth = 0
        } else {
            // Share the strip equally, but stop at the preferred width unless
            // the title itself needs more, and never past the hard ceiling.
            let fairShare = available / CGFloat(self.tabCount)
            let wanted = min(Self.maximumTabWidth, max(Self.preferredTabWidth, max(0, naturalTabWidth)))
            tabWidth = max(Self.minimumTabWidth, min(fairShare, wanted))
        }
        var tabsWidth = tabWidth * CGFloat(self.tabCount)
        // The gap only spends room the strip has spare.
        if let requested, !overflowing, (0..<self.tabCount).contains(requested.index), requested.extra > 0 {
            let extra = min(requested.extra, max(0, available - tabsWidth))
            stretch = extra > 0 ? (requested.index, extra) : nil
            tabsWidth += extra > 0 ? extra : 0
        } else {
            stretch = nil
        }
        // Pinning New Tab to the far edge of a half-empty strip puts it nowhere
        // near the tabs it adds to, so it follows them instead (D79).
        addButtonFollowsTabs = self.tabCount > 0 && !overflowing && tabsWidth < available
        let viewportWidth = addButtonFollowsTabs ? tabsWidth : available
        addButtonFrame = CGRect(x: addButtonFollowsTabs ? inset + tabsWidth + addGap : pinnedX,
                                y: buttonY, width: buttonWidth, height: buttonHeight)
        viewportFrame = CGRect(x: inset, y: 0, width: viewportWidth, height: height)
        contentWidth = max(viewportWidth, tabsWidth)
    }

    var isOverflowing: Bool { overflowButtonFrame != nil }

    func frameForTab(_ index: Int) -> CGRect {
        guard (0..<tabCount).contains(index) else { return .zero }
        var x = CGFloat(index) * tabWidth
        let width = tabWidth
        if let stretch, index >= stretch.index { x += stretch.extra }
        return CGRect(x: x + 2, y: 4, width: max(0, width - 4), height: max(0, viewportFrame.height - 8))
    }

    func targetIndex(atDocumentX x: CGFloat) -> Int? {
        guard tabCount > 0, tabWidth > 0 else { return nil }
        guard stretch != nil else { return max(0, min(tabCount - 1, Int(max(0, x) / tabWidth))) }
        // Slots are no longer equal: the first slot whose right edge passes x.
        for index in 0..<tabCount where x < frameForTab(index).maxX + 2 { return index }
        return tabCount - 1
    }
}
