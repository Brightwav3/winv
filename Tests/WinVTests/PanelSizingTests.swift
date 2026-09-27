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
}
