import Foundation
import Observation

/// Which of the server's music folders the UI is currently browsing.
///
/// `.all` is expressed by *omitting* `musicFolderId` from the request. Subsonic
/// treats an absent folder id as "every folder", so there is no fan-out, no merge
/// and no de-duplication to write -- the whole feature is one optional query
/// parameter threaded through the client.
enum LibraryScope: Hashable, Sendable {
    case all
    case folder(id: Int, name: String)

    var folderID: Int? {
        if case let .folder(id, _) = self { return id }
        return nil
    }

    /// `nil` means "do not send the parameter", i.e. all folders.
    var queryValue: String? {
        folderID.map(String.init)
    }

    var shortName: String {
        if case let .folder(_, name) = self { return name }
        return "All"
    }
}

@MainActor
@Observable
final class LibraryScopeStore {
    private static let defaultsKey = "libraryScopeFolderID"

    private(set) var folders: [MusicFolder] = []

    /// Bumped on every change so views can key `.task(id:)` on it and reload.
    private(set) var generation = 0

    var scope: LibraryScope = .all {
        didSet {
            guard scope != oldValue else { return }
            generation += 1
            // Written by hand rather than with @AppStorage: that is a
            // DynamicProperty and only works inside a View.
            UserDefaults.standard.set(scope.folderID ?? 0, forKey: Self.defaultsKey)
        }
    }

    /// Adopts the server's folder list, then restores the saved selection. A saved
    /// id that no longer exists on the server falls back to `.all` rather than
    /// silently filtering everything out.
    func adopt(folders: [MusicFolder]) {
        self.folders = folders

        let savedID = UserDefaults.standard.integer(forKey: Self.defaultsKey)
        if savedID != 0, let match = folders.first(where: { $0.id == savedID }) {
            scope = .folder(id: match.id, name: match.name)
        } else {
            scope = .all
        }
    }

    /// A single-library server needs no control at all.
    var isSwitchable: Bool { folders.count > 1 }

    var options: [LibraryScope] {
        [.all] + folders.map { .folder(id: $0.id, name: $0.name) }
    }
}
