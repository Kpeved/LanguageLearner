import SwiftUI
import SwiftData
import LibraryStore
import TTSService

@main
struct LanguageLearnerApp: App {
    let modelContainer: ModelContainer
    let store: DefaultLibraryStore
    let tts: DefaultTTSService

    init() {
        NSLog("[App] LanguageLearnerApp.init() called -- if you see this, console works.")
        print("[App-print] LanguageLearnerApp.init() called via print().")
        let schema = Schema([PairedEntry.self, Book.self])
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
    }

    var body: some Scene {
        WindowGroup {
            LibraryRootView(store: store, tts: tts)
        }
        .modelContainer(modelContainer)
    }
}
