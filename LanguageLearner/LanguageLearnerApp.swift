import SwiftUI
import SwiftData
import LibraryStore
import TTSService
import VocabKit

@main
struct LanguageLearnerApp: App {
    let modelContainer: ModelContainer
    let store: DefaultLibraryStore
    let tts: DefaultTTSService
    let vocab: DefaultVocabStore

    init() {
        NSLog("[App] LanguageLearnerApp.init() called -- if you see this, console works.")
        let schema = Schema([PairedEntry.self, Book.self, VocabCard.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        self.modelContainer = container
        self.store = DefaultLibraryStore(modelContext: container.mainContext)
        self.tts = DefaultTTSService()
        self.vocab = DefaultVocabStore(modelContext: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            LibraryRootView(store: store, tts: tts, vocab: vocab)
        }
        .modelContainer(modelContainer)
    }
}
