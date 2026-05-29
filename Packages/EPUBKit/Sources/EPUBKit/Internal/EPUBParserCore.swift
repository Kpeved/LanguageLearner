import Foundation
import ZIPFoundation
import os.log

let epubLogger = Logger(subsystem: "com.languagelearner.epub", category: "EPUBParser")

@inline(__always)
func epubLog(_ message: @autoclosure () -> String) {
    let m = message()
    epubLogger.notice("\(m)")
    NSLog("[EPUBParser] %@", m)
}

/// Synchronous implementation of the EPUB parsing pipeline.
///
/// Called from ``DefaultEPUBParser`` on a detached task.
struct EPUBParserCore {

    func parse(_ url: URL) throws -> EPUBBook {
        let filename = url.lastPathComponent
        epubLog("==== Begin parse: \(filename) ====")

        // Open the ZIP archive.
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            epubLog("notAZipArchive: \(error.localizedDescription)")
            throw EPUBParseError.notAZipArchive
        }

        // Reject DRM-protected EPUBs.
        if archive["META-INF/encryption.xml"] != nil {
            epubLog("unsupportedEncryption: encryption.xml present")
            throw EPUBParseError.unsupportedEncryption
        }

        // Parse META-INF/container.xml to locate the OPF file.
        let containerData = try readEntry(path: "META-INF/container.xml", from: archive,
                                          notFoundError: .missingContainerXML)
        let opfPath = try ContainerXMLParser().opfPath(from: containerData)
        epubLog("container.xml OK -> opfPath: \(opfPath)")

        // Parse the OPF.
        let opfData = try readEntry(path: opfPath, from: archive,
                                    notFoundError: .missingOPF)
        let opfDoc = try OPFParser().parse(data: opfData)
        epubLog("OPF parsed: title=\(opfDoc.title), lang=\(opfDoc.language), manifest=\(opfDoc.manifest.count) items, spine=\(opfDoc.spineIDs.count) ids, tocID=\(opfDoc.tocID ?? "<nil>")")

        guard !opfDoc.spineIDs.isEmpty else {
            epubLog("malformedSpine: spine has 0 ids in \(filename)")
            throw EPUBParseError.malformedSpine
        }

        // The OPF directory is needed to resolve relative hrefs.
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        // Load chapter titles from the NCX / NAV document.
        let chapterTitles = loadChapterTitles(from: opfDoc, opfDir: opfDir, archive: archive)
        epubLog("Chapter titles loaded: \(chapterTitles.count) entries")

        // Resolve spine items and parse each as XHTML.
        let chapters = try parseChapters(opfDoc: opfDoc, opfDir: opfDir, archive: archive,
                                         titleMap: chapterTitles)

        // Cover image.
        let coverData = loadCoverData(opfDoc: opfDoc, opfDir: opfDir, archive: archive)

        epubLog("==== End parse: \(filename) -> \(chapters.count) chapters, cover=\(coverData == nil ? "no" : "yes") ====")

