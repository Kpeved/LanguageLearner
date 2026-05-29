import Foundation
import EPUBKit

/// Codable mirror of `EPUBChapter`, used for on-disk JSON serialisation.
/// EPUBChapter itself is not Codable, so we convert at the boundary.
struct ChapterDTO: Codable {
    let title: String?
    let paragraphs: [String]

    init(from chapter: EPUBChapter) {
        self.title = chapter.title
        self.paragraphs = chapter.paragraphs
    }

    func toEPUBChapter() -> EPUBChapter {
        EPUBChapter(title: title, paragraphs: paragraphs)
    }
}
