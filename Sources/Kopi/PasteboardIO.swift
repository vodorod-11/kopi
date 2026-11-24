import AppKit
import KopiCore

/// Reads the general pasteboard into a `ClipContent` and writes clips back to it.
enum PasteboardIO {
    enum ReadResult {
        case content(ClipContent)
        /// Empty, or marked as a password / throw-away copy.
        case ignored
        /// Bigger than the size limit even without images.
        case tooLarge(Int)
    }

    static func read(_ pasteboard: NSPasteboard, maxBytes: Int) -> ReadResult {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else { return .ignored }
        let types = Set(pasteboardItems.flatMap { $0.types.map(\.rawValue) })
        if !types.isDisjoint(with: PasteboardType.ignoredMarkers) { return .ignored }

        var items: [ClipItem] = []
        var total = 0
        for pasteboardItem in pasteboardItems {
            let itemTypes = pasteboardItem.types.map(\.rawValue)
            // TIFF is often a much bigger duplicate of a PNG or JPEG on the same item.
            let hasCompactImage = itemTypes.contains { PasteboardType.imageTypes.contains($0) && $0 != PasteboardType.tiff }
            var representations: [Representation] = []
            for type in pasteboardItem.types {
                if type.rawValue == PasteboardType.tiff && hasCompactImage { continue }
                guard let data = pasteboardItem.data(forType: type) else { continue }
                representations.append(Representation(type: type.rawValue, data: data))
                total += data.count
            }
            if !representations.isEmpty {
                items.append(ClipItem(representations))
            }
        }
        guard !items.isEmpty else { return .ignored }

        var content = ClipContent(items: items)
        if total > maxBytes {
            // Keep the text and file parts of an oversized copy (Office copies carry big previews).
            let keep = PasteboardType.textTypes.union(PasteboardType.richTextTypes).union([PasteboardType.fileURL, PasteboardType.url])
            let reduced = items.map { ClipItem($0.representations.filter { keep.contains($0.type) }) }.filter { !$0.representations.isEmpty }
            content = ClipContent(items: reduced)
            if reduced.isEmpty || content.byteSize > maxBytes { return .tooLarge(total) }
        }
        return .content(content)
    }

    /// Plain text for a clip: plain text, file paths, or text converted from RTF / HTML.
    static func plainText(of content: ClipContent) -> String? {
        if let text = content.basicPlainText { return text }
        if let rtf = content.firstData(forAnyOf: [PasteboardType.rtf]),
           let string = NSAttributedString(rtf: rtf.data, documentAttributes: nil)?.string {
            return string
        }
        if let rtfd = content.firstData(forAnyOf: [PasteboardType.rtfd]),
           let string = NSAttributedString(rtfd: rtfd.data, documentAttributes: nil)?.string {
            return string
        }
        if let html = content.firstData(forAnyOf: [PasteboardType.html]),
           let string = NSAttributedString(html: html.data, documentAttributes: nil)?.string {
            return string
        }
        return nil
    }

    /// Puts a clip on the pasteboard and returns the new change count.
    @discardableResult
    static func write(_ content: ClipContent, plainTextOnly: Bool, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        if plainTextOnly {
            pasteboard.setString(plainText(of: content) ?? "", forType: .string)
        } else {
            let objects: [NSPasteboardItem] = content.items.map { item in
                let pasteboardItem = NSPasteboardItem()
                for representation in item.representations {
                    pasteboardItem.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                return pasteboardItem
            }
            pasteboard.writeObjects(objects)
        }
        return pasteboard.changeCount
    }
}
