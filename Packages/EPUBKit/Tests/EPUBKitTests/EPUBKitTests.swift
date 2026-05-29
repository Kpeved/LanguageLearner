import Testing
import Foundation
import ZIPFoundation
@testable import EPUBKit

// MARK: - EPUB fixture builder

/// Builds a minimal, valid EPUB 2 ZIP archive in a temporary directory and
/// returns the URL to the `.epub` file.
private func buildMinimalEPUB(
    title: String = "Test Book",
    author: String = "Test Author",
    language: String = "en",
    chapters: [(title: String, paragraphs: [String])],
    includeEncryptionXML: Bool = false
) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let epubURL = tempDir.appendingPathComponent("test.epub")

    let archive: Archive
    do {
        archive = try Archive(url: epubURL, accessMode: .create)
    } catch {
        throw EPUBParseError.ioFailure(message: "Cannot create archive: \(error)")
    }

    // --- mimetype ---
    let mimetype = "application/epub+zip"
    try archive.addEntry(with: "mimetype",
                         type: .file,
                         uncompressedSize: Int64(mimetype.utf8.count),
                         provider: { _, _ in Data(mimetype.utf8) })

    // --- META-INF/container.xml ---
    let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
    try addString(container, as: "META-INF/container.xml", to: archive)

    // --- encryption.xml (optional) ---
    if includeEncryptionXML {
        let enc = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"/>
        """
        try addString(enc, as: "META-INF/encryption.xml", to: archive)
    }

    // --- OPF (OEBPS/content.opf) ---
    var manifestItems = ""
    var spineItems = ""
    var ncxNavPoints = ""

    for (index, chapter) in chapters.enumerated() {
        let id = "chapter\(index)"
        let href = "chapter\(index).xhtml"
        manifestItems += """
          <item id="\(id)" href="\(href)" media-type="application/xhtml+xml"/>\n
        """
        spineItems += """
          <itemref idref="\(id)"/>\n
        """
        ncxNavPoints += """
          <navPoint id="navPoint-\(index)" playOrder="\(index + 1)">
            <navLabel><text>\(chapter.title)</text></navLabel>
            <content src="\(href)"/>
          </navPoint>\n
        """
    }
    manifestItems += """
      <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    """

    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>\(title)</dc:title>
        <dc:creator>\(author)</dc:creator>
        <dc:language>\(language)</dc:language>
      </metadata>
      <manifest>
        \(manifestItems)
      </manifest>
      <spine toc="ncx">
        \(spineItems)
      </spine>
    </package>
    """
    try addString(opf, as: "OEBPS/content.opf", to: archive)

    // --- NCX (OEBPS/toc.ncx) ---
    // No DOCTYPE declaration: XMLParser may attempt to resolve external DTD URLs, which fails offline.
    let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <navMap>
        \(ncxNavPoints)
      </navMap>
    </ncx>
    """
    try addString(ncx, as: "OEBPS/toc.ncx", to: archive)

    // --- Chapter XHTML files ---
    for (index, chapter) in chapters.enumerated() {
        let paragraphsXML = chapter.paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n    ")
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>\(chapter.title)</title></head>
          <body>
            \(paragraphsXML)
          </body>
        </html>
        """
        try addString(xhtml, as: "OEBPS/chapter\(index).xhtml", to: archive)
    }

    return epubURL
}

private func addString(_ string: String, as path: String, to archive: Archive) throws {
    let data = Data(string.utf8)
    try archive.addEntry(with: path,
                         type: .file,
                         uncompressedSize: Int64(data.count),
                         provider: { _, _ in data })
}

// MARK: - Happy-path round-trip test

@Test("Full round-trip: parse synthetic EPUB and verify chapter/paragraph counts")
func testFullRoundTrip() async throws {
    let chapters: [(title: String, paragraphs: [String])] = [
        ("Introduction", ["First paragraph of the introduction.", "Second paragraph here."]),
        ("Chapter One",  ["Once upon a time.", "The story continues.", "And so it goes."]),
        ("Chapter Two",  ["A new beginning.", "More text follows."])
    ]

    let url = try buildMinimalEPUB(title: "My Novel", author: "Jane Doe", language: "en",
                                   chapters: chapters)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let parser = DefaultEPUBParser()
    let book = try await parser.parse(url)

    #expect(book.title == "My Novel")
    #expect(book.author == "Jane Doe")
    #expect(book.language == "en")
    #expect(book.coverPNG == nil)
    #expect(book.chapters.count == chapters.count)
    #expect(book.chapters[0].title == "Introduction")
    #expect(book.chapters[0].paragraphs.count == 2)
    #expect(book.chapters[1].title == "Chapter One")
    #expect(book.chapters[1].paragraphs.count == 3)
    #expect(book.chapters[2].title == "Chapter Two")
    #expect(book.chapters[2].paragraphs.count == 2)
}

// MARK: - Error surface tests

@Test("missingContainerXML is thrown when container.xml is absent")
func testMissingContainerXML() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let epubURL = tempDir.appendingPathComponent("empty.epub")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let archive: Archive
    do {
        archive = try Archive(url: epubURL, accessMode: .create)
    } catch {
        Issue.record("Could not create archive: \(error)")
        return
    }
    let mimetype = "application/epub+zip"
    try archive.addEntry(with: "mimetype",
                         type: .file,
                         uncompressedSize: Int64(mimetype.utf8.count),
                         provider: { _, _ in Data(mimetype.utf8) })

    let parser = DefaultEPUBParser()
    do {
        _ = try await parser.parse(epubURL)
        Issue.record("Expected EPUBParseError.missingContainerXML")
    } catch EPUBParseError.missingContainerXML {
        // Expected
    }
}

