import Testing
import VocabKit

@Suite struct LemmatizerTests {

    @Test func englishInflectionsReduceToLemma() {
        #expect(Lemmatizer.analyze(word: "running", language: "en").lemma == "run")
        #expect(Lemmatizer.analyze(word: "cats", language: "en").lemma == "cat")
    }

    @Test func resultIsLowercased() {
        #expect(Lemmatizer.analyze(word: "Running", language: "en").lemma == "run")
    }

    @Test func phrasesPassThroughUnchanged() {
        let a = Lemmatizer.analyze(word: "give up", language: "en")
        #expect(a.lemma == "give up")
        #expect(a.partOfSpeech == nil)
    }

    @Test func unknownLanguageFallsBackToSurface() {
        // No NLTagger support: lemma is the lowercased surface, never empty.
        let a = Lemmatizer.analyze(word: "Word", language: "zz")
        #expect(a.lemma == "word")
    }

    @Test func emptyInputIsSafe() {
        #expect(Lemmatizer.analyze(word: "   ", language: "en").lemma == "")
    }
}
