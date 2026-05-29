import Foundation

/// Maps a spine item href (relative to OPF dir) to a chapter title.
/// Parses EPUB 2 NCX (`toc.ncx`) or EPUB 3 Navigation Document.
final class NCXParser: NSObject, XMLParserDelegate {

    // href (relative to NCX dir, without fragment) -> title
    // Both percent-encoded and percent-decoded forms are stored so the spine-side
    // lookup matches regardless of which form the OPF uses.
    private(set) var titles: [String: String] = [:]

    // Stack of (href, title) for the current chain of nested navPoints.
    // Each navPoint commits when it closes, so titles at every nesting depth
    // make it into the map (not just the outermost).
    private var navPointStack: [(href: String?, title: String?)] = []

    // State for navLabel / text elements
    private var insideNavLabel = false
    private var insideText = false
    private var currentText = ""

    // State for EPUB 3 nav <a> elements
    private var insideNavAnchor = false
    private var currentAnchorHref: String?

    func parse(data: Data) {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localPart(elementName)

        switch local {
        case "navPoint":
            navPointStack.append((href: nil, title: nil))

        case "content":
            if !navPointStack.isEmpty, let src = attributeDict["src"] {
                navPointStack[navPointStack.count - 1].href = stripFragment(src)
            }

        case "navLabel":
            insideNavLabel = true
            currentText = ""

        case "text":
            if insideNavLabel {
                insideText = true
                currentText = ""
            }

        // EPUB 3 nav document: <a href="chapter.xhtml">Title</a>
        case "a":
            if let href = attributeDict["href"] {
                insideNavAnchor = true
                currentAnchorHref = stripFragment(href)
                currentText = ""
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText || insideNavLabel || insideNavAnchor {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localPart(elementName)

        switch local {
        case "text":
            insideText = false

        case "navLabel":
            insideNavLabel = false
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !navPointStack.isEmpty {
                navPointStack[navPointStack.count - 1].title = trimmed
            }
            currentText = ""

        case "navPoint":
            // Commit at every level so nested navPoints survive.
            if let top = navPointStack.popLast(),
               let href = top.href, let title = top.title {
                storeTitle(href: href, title: title)
            }

        case "a":
            if insideNavAnchor {
                insideNavAnchor = false
                let title = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let href = currentAnchorHref, !title.isEmpty {
                    storeTitle(href: href, title: title)
                }
                currentAnchorHref = nil
                currentText = ""
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    private func localPart(_ name: String) -> String {
        if let colon = name.firstIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    private func stripFragment(_ href: String) -> String {
        href.components(separatedBy: "#").first ?? href
    }

    /// Store the title under both the raw (possibly percent-encoded) key and the
    /// percent-decoded key, plus their bare filename forms. Makes lookups from the
    /// spine succeed whether the OPF stores hrefs encoded or not.
    private func storeTitle(href: String, title: String) {
        titles[href] = title
        if let decoded = href.removingPercentEncoding, decoded != href {
            titles[decoded] = title
        }
        let filename = (href as NSString).lastPathComponent
        if !filename.isEmpty, titles[filename] == nil {
            titles[filename] = title
        }
        if let decodedFilename = filename.removingPercentEncoding,
           decodedFilename != filename, titles[decodedFilename] == nil {
            titles[decodedFilename] = title
        }
    }
}
