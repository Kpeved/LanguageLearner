import Foundation

/// Parses a reflowable EPUB 2/3 file at a given `URL` into an ``EPUBBook``.
public protocol EPUBParser: Sendable {
    /// Parse the EPUB at `url` and return the structured book.
    /// - Throws: ``EPUBParseError`` on any structural or I/O problem.
    func parse(_ url: URL) async throws -> EPUBBook
}

/// Default, production implementation of ``EPUBParser``.
///
/// Parsing is performed on a detached `Task` so the calling actor is
/// not blocked. This type is safe to share across concurrency domains.
public struct DefaultEPUBParser: EPUBParser {
    public init() {}

    public func parse(_ url: URL) async throws -> EPUBBook {
        NSLog("[EPUBParser] DefaultEPUBParser.parse called with %@", url.path)
        return try await Task.detached(priority: .userInitiated) {
            try EPUBParserCore().parse(url)
        }.value
    }
}
