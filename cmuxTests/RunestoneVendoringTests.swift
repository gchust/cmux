import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class RunestoneVendoringTests: XCTestCase {
    func testVendoredRunestoneSmokeSnapshot() {
        let snapshot = VendoredRunestoneSupport.makeSmokeSnapshot()

        XCTAssertEqual(snapshot.text, "# cmux\nVendored Runestone\n")
        XCTAssertTrue(snapshot.isEditable)
        XCTAssertTrue(snapshot.isSelectable)
        XCTAssertEqual(snapshot.themeTypeName, "DefaultTheme")
    }

    func testMarkdownRendererAppliesHeadingAndLinkAttributes() {
        let storage = NSTextStorage(string: "# Title\n\nA [link](https://example.com)\n")
        let theme = MarkdownPanelTheme(colorScheme: .light)

        MarkdownPanelAttributedRenderer.render(
            markdown: storage.string,
            in: storage,
            theme: theme
        )

        let titleRange = (storage.string as NSString).range(of: "Title")
        let headingFont = storage.attribute(.font, at: titleRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(headingFont)
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, theme.font.pointSize)

        let linkRange = (storage.string as NSString).range(of: "[link](https://example.com)")
        let linkValue = storage.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(linkValue?.absoluteString, "https://example.com")
    }
}
