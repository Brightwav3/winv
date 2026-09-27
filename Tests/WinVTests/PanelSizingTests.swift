import AppKit
import SwiftUI
import XCTest
@testable import WinV

@MainActor
final class PanelSizingTests: XCTestCase {
    func testMinimalPanelShrinksToOneClipAndStops() {
        let empty = PanelModel.height(for: 0, minimal: true, historyOn: true)
        let one = PanelModel.height(for: 1, minimal: true, historyOn: true)
        let two = PanelModel.height(for: 2, minimal: true, historyOn: true)
        let three = PanelModel.height(for: 3, minimal: true, historyOn: true)

        XCTAssertEqual(empty, one)
        XCTAssertLessThan(one, two)
        XCTAssertLessThan(two, three)
        XCTAssertEqual(PanelModel.height(for: 200, minimal: true, historyOn: true), PanelModel.maxHeight)
    }

    func testStandardPanelShrinksToOneClipAndStops() {
        let empty = PanelModel.height(for: 0, minimal: false, historyOn: true)
        let one = PanelModel.height(for: 1, minimal: false, historyOn: true)
        let two = PanelModel.height(for: 2, minimal: false, historyOn: true)

        XCTAssertEqual(empty, one)
        XCTAssertLessThan(one, two)
        XCTAssertEqual(PanelModel.height(for: 200, minimal: false, historyOn: true), PanelModel.maxHeight)
    }

    func testGlassPanelAcceptsOneClipFrame() {
        _ = NSApplication.shared
        let panel = HistoryPanel(contentRect: .zero,
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.contentView = Glass.surface(Text("Clip"), cornerRadius: 16, tunable: true)
        panel.setContentSize(NSSize(width: 360, height: PanelModel.maxHeight))

        let oneClipHeight = PanelModel.height(for: 1, minimal: true, historyOn: true)
        panel.setFrame(NSRect(x: 0, y: 0, width: 360, height: oneClipHeight), display: false)

        XCTAssertEqual(panel.frame.height, oneClipHeight)
        XCTAssertLessThan(panel.frame.height, PanelModel.maxHeight)
    }

    func testResizeKeepsAnchoredEdgeAndStaysOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        // Above the caret: bottom edge stays put.
        let above = PanelController.resized(NSRect(x: 0, y: 100, width: 360, height: 200), to: 300, hangsBelow: false, within: screen)
        XCTAssertEqual(above.minY, 100); XCTAssertEqual(above.height, 300)
        // Below the caret: top edge stays put.
        let below = PanelController.resized(NSRect(x: 0, y: 400, width: 360, height: 200), to: 300, hangsBelow: true, within: screen)
        XCTAssertEqual(below.maxY, 600)
        // Growing past the top of the screen gets pushed back down inside it.
        let tall = PanelController.resized(NSRect(x: 0, y: 500, width: 360, height: 200), to: 400, hangsBelow: false, within: screen)
        XCTAssertLessThanOrEqual(tall.maxY, screen.maxY - 8)
    }

    func testViewFillsWindowWhateverTheModelHeight() {
        _ = NSApplication.shared
        let model = PanelModel()
        let controller = NSHostingController(rootView: HistoryView(model: model))
        // A root pinned to model.height gets centred and clipped in a mismatched window;
        // it has to take whatever height it is offered, so the window alone decides.
        for offered: CGFloat in [150, PanelModel.maxHeight] {
            let size = controller.sizeThatFits(in: CGSize(width: 360, height: offered))
            XCTAssertEqual(size.height, offered, accuracy: 0.5)
        }
    }
}
