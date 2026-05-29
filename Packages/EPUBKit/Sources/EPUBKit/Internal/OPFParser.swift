import Foundation

/// A manifest item from the OPF `<manifest>`.
struct ManifestItem {
    let id: String
    let href: String
    let mediaType: String
    let properties: String
}

/// Parsed data extracted from an OPF file.
struct OPFDocument {
    var title: String = ""
    var author: String?
    var language: String = ""
    var coverImageID: String?   // manifest id of the cover image item
    var coverMetaID: String?    // value from <meta name="cover"> fallback
    var manifest: [String: ManifestItem] = [:]
    var spineIDs: [String] = []
    var tocID: String?          // manifest id of the NCX/NAV toc item
}

/// SAX-style parser for EPUB OPF (Open Packaging Format) files.
final class OPFParser: NSObject, XMLParserDelegate {

    private var document = OPFDocument()
    private var parseError: Error?

    // Text accumulation state
    private var currentElement: String = ""
    private var currentText: String = ""
    private var inMetadata = false

    func parse(data: Data) throws -> OPFDocument {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()

        if let error = parseError {
            throw EPUBParseError.ioFailure(message: error.localizedDescription)
        }
        return document
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = localPart(elementName)
        currentElement = localName
        currentText = ""

        switch localName {
        case "metadata":
            inMetadata = true

        case "item":
            // <item id="..." href="..." media-type="..." properties="..."/>
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                let mediaType = attributeDict["media-type"] ?? ""
                let properties = attributeDict["properties"] ?? ""
                let item = ManifestItem(id: id, href: href, mediaType: mediaType, properties: properties)
                document.manifest[id] = item
                if properties.contains("cover-image") {
                    document.coverImageID = id
                }
            }

        case "itemref":
            // <itemref idref="..."/>
            if let idref = attributeDict["idref"] {
                document.spineIDs.append(idref)
            }

        case "spine":
            if let toc = attributeDict["toc"] {
                document.tocID = toc
            }

        case "reference":
            // <guide><reference type="cover" href="..."/></guide> - guide cover fallback
            if let type_ = attributeDict["type"], type_ == "cover",
               let refHref = attributeDict["href"] {
                // find the manifest item matching this href
                for (id, item) in document.manifest where item.href == refHref {
                    if document.coverImageID == nil {
                        document.coverImageID = id
                    }
                }
            }

        case "meta":
            // EPUB2 <meta name="cover" content="itemID"/>
            if let name = attributeDict["name"], name == "cover",
               let content = attributeDict["content"] {
                document.coverMetaID = content
            }

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = localPart(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inMetadata {
            switch localName {
            case "title":
                if document.title.isEmpty { document.title = text }
            case "creator":
                if document.author == nil { document.author = text.isEmpty ? nil : text }
            case "language":
                if document.language.isEmpty { document.language = text }
            case "metadata":
                inMetadata = false
            default:
                break
            }
        }

        currentElement = ""
        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    // MARK: - Helpers

    /// Strip namespace prefix from qualified element names like `dc:title` -> `title`.
    private func localPart(_ name: String) -> String {
        if let colon = name.firstIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }
}