@Test("unsupportedEncryption is thrown when encryption.xml is present")
func testUnsupportedEncryption() async throws {
    let url = try buildMinimalEPUB(
        chapters: [("Ch1", ["Hello."])],
        includeEncryptionXML: true
    )
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let parser = DefaultEPUBParser()
    do {
        _ = try await parser.parse(url)
        Issue.record("Expected EPUBParseError.unsupportedEncryption")
    } catch EPUBParseError.unsupportedEncryption {
        // Expected
    }
}

@Test("notAZipArchive is thrown for a non-ZIP file")
func testNotAZipArchive() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let fakeURL = tempDir.appendingPathComponent("not_an_epub.epub")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try Data("this is not a zip file".utf8).write(to: fakeURL)

    let parser = DefaultEPUBParser()
    do {
        _ = try await parser.parse(fakeURL)
        Issue.record("Expected EPUBParseError.notAZipArchive")
    } catch EPUBParseError.notAZipArchive {
        // Expected
    }
}

// MARK: - XHTMLStripper unit tests

@Test("XHTMLStripper: whitespace collapsing")
func testWhitespaceCollapsing() {
    let stripper = XHTMLStripper()
    let xhtml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <body>
        <p>  Hello   \n  world  </p>
        <p>   </p>
        <p>Another\tparagraph here.</p>
      </body>
    </html>
    """
    let paragraphs = stripper.strip(data: Data(xhtml.utf8))
    #expect(paragraphs.count == 2)
    #expect(paragraphs[0] == "Hello world")
    #expect(paragraphs[1] == "Another paragraph here.")
}

@Test("XHTMLStripper: HTML entity decoding")
func testEntityDecoding() {
    let stripper = XHTMLStripper()
    let xhtml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <body>
        <p>Tom &amp; Jerry</p>
        <p>Less than: &lt; greater: &gt;</p>
        <p>Non-breaking&#160;space and &#x201C;quotes&#x201D;.</p>
      </body>
    </html>
    """
    let paragraphs = stripper.strip(data: Data(xhtml.utf8))
    #expect(paragraphs.count == 3)
    #expect(paragraphs[0] == "Tom & Jerry")
    #expect(paragraphs[1] == "Less than: < greater: >")
    // &#160; is non-breaking space (U+00A0), &#x201C; / &#x201D; are curly quotes
    #expect(paragraphs[2].contains("\u{00A0}"))
    #expect(paragraphs[2].contains("\u{201C}"))
    #expect(paragraphs[2].contains("\u{201D}"))
}

@Test("XHTMLStripper: script and style elements are skipped")
func testScriptAndStyleSkipped() {
    let stripper = XHTMLStripper()
    let xhtml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head>
        <style>body { color: red; }</style>
        <script>var x = 1;</script>
      </head>
      <body>
        <p>Visible text.</p>
        <nav><p>Nav should be skipped.</p></nav>
        <p>Also visible.</p>
      </body>
    </html>
    """
    let paragraphs = stripper.strip(data: Data(xhtml.utf8))
    #expect(paragraphs.count == 2)
    #expect(paragraphs[0] == "Visible text.")
    #expect(paragraphs[1] == "Also visible.")
}

@Test("XHTMLStripper: heading elements produce paragraphs")
func testHeadingsProduceParagraphs() {
    let stripper = XHTMLStripper()
    let xhtml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <body>
        <h1>Chapter Title</h1>
        <h2>Section</h2>
        <p>Body text.</p>
      </body>
    </html>
    """
    let paragraphs = stripper.strip(data: Data(xhtml.utf8))
    #expect(paragraphs.count == 3)
    #expect(paragraphs[0] == "Chapter Title")
    #expect(paragraphs[1] == "Section")
    #expect(paragraphs[2] == "Body text.")
}

// MARK: - EPUBBook/EPUBChapter model conformances

@Test("EPUBChapter and EPUBBook are Equatable and Sendable")
func testModelConformances() {
    let ch1 = EPUBChapter(title: "Ch1", paragraphs: ["Hello."])
    let ch2 = EPUBChapter(title: "Ch1", paragraphs: ["Hello."])
    #expect(ch1 == ch2)

    let book1 = EPUBBook(title: "A", author: nil, language: "en", coverPNG: nil, chapters: [ch1])
    let book2 = EPUBBook(title: "A", author: nil, language: "en", coverPNG: nil, chapters: [ch2])
    #expect(book1 == book2)
}

@Test("EPUBParseError is Equatable")
func testParseErrorEquatable() {
    #expect(EPUBParseError.notAZipArchive == EPUBParseError.notAZipArchive)
    #expect(EPUBParseError.missingContainerXML != EPUBParseError.missingOPF)
    #expect(EPUBParseError.ioFailure(message: "boom") == EPUBParseError.ioFailure(message: "boom"))
    #expect(EPUBParseError.ioFailure(message: "a") != EPUBParseError.ioFailure(message: "b"))
}
