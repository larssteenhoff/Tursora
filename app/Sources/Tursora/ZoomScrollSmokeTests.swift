import AppKit

/// ⌃-scroll zooms like ⌘-scroll in every file view, and a mouse wheel moves
/// the zoom by one status-bar slider step per notch.
enum ZoomScrollSmokeTests: SmokeSuite {
    static var checkPrefix: String { "zoom scroll: " }

    static func run(_ completion: @escaping () -> Void) {
        print("== zoom scroll ==")
        rule()
        Task { @MainActor in
            await views()
            completion()
        }
    }

    /// The modifier rule and the stepping, as pure functions.
    private static func rule() {
        check("⌃ and ⌘ make a scroll zoom; plain and ⇧ scrolls do not",
              ZoomGestureAccumulator.isZoomScroll(.control) && ZoomGestureAccumulator.isZoomScroll(.command)
              && ZoomGestureAccumulator.isZoomScroll([.control, .capsLock])
              && !ZoomGestureAccumulator.isZoomScroll([]) && !ZoomGestureAccumulator.isZoomScroll(.shift))
        var accumulator = ZoomGestureAccumulator()
        let notches = [accumulator.step(scrollingDeltaY: 1, precise: false),
                       accumulator.step(scrollingDeltaY: -1, precise: false)]
        let smooth = [accumulator.step(scrollingDeltaY: 3, precise: true),
                      accumulator.step(scrollingDeltaY: 3, precise: true),
                      accumulator.step(scrollingDeltaY: 3, precise: true)]
        check("each wheel notch is one zoom step; trackpad scrolling still accumulates",
              notches == [1, -1] && smooth == [nil, nil, 1], "notches=\(notches) smooth=\(smooth)")
    }

    /// Real ⌃ + mouse-wheel events delivered to each view's own scrolling
    /// view, moving the same zoom index the slider shows.
    @MainActor
    private static func views() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tursora-zoomscroll-\(UUID().uuidString)")
        try? fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try? "note".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let store = DirectoryViewPropertiesStore(fileURL: root.appendingPathComponent("views.json"))
        let controller = MainWindowController(provider: LocalFileProvider(), places: PlacesModel(), initialURL: root,
                                              viewPropertiesStore: store)
        defer { controller.close(); try? store.flush() }
        controller.window?.setContentSize(NSSize(width: 1100, height: 650))
        controller.window?.makeKeyAndOrderFront(nil)
        await expectEventually("fixture loaded") { controller.browser.model.generation > 0 }
        let pane = controller.browser

        func controlWheel(_ lines: Int32) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                   wheel1: lines, wheel2: 0, wheel3: 0) else { return nil }
            cg.flags = .maskControl
            return NSEvent(cgEvent: cg)
        }
        let targets: [(ViewMode, () -> NSView)] = [
            (.icons, { pane.iconGrid.collectionView }),
            (.details, { pane.fileList.tableView }),
            (.columns, { pane.columnView.browser }),
        ]
        for (mode, target) in targets {
            pane.setViewMode(mode)
            pane.zoomActualSize(nil)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let start = pane.zoomIndex
            guard let up = controlWheel(1), let down = controlWheel(-1) else {
                check("\(mode) ⌃-wheel event can be made", false); continue
            }
            check("a synthesized \(mode) wheel event is a notched ⌃ scroll",
                  !up.hasPreciseScrollingDeltas && up.scrollingDeltaY > 0
                      && ZoomGestureAccumulator.isZoomScroll(up.modifierFlags),
                  "precise=\(up.hasPreciseScrollingDeltas) dy=\(up.scrollingDeltaY) flags=\(up.modifierFlags.rawValue)")
            target().scrollWheel(with: up)
            let afterUp = pane.zoomIndex
            let sliderUp = Int(pane.statusBar.zoomSlider.doubleValue.rounded())
            target().scrollWheel(with: down)
            check("in \(mode) one ⌃-wheel notch zooms one slider step each way",
                  afterUp == start + 1 && sliderUp == afterUp && pane.zoomIndex == start,
                  "start=\(start) up=\(afterUp) slider=\(sliderUp) down=\(pane.zoomIndex)")
        }
        pane.zoomActualSize(nil)

        // The slider those notches move draws a round knob, tick marks kept.
        let slider = pane.statusBar.zoomSlider
        slider.display()
        let knob = (slider.cell as? RoundKnobSliderCell)?.lastKnobRect ?? .zero
        let gray = { (name: NSAppearance.Name) -> Bool in
            var result = false
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                guard let c = RoundKnobSliderCell.knobColor.usingColorSpace(.sRGB) else { return }
                result = abs(c.redComponent - c.greenComponent) < 0.05 && c.redComponent > 0.5 && c.redComponent < 0.9
            }
            return result
        }
        check("the knob is gray, not white, in dark and light mode", gray(.darkAqua) && gray(.aqua))
        check("the zoom slider's knob is a circle and its tick marks stay",
              knob.width > 4 && abs(knob.width - knob.height) < 0.01 && slider.numberOfTickMarks >= 2,
              "knob=\(knob) ticks=\(slider.numberOfTickMarks)")
    }
}
