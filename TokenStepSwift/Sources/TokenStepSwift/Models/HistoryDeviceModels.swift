import Foundation

enum HistoryDeviceFilter: Equatable, Hashable {
    case all
    case machine(String)

    var machineId: String? {
        if case let .machine(id) = self { return id }
        return nil
    }
}

struct SyncedMachineLedger: Equatable, Identifiable {
    var machineId: String
    var machineName: String
    var fileSlug: String
    var isLocal: Bool
    var daily: [DailyUsage]

    var id: String { machineId }

    init(
        machineId: String,
        machineName: String,
        fileSlug: String,
        isLocal: Bool,
        daily: [DailyUsage]
    ) {
        self.machineId = machineId
        self.machineName = machineName
        self.fileSlug = fileSlug
        self.isLocal = isLocal
        self.daily = daily
    }

    init(remote file: UsageSyncService.MachineUsageFile, fileSlug: String? = nil) {
        machineId = file.machineId
        machineName = file.machineName
        self.fileSlug = file.fileSlug ?? fileSlug ?? HistoryDevicePresentation.slug(from: file.machineId)
        isLocal = false
        daily = file.daily
    }
}

struct DailyDeviceBar: Equatable, Identifiable {
    var date: String
    var totalTokens: Int
    var cost: Double
    var slices: [DeviceBarSlice]

    var id: String { date }
}

struct DeviceBarSlice: Equatable, Identifiable {
    var machineId: String
    var machineName: String
    var isLocal: Bool
    var tokens: Int

    var id: String { machineId }
}

struct DeviceUsageStat: Equatable, Identifiable {
    var machineId: String
    var machineName: String
    var isLocal: Bool
    var tokens: Int
    var cost: Double
    var percent: Double

    var id: String { machineId }
}

enum HistoryDevicePresentation {
    static func selectedMachines(
        _ machines: [SyncedMachineLedger],
        filter: HistoryDeviceFilter
    ) -> [SyncedMachineLedger] {
        switch filter {
        case .all:
            return machines
        case let .machine(id):
            return machines.filter { $0.machineId == id }
        }
    }

    static func displayTitle(for machine: SyncedMachineLedger, among machines: [SyncedMachineLedger]) -> String {
        let duplicateName = machines.filter { $0.machineName == machine.machineName }.count > 1
        let base: String
        if machine.isLocal {
            base = LFormat("%@（本机）", machine.machineName)
        } else {
            base = machine.machineName
        }
        guard duplicateName else { return base }
        let suffix = String(machine.fileSlug.suffix(4))
        return "\(base) · \(suffix)"
    }

    static func filteredDaily(
        machines: [SyncedMachineLedger],
        filter: HistoryDeviceFilter
    ) -> [DailyUsage] {
        mergedDaily(from: selectedMachines(machines, filter: filter))
    }

    static func mergedDaily(from machines: [SyncedMachineLedger]) -> [DailyUsage] {
        var merged: [String: DailyUsage] = [:]
        for machine in machines {
            for day in machine.daily {
                merged[day.date] = mergedDay(merged[day.date], day)
            }
        }
        return merged.values.sorted { $0.date < $1.date }
    }

    static func totals(from daily: [DailyUsage]) -> UsageTotals {
        let active = daily.filter { $0.totalTokens > 0 }
        return UsageTotals(
            tokens: active.map(\.totalTokens).reduce(0, +),
            cost: active.map(\.displayCost).reduce(0, +),
            activeDays: active.count
        )
    }

    static func toolUsages(from daily: [DailyUsage]) -> [ToolUsage] {
        var map: [String: Int] = [:]
        for day in daily {
            for (tool, tokens) in day.tools where tokens > 0 {
                map[tool, default: 0] += tokens
            }
        }
        let total = max(map.values.reduce(0, +), 1)
        return map
            .map { ToolUsage(tool: $0.key, tokens: $0.value, percent: Double($0.value) / Double(total) * 100) }
            .sorted { $0.tokens > $1.tokens }
    }

