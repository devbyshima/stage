import Foundation

/// The Studio windows that are open, so AI control knows which recording
/// to work on: the one used last.
@MainActor
final class StudioRegistry {
    static let shared = StudioRegistry()

    private var documents: [StudioDocument] = []

    /// The Studio used most recently.
    var active: StudioDocument? { documents.last }

    func document(for url: URL) -> StudioDocument? {
        documents.last { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    /// Adds `document`, or brings it forward when it's already open.
    func activate(_ document: StudioDocument) {
        documents.removeAll { $0 === document }
        documents.append(document)
    }

    func remove(_ document: StudioDocument) {
        documents.removeAll { $0 === document }
    }
}
