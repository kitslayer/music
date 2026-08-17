import SwiftUI

/// Stub until M5, so the Library hub row is never a dead link.
struct DownloadsView: View {
    var body: some View {
        ContentUnavailableView(
            "No Downloads",
            systemImage: "arrow.down.circle",
            description: Text("Downloaded music plays without a server connection.")
        )
        .navigationTitle("Downloads")
    }
}