        return EPUBBook(
            title: opfDoc.title.isEmpty ? "Unknown" : opfDoc.title,
            author: opfDoc.author,
            language: opfDoc.language,
            coverPNG: coverData,
            chapters: chapters
        )
    }

    // MARK: - Private helpers

    /// Read a ZIP entry into `Data`, throwing the given error when the entry is absent.
    /// EPUB hrefs are URI references and may be percent-encoded (e.g. spaces as `%20`),
    /// while the ZIP central directory stores literal filenames. Try both forms.
    private func readEntry(path: String, from archive: Archive, notFoundError: EPUBParseError) throws -> Data {
        if let entry = archive[path] {
            return try extractData(entry: entry, from: archive)
        }
        if let decoded = path.removingPercentEncoding, decoded != path, let entry = archive[decoded] {
            return try extractData(entry: entry, from: archive)
        }
        throw notFoundError
    }

    /// Extract `Data` from a `ZIPFoundation.Entry`.
    private func extractData(entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        do {
            _ = try archive.extract(entry, consumer: { chunk in
                data.append(chunk)
            })
        } catch {
            throw EPUBParseError.ioFailure(message: error.localizedDescription)
        }
        return data
    }

    /// Return `nil` (not throwing) if the entry is absent or unreadable.
    /// Tries both the path as-given and a percent-decoded form, to handle EPUB
    /// manifests whose hrefs use URL-encoding (`%20`, etc.) for filenames that
    /// are stored literally in the ZIP.
    private func tryReadEntry(path: String, from archive: Archive) -> Data? {
        if let entry = archive[path] {
            return try? extractData(entry: entry, from: archive)
        }
        if let decoded = path.removingPercentEncoding, decoded != path,
           let entry = archive[decoded] {
            return try? extractData(entry: entry, from: archive)
        }
        return nil
    }

    /// Build a map from spine-item href (without fragment, relative to OPF dir) -> chapter title.
    private func loadChapterTitles(
        from opfDoc: OPFDocument,
        opfDir: String,
        archive: Archive
    ) -> [String: String] {
        // Prefer toc attribute on <spine>, fall back to scanning manifest for ncx / nav.
        let tocID: String? = opfDoc.tocID ?? opfDoc.manifest.values
            .first(where: { $0.mediaType == "application/x-dtbncx+xml" })?.id
            ?? opfDoc.manifest.values
            .first(where: { $0.properties == "nav" })?.id

        guard let id = tocID, let item = opfDoc.manifest[id] else {
            return [:]
        }

        let tocPath = joinPath(opfDir, item.href)
        guard let tocData = tryReadEntry(path: tocPath, from: archive) else {
            return [:]
        }

        let ncxParser = NCXParser()
        ncxParser.parse(data: tocData)
        return ncxParser.titles
    }

    /// Parse each spine item and return the chapters array.
    private func parseChapters(
        opfDoc: OPFDocument,
        opfDir: String,
        archive: Archive,
        titleMap: [String: String]
    ) throws -> [EPUBChapter] {
        let stripper = XHTMLStripper()
        var chapters: [EPUBChapter] = []

        var skippedNotInManifest = 0
        var skippedMediaType = 0
        var skippedMissingFile = 0
        var skippedEmptyAndUntitled = 0

        for spineID in opfDoc.spineIDs {
            guard let item = opfDoc.manifest[spineID] else {
                skippedNotInManifest += 1
                epubLog("spine id=\(spineID) not in manifest, skipping")
                continue
            }

            // Skip non-content items (e.g. media overlays).
            let mt = item.mediaType.lowercased()
            guard mt.contains("html") || mt.contains("xhtml") || mt.isEmpty else {
                skippedMediaType += 1
                epubLog("spine id=\(spineID) mediaType=\(item.mediaType), not html/xhtml, skipping")
                continue
            }

            let itemPath = joinPath(opfDir, item.href)

            // Title lookup: try exact href, decoded href, just filename, decoded filename, no-fragment.
            let hrefForTitle = item.href
            let decodedHref = hrefForTitle.removingPercentEncoding ?? hrefForTitle
            let filename = (item.href as NSString).lastPathComponent
            let decodedFilename = filename.removingPercentEncoding ?? filename
            let title = titleMap[hrefForTitle]
                ?? titleMap[decodedHref]
                ?? titleMap[filename]
                ?? titleMap[decodedFilename]
                ?? titleMap[stripFragment(hrefForTitle)]
                ?? titleMap[stripFragment(decodedHref)]

            guard let data = tryReadEntry(path: itemPath, from: archive) else {
                // Missing spine item - skip rather than hard-fail; real EPUBs sometimes omit items.
                skippedMissingFile += 1
                epubLog("spine id=\(spineID) file \(itemPath) missing in zip, skipping")
                continue
            }

            let paragraphs = stripper.strip(data: data)
            epubLog("spine id=\(spineID) href=\(item.href) bytes=\(data.count) paragraphs=\(paragraphs.count) title=\(title ?? "<none>")")

            // Only include chapters with actual content.
            if !paragraphs.isEmpty || title != nil {
                chapters.append(EPUBChapter(title: title, paragraphs: paragraphs))
            } else {
                skippedEmptyAndUntitled += 1
                epubLog("spine id=\(spineID) produced 0 paragraphs AND no title, skipping")
            }
        }

        epubLog("parseChapters summary: kept=\(chapters.count) notInManifest=\(skippedNotInManifest) mediaType=\(skippedMediaType) missingFile=\(skippedMissingFile) emptyUntitled=\(skippedEmptyAndUntitled)")
        return chapters
    }

    /// Extract cover image bytes from the OPF manifest.
    private func loadCoverData(
        opfDoc: OPFDocument,
        opfDir: String,
        archive: Archive
    ) -> Data? {
        // Prefer properties="cover-image", then <meta name="cover"> fallback.
        let coverID = opfDoc.coverImageID ?? opfDoc.coverMetaID
        guard let id = coverID, let item = opfDoc.manifest[id] else { return nil }

        // Validate it is an image type.
        let mt = item.mediaType.lowercased()
        guard mt.hasPrefix("image/") else { return nil }

        let path = joinPath(opfDir, item.href)
        return tryReadEntry(path: path, from: archive)
    }

    // MARK: - Path utilities

    /// Join an OPF-relative directory with an item href, normalising `..` and `.`.
    private func joinPath(_ dir: String, _ href: String) -> String {
        if dir.isEmpty { return href }
        let raw = dir + "/" + href
        return normalisePath(raw)
    }

    private func normalisePath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        var normalised: [String] = []
        for component in components {
            switch component {
            case ".", "":
                break
            case "..":
                if !normalised.isEmpty { normalised.removeLast() }
            default:
                normalised.append(component)
            }
        }
        return normalised.joined(separator: "/")
    }

    private func stripFragment(_ href: String) -> String {
        href.components(separatedBy: "#").first ?? href
    }
}
