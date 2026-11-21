import Foundation

struct HistoryPoint: Codable {
    let t: Date
    /// Session percent used.
    let s: Double?
    /// Weekly percent used.
    let w: Double?
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }
}

/// Keeps 31 days of readings in ~/Library/Application Support/Leeway/history.json.
final class HistoryStore {
    private(set) var points: [HistoryPoint] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let folder = base.appendingPathComponent("Leeway", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("history.json")
        load()
    }

    func add(session: Double?, weekly: Double?, at date: Date = Date()) {
        if let last = points.last, last.s == session, last.w == weekly, date.timeIntervalSince(last.t) < 15 * 60 {
            return
        }
        points.append(HistoryPoint(t: date, s: session, w: weekly))
        let cutoff = date.addingTimeInterval(-31 * 86400)
        if let first = points.first, first.t < cutoff {
            points.removeAll { $0.t < cutoff }
        }
        save()
    }

    func samples(in range: HistoryRange, now: Date = Date()) -> [HistoryPoint] {
        let start = now.addingTimeInterval(-range.seconds)
        return points.filter { $0.t >= start }
    }

    func clear() {
        points = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        points = (try? decoder.decode([HistoryPoint].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(points) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
