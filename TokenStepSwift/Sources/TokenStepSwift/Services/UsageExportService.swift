import Foundation

enum UsageExportService {
    static let jsonFileName = "aiquota-export.json"
    static let snapshotCSVFileName = "aiquota-snapshot.csv"
    static let dailyCSVFileName = "aiquota-daily.csv"
    static let signatureFileName = ".aiquota-export.sig"

    struct ExportDocument: Codable, Equatable {
        var generatedAt: String
        var app: AppInfo
        var snapshot: PeriodSnapshot
        var daily: [DailyRow]

        enum CodingKeys: String, CodingKey {
            case generatedAt
            case app
            case snapshot
            case daily
        }

        struct AppInfo: Codable, Equatable {
            var name: String
            var version: String
        }

        struct PeriodSnapshot: Codable, Equatable {
            var today: PeriodTotals
            var month: PeriodTotals
            var allTime: PeriodTotals
        }

        struct PeriodTotals: Codable, Equatable {
            var tokens: Int
            var costUsd: Double
            var tools: [String: Int]
            var models: [String: Int]

            enum CodingKeys: String, CodingKey {
                case tokens
                case costUsd = "cost_usd"
                case tools
                case models
            }
        }

        struct DailyRow: Codable, Equatable {
            var date: String
            var tokens: Int
            var costUsd: Double
            var perClient: [String: Int]
            var perModel: [String: Int]

            enum CodingKeys: String, CodingKey {
                case date
                case tokens
                case costUsd = "cost_usd"
                case perClient
                case perModel
            }
        }
    }

    @discardableResult
    static func export(snapshot: UsageSnapshot, to directory: URL, now: Date = Date()) throws -> [URL] {
        let folder = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UsageExportError.folderMissing
        }

        let document = makeDocument(from: snapshot, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(document)
        let snapshotCSV = snapshotCSV(from: document)
        let dailyCSV = dailyCSV(from: document)

        let jsonURL = folder.appendingPathComponent(jsonFileName)
        let snapshotURL = folder.appendingPathComponent(snapshotCSVFileName)
        let dailyURL = folder.appendingPathComponent(dailyCSVFileName)
        try jsonData.write(to: jsonURL, options: .atomic)
        try snapshotCSV.write(to: snapshotURL, atomically: true, encoding: .utf8)
        try dailyCSV.write(to: dailyURL, atomically: true, encoding: .utf8)
        try saveSignature(fingerprint(document), at: folder.appendingPathComponent(signatureFileName))
        return [jsonURL, snapshotURL, dailyURL]
    }