    static func modelUsages(from daily: [DailyUsage]) -> [ModelUsage] {
        var map: [String: Int] = [:]
        for day in daily {
            for (model, tokens) in day.models where tokens > 0 {
                map[model, default: 0] += tokens
            }
        }
        let total = max(map.values.reduce(0, +), 1)
        return map
            .map { ModelUsage(model: $0.key, tokens: $0.value, percent: Double($0.value) / Double(total) * 100) }
            .sorted { $0.tokens > $1.tokens }
    }

    static func deviceStats(from machines: [SyncedMachineLedger]) -> [DeviceUsageStat] {
        let tokenTotals = machines.map { machine in
            machine.daily.filter { $0.totalTokens > 0 }.map(\.totalTokens).reduce(0, +)
        }
        let costTotals = machines.map { machine in
            machine.daily.filter { $0.totalTokens > 0 }.map(\.displayCost).reduce(0, +)
        }
        let grand = max(tokenTotals.reduce(0, +), 1)
        return zip(machines, zip(tokenTotals, costTotals)).map { machine, pair in
            DeviceUsageStat(
                machineId: machine.machineId,
                machineName: machine.machineName,
                isLocal: machine.isLocal,
                tokens: pair.0,
                cost: pair.1,
                percent: Double(pair.0) / Double(grand) * 100
            )
        }
        .filter { $0.tokens > 0 }
        .sorted { $0.tokens > $1.tokens }
    }

    static func deviceBars(
        machines: [SyncedMachineLedger],
        filter: HistoryDeviceFilter,
        lastDays: Int = 30,
        now: Date = Date()
    ) -> [DailyDeviceBar] {
        let selected = selectedMachines(machines, filter: filter)
        let lookup: [String: [String: DailyUsage]] = Dictionary(uniqueKeysWithValues: selected.map { machine in
            (machine.machineId, Dictionary(uniqueKeysWithValues: machine.daily.map { ($0.date, $0) }))
        })
        return shanghaiDayKeys(lastDays: lastDays, now: now).map { date in
            let slices = selected.compactMap { machine -> DeviceBarSlice? in
                let tokens = lookup[machine.machineId]?[date]?.totalTokens ?? 0
                guard tokens > 0 else { return nil }
                return DeviceBarSlice(
                    machineId: machine.machineId,
                    machineName: machine.machineName,
                    isLocal: machine.isLocal,
                    tokens: tokens
                )
            }
            let cost = selected.reduce(0.0) { $0 + (lookup[$1.machineId]?[date]?.displayCost ?? 0) }
            return DailyDeviceBar(
                date: date,
                totalTokens: slices.map(\.tokens).reduce(0, +),
                cost: cost,
                slices: slices
            )
        }
    }

    static func colorIndex(for machineId: String, isLocal: Bool, paletteCount: Int = 5) -> Int {
        if isLocal { return -1 }
        let count = max(paletteCount, 1)
        var hash = 5381
        for scalar in machineId.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return abs(hash) % count
    }

    static func slug(from machineId: String) -> String {
        let fallback = machineId
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return fallback.isEmpty ? "machine" : fallback
    }

    static func shanghaiDayKeys(lastDays: Int, now: Date = Date()) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = calendar.startOfDay(for: now)
        let days = max(1, lastDays)
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start) else { return nil }
            return DateFormatter.tokenStepDay.string(from: date)
        }
    }

    private static func mergedDay(_ existing: DailyUsage?, _ incoming: DailyUsage) -> DailyUsage {
        guard var result = existing else { return incoming }
        result.totalTokens += incoming.totalTokens
        result.cost += incoming.cost
        result.equivalentCost += incoming.equivalentCost
        for (tool, tokens) in incoming.tools {
            result.tools[tool, default: 0] += tokens
        }
        for (model, tokens) in incoming.models {
            result.models[model, default: 0] += tokens
        }
        for (tool, models) in incoming.modelsByTool {
            for (model, tokens) in models {
                result.modelsByTool[tool, default: [:]][model, default: 0] += tokens
            }
        }
        for (model, cost) in incoming.modelCosts {
            result.modelCosts[model, default: 0] += cost
        }
        for (tool, cost) in incoming.toolCosts {
            result.toolCosts[tool, default: 0] += cost
        }
        return result
    }
}
