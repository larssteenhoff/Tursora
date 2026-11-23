import AppKit

/// The image under the pointer while files are dragged, drawn by the app in
/// every view and styled after Finder's: each item's icon beside its name in a
/// rounded accent-coloured label, up to four rows, and a red count badge when
/// several items are dragged.
enum DragGhost {
    static func image(for items: [FileItem]) -> NSImage? {
        guard !items.isEmpty else { return nil }
        let shown = Array(items.prefix(4))
        let icon: CGFloat = 20, rowHeight: CGFloat = 24, gap: CGFloat = 4, radius: CGFloat = 6
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                         .foregroundColor: NSColor.white]
        let nameWidths = shown.map { min(260, ceil(($0.name as NSString).size(withAttributes: attributes).width) + 14) }
        let badge = items.count > 1 ? "\(items.count)" : nil
        let badgeSize: CGFloat = 22
        let top = badge == nil ? 0 : badgeSize / 2
        let width = icon + gap + (nameWidths.max() ?? 0) + (badge == nil ? 0 : badgeSize / 2)
        let height = CGFloat(shown.count) * rowHeight + top
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            for (i, item) in shown.enumerated() {
                let y = top + CGFloat(i) * rowHeight
                NSWorkspace.shared.icon(forFile: item.url.path)
                    .draw(in: NSRect(x: 0, y: y + (rowHeight - icon) / 2, width: icon, height: icon),
                          from: .zero, operation: .sourceOver, fraction: 0.9, respectFlipped: true, hints: nil)
                let pill = NSRect(x: icon + gap, y: y + 2, width: nameWidths[i], height: rowHeight - 4)
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingMiddle
                var text = attributes
                text[.paragraphStyle] = style
                (item.name as NSString).draw(with: pill.insetBy(dx: 7, dy: 2),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                             attributes: text)
            }
            if let badge {
                let circle = NSRect(x: width - badgeSize, y: 0, width: badgeSize, height: badgeSize)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: circle).fill()
                let label: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12),
                                                            .foregroundColor: NSColor.white]
                let size = (badge as NSString).size(withAttributes: label)
                (badge as NSString).draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2),
                                         withAttributes: label)
            }
            return true
        }
    }

    /// Replaces a starting session's images with one ghost, its first row's
    /// icon at the pointer. `view` is the session's source view.
    static func apply(to session: NSDraggingSession, items: [FileItem], in view: NSView, at screenPoint: NSPoint) {
        guard let ghost = image(for: items), let window = view.window else { return }
        let local = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let top: CGFloat = items.count > 1 ? 11 : 0
        // The pointer sits on the first icon, as in Finder.
        let originY = view.isFlipped ? local.y - top - 12 : local.y - ghost.size.height + top + 12
        let frame = NSRect(x: local.x - 10, y: originY, width: ghost.size.width, height: ghost.size.height)
        session.draggingFormation = .none
        session.enumerateDraggingItems(options: [], for: view, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, index, _ in
            if index == 0 {
                item.setDraggingFrame(frame, contents: ghost)
            } else {
                item.imageComponentsProvider = { [] }
            }
        }
    }
}
