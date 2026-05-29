import Foundation

/// Parses `META-INF/container.xml` and extracts the path to the OPF rootfile.
final class ContainerXMLParser: NSObject, XMLParserDelegate {

    private var opfPath: String?
    private var parseError: Error?

    /// Returns the OPF rootfile path found in the XML data.
    /// - Throws: ``EPUBParseError/missingContainerXML`` when the expected
    ///   `<rootfile full-path="...">` element is absent.
    func opfPath(from data: Data) throws -> String {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()

        if let error = parseError {
            throw EPUBParseError.ioFailure(message: error.localizedDescription)
        }
        guard let path = opfPath else {
            throw EPUBParseError.missingContainerXML
        }
        return path
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "rootfile", let path = attributeDict["full-path"] {
            opfPath = path
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}
