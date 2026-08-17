import Foundation

/// A rolling log of things that went wrong, readable on the device.
///
/// This exists because of how this app is developed: there is no Mac, no simulator and
/// no debugger attached, so when something fails the only evidence is whatever the phone
/// can show for itself. Without this, "it didn't work" is unanswerable without plugging
/// in over USB and pulling crash reports — and a crash report says nothing about a
/// request that merely returned an error.
///
/// Deliberately small: failures only, capped, and never any credentials. The whole point
/// is that it can be read out loud without leaking the server password.
actor Diagnostics {
    static let shared = Diagnostics()

    struct Line: Codable, Sendable, Identifiable {
        var id = UUID()
        var at: Date
        var area: String
        var message: String
    }

    /// Enough to cover a session's worth of failures, small enough to read.
    private let limit = 200
    private var lines: [Line] = []
    private let url = Paths.root.appendingPathComponent("diagnostics.json")
    private var didLoad = false

    func record(_ area: String, _ message: String) {
        load()
        lines.insert(Line(at: .now, area: area, message: Self.redact(message)), at: 0)
        lines = Array(lines.prefix(limit))
        save()
    }

    func recent() -> [Line] {
        load()
        return lines
    }

    func clear() {
        lines = []
        try? FileManager.default.removeItem(at: url)
    }

    /// Plain text, for sharing or reading aloud.
    func export() -> String {
        load()
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return lines.reversed().map { line in
            "\(formatter.string(from: line.at))  [\(line.area)]  \(line.message)"
        }.joined(separator: "\n")
    }

    /// Strips the query string from any URL in a message. Subsonic puts the username and
    /// an auth token in every request, so an unredacted URL in a shareable log would hand
    /// them out.
    static func redact(_ message: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\?[^\\s]*") else { return message }
        return regex.stringByReplacingMatches(
            in: message,
            range: NSRange(message.startIndex..., in: message),
            withTemplate: "?…"
        )
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Line].self, from: data)
        else { return }
        lines = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