    @discardableResult
    static func autoExportIfEnabled(
        snapshot: UsageSnapshot,
        settings: TokenStepSettings,
        now: Date = Date()
    ) throws -> [URL]? {
        guard settings.usageExportAutoEnabled else { return nil }
        let trimmed = settings.usageExportFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: trimmed, isDirectory: true)
        let document = makeDocument(from: snapshot, now: now)
        let next = fingerprint(document)
        if next == loadSignature(at: directory.appendingPathComponent(signatureFileName)) {
            return nil
        }
        return try export(snapshot: snapshot, to: directory, now: now)
    }

    static func makeDocument(from snapshot: UsageSnapshot, now: Date = Date()) -> ExportDocument {
        let todayKey = UsageDayDate.formatter.string(from: now)
        let monthPrefix = String(todayKey.prefix(7))
        let todayDays = snapshot.daily.filter { $0.date == todayKey }
        let monthDays = snapshot.daily.filter { $0.date.hasPrefix(monthPrefix) }
        return ExportDocument(
            generatedAt: ISO8601DateFormatter.exportTimestamp.string(from: now),
            app: .init(name: "AIQuota", version: appVersion),
            snapshot: .init(
                today: totals(from: todayDays),
                month: totals(from: monthDays),
                allTime: totals(from: snapshot.daily)
            ),
            daily: snapshot.daily
                .filter { $0.totalTokens > 0 }
                .sorted { $0.date < $1.date }
                .map { day in
                    ExportDocument.DailyRow(
                        date: day.date,
                        tokens: day.totalTokens,
                        costUsd: rounded(day.displayCost),
                        perClient: day.tools.filter { $0.value > 0 },
                        perModel: day.models.filter { $0.value > 0 }
                    )
                }
        )
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func fingerprint(_ document: ExportDocument) -> String {
        let parts = document.daily.map { day in
            let tools = day.perClient.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            return "\(day.date)=\(day.tokens);\(tools)"
        }
        return parts.joined(separator: "|")
    }

    private static func totals(from days: [DailyUsage]) -> ExportDocument.PeriodTotals {
        var tools: [String: Int] = [:]
        var models: [String: Int] = [:]
        var tokens = 0
        var cost = 0.0
        for day in days {
            tokens += day.totalTokens
            cost += day.displayCost
            for (tool, value) in day.tools {
                tools[tool, default: 0] += value
            }
            for (model, value) in day.models {
                models[model, default: 0] += value
            }
        }
        return ExportDocument.PeriodTotals(
            tokens: tokens,
            costUsd: rounded(cost),
            tools: tools.filter { $0.value > 0 },
            models: models.filter { $0.value > 0 }
        )
    }

    private static func snapshotCSV(from document: ExportDocument) -> String {
        var rows = ["period,dimension,name,tokens,cost_usd"]
        func append(period: String, totals: ExportDocument.PeriodTotals) {
            for (name, tokens) in totals.tools.sorted(by: { $0.key < $1.key }) {
                rows.append([period, "tool", csv(name), String(tokens), csvNumber(0)].joined(separator: ","))
            }
            for (name, tokens) in totals.models.sorted(by: { $0.key < $1.key }) {
                rows.append([period, "model", csv(name), String(tokens), csvNumber(0)].joined(separator: ","))
            }
            if totals.tools.isEmpty && totals.models.isEmpty && totals.tokens > 0 {
                rows.append([period, "total", "all", String(totals.tokens), csvNumber(totals.costUsd)].joined(separator: ","))
            } else if totals.tokens > 0 {
                rows.append([period, "total", "all", String(totals.tokens), csvNumber(totals.costUsd)].joined(separator: ","))
            }
        }
        append(period: "today", totals: document.snapshot.today)
        append(period: "month", totals: document.snapshot.month)
        append(period: "allTime", totals: document.snapshot.allTime)
        return csvFile(rows)
    }

    private static func dailyCSV(from document: ExportDocument) -> String {
        var rows = ["date,tool,tokens,cost_usd"]
        for day in document.daily {
            if day.perClient.isEmpty {
                rows.append([day.date, "unknown", String(day.tokens), csvNumber(day.costUsd)].joined(separator: ","))
                continue
            }
            let toolCount = max(1, day.perClient.count)
            for (tool, tokens) in day.perClient.sorted(by: { $0.key < $1.key }) {
                let share = day.tokens > 0 ? (day.costUsd * Double(tokens) / Double(day.tokens)) : 0
                let cost = toolCount == 1 ? day.costUsd : share
                rows.append([day.date, csv(tool), String(tokens), csvNumber(cost)].joined(separator: ","))
            }
        }
        return csvFile(rows)
    }

    private static func csvFile(_ rows: [String]) -> String {
        "\u{FEFF}" + rows.joined(separator: "\n") + "\n"
    }

    private static func csv(_ value: String) -> String {
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func csvNumber(_ value: Double) -> String {
        String(format: "%.4f", rounded(value))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func saveSignature(_ value: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    private static func loadSignature(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum UsageExportError: LocalizedError {
    case folderMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .folderMissing:
            return L("尚未选择文件夹")
        case .cancelled:
            return nil
        }
    }
}

private extension ISO8601DateFormatter {
    static let exportTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
