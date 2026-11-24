import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import KopiCore

final class ClipStoreTests: XCTestCase {
    private var store: ClipStore!

    override func setUpWithError() throws {
        store = try ClipStore(path: ":memory:")
    }

    func testInsertAndReadBackText() throws {
        let content = ClipContent(text: "Hello   world\n  second line")
        let result = try store.insert(content, sourceBundleID: "com.example.editor", sourceName: "Editor")
        guard case .inserted(let id) = result else { return XCTFail("expected a new clip, got \(result)") }

        let clips = try store.clips()
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].title, "Hello world second line")
        XCTAssertEqual(clips[0].kind, .text)
        XCTAssertEqual(clips[0].sourceName, "Editor")
        XCTAssertEqual(try store.content(id: id), content)
    }

    func testRepeatedCopyMovesExistingClipToTop() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = try store.insert(ClipContent(text: "alpha"), now: start)
        try store.insert(ClipContent(text: "beta"), now: start.addingTimeInterval(1))
        let again = try store.insert(ClipContent(text: "alpha"), now: start.addingTimeInterval(2))

        XCTAssertEqual(again, .updated(first.id))
        XCTAssertEqual(try store.clips().map(\.title), ["alpha", "beta"])
    }

    func testRichTextWithSamePlainTextIsTheSameClip() throws {
        let plain = ClipContent(text: "same words")
        var rich = ClipContent(text: "same words")
        rich.items[0].representations.append(Representation(type: PasteboardType.rtf, data: Data("{\\rtf1 same words}".utf8)))
        let first = try store.insert(plain)
        XCTAssertEqual(try store.insert(rich), .updated(first.id))
    }

    func testSearchIsCaseInsensitiveForCyrillicAndLatin() throws {
        try store.insert(ClipContent(text: "Здравей, Свят"))
        try store.insert(ClipContent(text: "Hello World"))

        XCTAssertEqual(try store.clips(query: "здравей").map(\.title), ["Здравей, Свят"])
        XCTAssertEqual(try store.clips(query: "СВЯТ здр").map(\.title), ["Здравей, Свят"])
        XCTAssertEqual(try store.clips(query: "WORLD").map(\.title), ["Hello World"])
        XCTAssertTrue(try store.clips(query: "missing").isEmpty)
    }

    func testSearchTreatsWildcardCharactersLiterally() throws {
        try store.insert(ClipContent(text: "50% off_today"))
        try store.insert(ClipContent(text: "nothing special"))
        XCTAssertEqual(try store.clips(query: "%").map(\.title), ["50% off_today"])
        XCTAssertEqual(try store.clips(query: "_").map(\.title), ["50% off_today"])
    }

    func testTrimByCountKeepsPinnedAndGroupedClips() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var ids: [Int64] = []
        for index in 0..<6 {
            ids.append(try store.insert(ClipContent(text: "clip \(index)"), now: start.addingTimeInterval(Double(index))).id)
        }
        try store.setPinned(ids[0], true)
        let group = try store.createGroup(named: "Keep")
        try store.setGroup(ids[1], group)

        let removed = try store.trim(maxCount: 2, maxAge: 0)

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(Set(try store.clips().map(\.title)), ["clip 0", "clip 1", "clip 4", "clip 5"])
    }

    func testTrimByAge() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        try store.insert(ClipContent(text: "old"), now: now.addingTimeInterval(-10 * 86_400))
        try store.insert(ClipContent(text: "new"), now: now.addingTimeInterval(-60))

        XCTAssertEqual(try store.trim(maxCount: 0, maxAge: 7 * 86_400, now: now), 1)
        XCTAssertEqual(try store.clips().map(\.title), ["new"])
    }

    func testDeleteRemovesDataToo() throws {
        let id = try store.insert(ClipContent(text: "gone soon")).id
        try store.delete(id)
        XCTAssertNil(try store.content(id: id))
        XCTAssertEqual(try store.database.scalar("SELECT COUNT(*) FROM clip_data"), 0)
    }

    func testClearHistoryKeepsPinnedAndGrouped() throws {
        let pinned = try store.insert(ClipContent(text: "pinned")).id
        let grouped = try store.insert(ClipContent(text: "grouped")).id
        try store.insert(ClipContent(text: "plain"))
        try store.setPinned(pinned, true)
        try store.setGroup(grouped, try store.createGroup(named: "Work"))

        XCTAssertEqual(try store.clearHistory(), 1)
        XCTAssertEqual(Set(try store.clips().map(\.title)), ["pinned", "grouped"])
    }

    func testPinnedClipsComeFirstInAllButNotInsideFilters() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let old = try store.insert(ClipContent(text: "old pinned"), now: start).id
        try store.insert(ClipContent(text: "newer"), now: start.addingTimeInterval(1))
        try store.setPinned(old, true)

        XCTAssertEqual(try store.clips().map(\.title), ["old pinned", "newer"])
        XCTAssertEqual(try store.clips(filter: .pinned).map(\.title), ["old pinned"])
    }

    func testGroups() throws {
        let work = try store.createGroup(named: "Work")
        let home = try store.createGroup(named: "Home")
        let clip = try store.insert(ClipContent(text: "meeting notes")).id
        try store.setGroup(clip, work)

        XCTAssertEqual(try store.groups().map(\.name), ["Work", "Home"])
        XCTAssertEqual(try store.groups().first?.clipCount, 1)
        XCTAssertEqual(try store.clips(filter: .group(work)).map(\.id), [clip])
        XCTAssertTrue(try store.clips(filter: .group(home)).isEmpty)

        try store.renameGroup(home, to: "Personal")
        XCTAssertEqual(try store.groups().map(\.name), ["Work", "Personal"])

        try store.deleteGroup(work)
        XCTAssertEqual(try store.groups().map(\.name), ["Personal"])
        XCTAssertNil(try store.clip(id: clip)?.groupID, "clips of a deleted group stay in the history")
    }

    func testMarkUsed() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = try store.insert(ClipContent(text: "first"), now: start).id
        try store.insert(ClipContent(text: "second"), now: start.addingTimeInterval(1))

        try store.markUsed(first, moveToTop: false, now: start.addingTimeInterval(2))
        XCTAssertEqual(try store.clips().map(\.title), ["second", "first"])

        try store.markUsed(first, moveToTop: true, now: start.addingTimeInterval(3))
        XCTAssertEqual(try store.clips().map(\.title), ["first", "second"])
        XCTAssertEqual(try store.clip(id: first)?.useCount, 2)
    }

    func testFileClip() throws {
        let content = ClipContent(items: [
            ClipItem([Representation(type: PasteboardType.fileURL, data: Data("file:///Users/me/a.txt".utf8))]),
            ClipItem([Representation(type: PasteboardType.fileURL, data: Data("file:///Users/me/b%20c.png".utf8))]),
        ])
        XCTAssertEqual(content.kind, .files)
        XCTAssertEqual(content.basicPlainText, "/Users/me/a.txt\n/Users/me/b c.png")

        let id = try store.insert(content).id
        XCTAssertEqual(try store.clip(id: id)?.title, "2 files: a.txt, b c.png")
        XCTAssertEqual(try store.clips(query: "b c.png").count, 1)
    }

    func testImageClipGetsTitleAndThumbnail() throws {
        let png = makePNG(width: 800, height: 400)
        let content = ClipContent(items: [ClipItem([Representation(type: PasteboardType.png, data: png)])])
        XCTAssertEqual(content.kind, .image)

        let id = try store.insert(content).id
        let summary = try XCTUnwrap(store.clip(id: id))
        XCTAssertEqual(summary.title, "Image 800 × 400")
        XCTAssertTrue(summary.hasThumbnail)

        let thumbnail = try XCTUnwrap(store.thumbnail(id: id))
        let size = try XCTUnwrap(Thumbnailer.pixelSize(thumbnail))
        XCTAssertEqual(size.width, 256)
        XCTAssertEqual(size.height, 128)

        // The same image copied again is not stored twice.
        XCTAssertEqual(try store.insert(content), .updated(id))
    }

    func testStorePersistsOnDisk() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kopi-test-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        do {
            let disk = try ClipStore(path: path)
            try disk.insert(ClipContent(text: "kept across launches"))
        }
        let reopened = try ClipStore(path: path)
        XCTAssertEqual(try reopened.clips().map(\.title), ["kept across launches"])
    }

    private func makePNG(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

final class ClipTextTests: XCTestCase {
    func testTitleCollapsesWhitespace() {
        XCTAssertEqual(ClipText.title("  one\n\n\ttwo   three  "), "one two three")
        XCTAssertEqual(ClipText.title(" \n\t "), "")
    }

    func testTitleIsLimited() {
        XCTAssertEqual(ClipText.title("abcdef", limit: 3), "abc…")
        XCTAssertEqual(ClipText.title("abc", limit: 3), "abc")
    }

    func testKinds() {
        var rich = ClipContent(text: "x")
        rich.items[0].representations.append(Representation(type: PasteboardType.html, data: Data("<b>x</b>".utf8)))
        XCTAssertEqual(rich.kind, .richText)

        // A browser's "Copy Image" also writes HTML; it is still an image.
        let image = ClipContent(items: [ClipItem([
            Representation(type: PasteboardType.html, data: Data("<img src=x>".utf8)),
            Representation(type: PasteboardType.tiff, data: Data([1, 2, 3])),
        ])])
        XCTAssertEqual(image.kind, .image)

        let other = ClipContent(items: [ClipItem([Representation(type: "com.example.custom", data: Data([1]))])])
        XCTAssertEqual(other.kind, .other)
    }
}
