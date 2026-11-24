import AppKit
import Carbon.HIToolbox
import KopiCore
import XCTest
@testable import Kopi

/// Uses private named pasteboards: they never trigger the macOS "Paste from Other Apps" prompt
/// and do not touch the user's clipboard.
final class PasteboardIOTests: XCTestCase {
    private var source: NSPasteboard!
    private var target: NSPasteboard!

    override func setUp() {
        source = NSPasteboard(name: NSPasteboard.Name("kopi.tests.source.\(UUID().uuidString)"))
        target = NSPasteboard(name: NSPasteboard.Name("kopi.tests.target.\(UUID().uuidString)"))
    }

    override func tearDown() {
        source.releaseGlobally()
        target.releaseGlobally()
    }

    private func readContent(maxBytes: Int = 1 << 24, file: StaticString = #filePath, line: UInt = #line) -> ClipContent? {
        switch PasteboardIO.read(source, maxBytes: maxBytes) {
        case .content(let content): return content
        case .ignored: XCTFail("copy was ignored", file: file, line: line)
        case .tooLarge: XCTFail("copy was too large", file: file, line: line)
        }
        return nil
    }

    func testRichTextRoundTrip() throws {
        let rtf = Data("{\\rtf1\\ansi {\\b Hello} world}".utf8)
        let item = NSPasteboardItem()
        item.setString("Hello world", forType: .string)
        item.setData(rtf, forType: .rtf)
        source.clearContents()
        source.writeObjects([item])

        let content = try XCTUnwrap(readContent())
        XCTAssertEqual(content.kind, .richText)

        PasteboardIO.write(content, plainTextOnly: false, to: target)
        XCTAssertEqual(target.string(forType: .string), "Hello world")
        XCTAssertEqual(target.data(forType: .rtf), rtf)
    }

    func testPlainTextPasteDropsFormatting() throws {
        let rtf = Data("{\\rtf1\\ansi {\\b Bold} only}".utf8)
        source.clearContents()
        source.setData(rtf, forType: .rtf)

        let content = try XCTUnwrap(readContent())
        XCTAssertEqual(PasteboardIO.plainText(of: content), "Bold only")

        PasteboardIO.write(content, plainTextOnly: true, to: target)
        let types = try XCTUnwrap(target.types)
        XCTAssertFalse(types.contains(.rtf), "plain-text paste must not carry formatting")
        XCTAssertEqual(target.string(forType: .string), "Bold only")
    }

    func testConcealedCopiesAreIgnored() {
        source.clearContents()
        source.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        source.setString("hunter2", forType: .string)
        source.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        guard case .ignored = PasteboardIO.read(source, maxBytes: 1 << 20) else {
            return XCTFail("a concealed copy must not be recorded")
        }
    }

    func testTiffIsDroppedWhenPngIsPresent() throws {
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: .png)
        item.setData(Data(repeating: 7, count: 1_000), forType: .tiff)
        source.clearContents()
        source.writeObjects([item])

        let content = try XCTUnwrap(readContent())
        XCTAssertEqual(content.items.first?.types, [PasteboardType.png])
    }

    func testOversizedCopyKeepsItsText() throws {
        let item = NSPasteboardItem()
        item.setString("Quarterly numbers", forType: .string)
        item.setData(Data(repeating: 1, count: 3_000_000), forType: .pdf)
        source.clearContents()
        source.writeObjects([item])

        let content = try XCTUnwrap(readContent(maxBytes: 1_000_000))
        XCTAssertEqual(content.allTypes, [PasteboardType.string])
        XCTAssertEqual(content.basicPlainText, "Quarterly numbers")
    }

    func testFilesRoundTrip() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b c.png")]
        source.clearContents()
        source.writeObjects(urls as [NSURL])

        let content = try XCTUnwrap(readContent())
        XCTAssertEqual(content.kind, .files)
        XCTAssertEqual(content.fileURLs.map(\.path), ["/tmp/a.txt", "/tmp/b c.png"])

        PasteboardIO.write(content, plainTextOnly: false, to: target)
        let pasted = target.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(pasted?.map(\.path), ["/tmp/a.txt", "/tmp/b c.png"])
    }

    func testDefaultShortcut() {
        XCTAssertEqual(KeyCombo.default.keyCode, UInt32(kVK_ANSI_Q))
        XCTAssertEqual(KeyCombo.default.modifiers, UInt32(controlKey))
        XCTAssertEqual(KeyCombo.default.modifierFlags, .control)
        XCTAssertTrue(KeyCombo.default.displayString.hasPrefix("⌃"))
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0).displayString, "F5")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)).displayString, "⌥Space")
    }
}
