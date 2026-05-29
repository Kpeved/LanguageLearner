import Foundation

/// A single chapter extracted from an EPUB document.
public struct EPUBChapter: Sendable, Equatable {
    /// Optional chapter heading, taken from the OPF `toc` `navPoint`
    /// label or the first heading element in the spine item.
    public let title: String?

    /// Plain-text paragraphs in document order.
    /// Each string has collapsed whitespace and no surrounding blanks.
    public let paragraphs: [String]

    public init(title: String?, paragraphs: [String]) {
        self.title = title
        self.paragraphs = paragraphs
    }
}

/// The full, parsed representation of a reflowable EPUB 2/3 book.
public struct EPUBBook: Sendable, Equatable {
    /// Value of `<dc:title>` from the OPF metadata.
    public let title: String

    /// Value of `<dc:creator>` from the OPF metadata, if present.
    public let author: String?

    /// BCP-47 language tag from `<dc:language>`. May be empty string if absent.
    public let language: String

    /// Raw bytes of the cover image (PNG, JPEG, etc.), or `nil` if no cover
    /// was found. The field is named `coverPNG` per the design contract.
    public let coverPNG: Data?

    /// Chapters in spine order.
    public let chapters: [EPUBChapter]

    public init(title: String, author: String?, language: String, coverPNG: Data?, chapters: [EPUBChapter]) {
        self.title = title
        self.author = author
        self.language = language
        self.coverPNG = coverPNG
        self.chapters = chapters
    }
}

/// Errors thrown by ``EPUBParser/parse(_:)``.
public enum EPUBParseError: Error, Sendable, Equatable {
    /// The supplied file is not a valid ZIP archive.
    case notAZipArchive
    /// `META-INF/container.xml` is absent from the archive.
    case missingContainerXML
    /// The OPF file referenced by `container.xml` was not found.
    case missingOPF
    /// `META-INF/encryption.xml` was found; DRM is not supported.
    case unsupportedEncryption
    /// The OPF `<spine>` element is empty or malformed.
    case malformedSpine
    /// A low-level I/O or filesystem error occurred.
    case ioFailure(message: String)
}
