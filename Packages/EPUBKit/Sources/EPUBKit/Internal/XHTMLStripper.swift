import Foundation

/// Converts an XHTML/HTML document to a list of plain-text paragraphs.
///
/// Paragraph-like elements (`<p>`, `<h1>`-`<h6>`, `<li>`) each produce one
/// paragraph string. `<script>`, `<style>`, and `<nav>` elements are skipped
/// in their entirety. Whitespace is collapsed and HTML entities are decoded.
final class XHTMLStripper: NSObject, XMLParserDelegate {

    private var paragraphs: [String] = []
    private var currentText: String = ""
    private var isCapturing = false
    private var skipDepth = 0        // depth while inside a skipped element
    private var skipElements: Set<String> = ["script", "style", "nav"]
    private var paragraphElements: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "dt", "dd", "blockquote"]

    func strip(data: Data) -> [String] {
        paragraphs = []
        currentText = ""
        isCapturing = false
        skipDepth = 0

        // XMLParser requires well-formed XML; XHTML should be fine.
        // Wrap in a root element to handle bare fragments.
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldProcessNamespaces = false
        xmlParser.shouldReportNamespacePrefixes = false
        xmlParser.delegate = self
        let ok = xmlParser.parse()
        if !ok {
            let err = xmlParser.parserError
            let line = xmlParser.lineNumber
            let col = xmlParser.columnNumber
            epubLog("XHTMLStripper: XMLParser FAILED at line \(line) col \(col): \(err?.localizedDescription ?? "<no err>"). Bytes=\(data.count), paragraphs salvaged so far=\(self.paragraphs.count)")
        }

        // Flush any trailing text that was not closed by an end element.
        flush()
        return paragraphs
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()

        if skipDepth > 0 {
            skipDepth += 1
            return
        }

        if skipElements.contains(name) {
            skipDepth = 1
            return
        }

        if paragraphElements.contains(name) {
            // Flush any text accumulated before this block-level element.
            flush()
            isCapturing = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0, isCapturing else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()

        if skipDepth > 0 {
            skipDepth -= 1
            return
        }

        if paragraphElements.contains(name) {
            flush()
            isCapturing = false
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // Best-effort: flush whatever we have.
        flush()
    }

    // MARK: - Helpers

    private func flush() {
        guard isCapturing else { return }
        let paragraph = normalise(currentText)
        if !paragraph.isEmpty {
            paragraphs.append(paragraph)
        }
        currentText = ""
    }

    /// Collapse whitespace runs to a single space and trim the result.
    /// U+00A0 (non-breaking space) is preserved as-is; only ASCII whitespace
    /// and Unicode line/paragraph separators are collapsed.
    private func normalise(_ text: String) -> String {
        let decoded = decodeEntities(text)
        // Collapse runs of regular whitespace (space, tab, newlines) to a single space.
        // We intentionally do NOT split on U+00A0 so it is preserved.
        var result = ""
        var inWhitespace = false
        for ch in decoded {
            if ch == "\u{00A0}" {
                // Always emit non-breaking space directly.
                inWhitespace = false
                result.append(ch)
            } else if ch.isWhitespace || ch.isNewline {
                if !inWhitespace {
                    inWhitespace = true
                    result.append(" ")
                }
            } else {
                inWhitespace = false
                result.append(ch)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Decode common HTML/XML character references that Foundation's XMLParser
    /// does not automatically expand (e.g. `&nbsp;`, numeric references).
    private func decodeEntities(_ text: String) -> String {
        var result = text
        // Named entities not handled by XMLParser
        let namedEntities: [(String, String)] = [
            ("&nbsp;", "\u{00A0}"),
            ("&shy;",  "\u{00AD}"),
            ("&copy;", "\u{00A9}"),
            ("&reg;",  "\u{00AE}"),
            ("&trade;","\u{2122}"),
            ("&mdash;","\u{2014}"),
            ("&ndash;","\u{2013}"),
            ("&laquo;","\u{00AB}"),
            ("&raquo;","\u{00BB}"),
            ("&ldquo;","\u{201C}"),
            ("&rdquo;","\u{201D}"),
            ("&lsquo;","\u{2018}"),
            ("&rsquo;","\u{2019}"),
            ("&hellip;","\u{2026}"),
            ("&amp;",  "&"),
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&quot;", "\""),
            ("&apos;", "'")
        ]
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decimal numeric references: &#nnnn;
        result = decodeNumericEntities(result, hex: false)
        // Hex numeric references: &#xHHHH;
        result = decodeNumericEntities(result, hex: true)
        return result
    }

    private func decodeNumericEntities(_ text: String, hex: Bool) -> String {
        let pattern = hex ? "&#x([0-9A-Fa-f]+);" : "&#([0-9]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)
        var result = text
        // Process in reverse to preserve string indices.
        for match in matches.reversed() {
            let fullRange = Range(match.range, in: result)!
            let capRange = Range(match.range(at: 1), in: result)!
            let digits = String(result[capRange])
            let codepoint: UInt32?
            if hex {
                codepoint = UInt32(digits, radix: 16)
            } else {
                codepoint = UInt32(digits)
            }
            if let cp = codepoint, let scalar = Unicode.Scalar(cp) {
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }
        return result
    }
}
