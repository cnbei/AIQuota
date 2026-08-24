import Foundation

struct AntigravityUsageTurn: Equatable {
    var model: String
    var inputTokens: Int
    var cacheReadTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var responseID: String?
    var timestampEpoch: TimeInterval?

    var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }
}

enum AntigravityUsageParser {
    static func data(fromHex hex: String) -> Data? {
        let scalars = hex.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty, scalars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(scalars.count / 2)
        var iterator = scalars.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let highValue = hexValue(high), let lowValue = hexValue(low) else {
                return nil
            }
            bytes.append((highValue << 4) | lowValue)
        }
        return Data(bytes)
    }

    static func sessionCreatedEpoch(fromTrajectoryBlob data: Data) -> TimeInterval? {
        protoTimestampEpoch(messageField(data, 2))
    }

    static func turns(
        fromGenMetadataBlobs blobs: [Data],
        sessionCreatedEpoch: TimeInterval? = nil
    ) -> [AntigravityUsageTurn] {
        let sessionModels = SessionModels(blobs: blobs)
        var seen = Set<String>()
        return blobs.compactMap { blob in
            turn(
                from: blob,
                sessionCreatedEpoch: sessionCreatedEpoch,
                sessionModels: sessionModels,
                seenResponseIDs: &seen
            )
        }
    }

    private static func turn(
        from blob: Data,
        sessionCreatedEpoch: TimeInterval?,
        sessionModels: SessionModels,
        seenResponseIDs: inout Set<String>
    ) -> AntigravityUsageTurn? {
        guard let chatModel = messageField(blob, 1),
              let usage = messageField(chatModel, 4)
        else {
            return nil
        }

        let systemTokens = clampedInt(varintField(usage, 1))
        let newInputTokens = clampedInt(varintField(usage, 2))
        let cacheReadTokens = clampedInt(varintField(usage, 5))
        let textTokens = clampedInt(varintField(usage, 9))
        let reasoningTokens = clampedInt(varintField(usage, 10))
        let inputTokens = saturatingAdd(systemTokens, newInputTokens)
        let outputTokens = saturatingAdd(textTokens, reasoningTokens)
        guard inputTokens > 0 || cacheReadTokens > 0 || outputTokens > 0 else {
            return nil
        }

        if let responseID = nonEmptyStringField(usage, 11),
           !seenResponseIDs.insert(responseID).inserted {
            return nil
        }

        let timestamp = protoTimestampEpoch(messageField(messageField(chatModel, 9), 4))
            ?? sessionCreatedEpoch

        return AntigravityUsageTurn(
            model: resolvedModel(chatModel: chatModel, sessionModels: sessionModels),
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            responseID: nonEmptyStringField(usage, 11),
            timestampEpoch: timestamp
        )
    }

    private static func resolvedModel(chatModel: Data, sessionModels: SessionModels) -> String {
        let responseModel = nonEmptyStringField(chatModel, 19)
        if let responseModel, !isRoutingLabel(responseModel) {
            return responseModel
        }
        if let recovered = sessionModels.recover(chatModel: chatModel) {
            return recovered
        }
        if let label = nonEmptyStringField(chatModel, 21),
           let mapped = modelID(fromDisplayLabel: label) {
            return mapped
        }
        return responseModel ?? "unknown"
    }

    private static func isRoutingLabel(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("gemini-default") == .orderedSame
    }

    private static func modelID(fromDisplayLabel label: String) -> String? {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Gemini 3.5 Flash (Low)":
            return "gemini-3.5-flash-extra-low"
        case "Gemini 3.5 Flash (Medium)":
            return "gemini-3.5-flash-medium"
        case "Gemini 3.5 Flash (High)":
            return "gemini-3.5-flash-high"
        default:
            return nil
        }
    }

    private static func protoTimestampEpoch(_ data: Data?) -> TimeInterval? {
        guard let data,
              let seconds = varintField(data, 1).flatMap({ TimeInterval(exactly: $0) }),
              seconds > 0
        else {
            return nil
        }
        let nanos = varintField(data, 2).map { TimeInterval($0) } ?? 0
        guard (0...999_999_999).contains(nanos) else { return nil }
        return seconds + nanos / 1_000_000_000
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9":
            return UInt8(scalar.value - Unicode.Scalar("0").value)
        case "a"..."f":
            return UInt8(scalar.value - Unicode.Scalar("a").value + 10)
        case "A"..."F":
            return UInt8(scalar.value - Unicode.Scalar("A").value + 10)
        default:
            return nil
        }
    }

    private static func clampedInt(_ value: UInt64?) -> Int {
        guard let value else { return 0 }
        return Int(clamping: value)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }
}

private struct SessionModels {
    var byDisplay: [String: String]
    var soleModel: String?

    init(blobs: [Data]) {
        var byDisplay: [String: String?] = [:]
        var distinct = Set<String>()
        var unresolvedLabels: [String] = []

        for blob in blobs {
            guard let chatModel = messageField(blob, 1) else { continue }
            let label = nonEmptyStringField(chatModel, 21)
            guard let model = nonEmptyStringField(chatModel, 19),
                  model.caseInsensitiveCompare("gemini-default") != .orderedSame
            else {
                if let label { unresolvedLabels.append(label) }
                continue
            }
            distinct.insert(model)
            guard let label else { continue }
            if let existing = byDisplay[label] ?? nil, existing != model {
                byDisplay[label] = nil
            } else if byDisplay[label] == nil {
                byDisplay[label] = model
            }
        }

        self.byDisplay = byDisplay.compactMapValues { $0 }
        let everyLabelIdentified = unresolvedLabels.allSatisfy { self.byDisplay[$0] != nil }
        soleModel = distinct.count == 1 && everyLabelIdentified ? distinct.first : nil
    }

    func recover(chatModel: Data) -> String? {
        if let label = nonEmptyStringField(chatModel, 21) {
            return byDisplay[label]
        }
        return soleModel
    }
}

private enum ProtoWire {
    case varint(UInt64)
    case length(Data)
    case skipped
}

private struct ProtoReader {
    let bytes: [UInt8]
    var offset = 0

    init(buffer: Data) {
        bytes = Array(buffer)
    }

    mutating func nextField() -> (UInt64, ProtoWire)? {
        guard offset < bytes.count, let tag = readVarint() else { return nil }
        let field = tag >> 3
        switch tag & 0x7 {
        case 0:
            guard let value = readVarint() else { return nil }
            return (field, .varint(value))
        case 1:
            guard skip(8) else { return nil }
            return (field, .skipped)
        case 2:
            guard let length = readVarint(),
                  let end = checkedEnd(length),
                  end <= bytes.count
            else {
                return nil
            }
            let payload = Data(bytes[offset..<end])
            offset = end
            return (field, .length(payload))
        case 5:
            guard skip(4) else { return nil }
            return (field, .skipped)
        default:
            return nil
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                return nil
            }
        }
        return nil
    }

    private mutating func skip(_ count: Int) -> Bool {
        guard let end = checkedEnd(UInt64(count)), end <= bytes.count else { return false }
        offset = end
        return true
    }

    private func checkedEnd(_ length: UInt64) -> Int? {
        let added = Int(clamping: length)
        let (end, overflow) = offset.addingReportingOverflow(added)
        return overflow ? nil : end
    }
}

private func messageField(_ data: Data?, _ field: UInt64) -> Data? {
    guard let data else { return nil }
    var reader = ProtoReader(buffer: data)
    while let (found, wire) = reader.nextField() {
        if found == field, case .length(let payload) = wire {
            return payload
        }
    }
    return nil
}

private func varintField(_ data: Data, _ field: UInt64) -> UInt64? {
    var reader = ProtoReader(buffer: data)
    while let (found, wire) = reader.nextField() {
        if found == field, case .varint(let value) = wire {
            return value
        }
    }
    return nil
}

private func nonEmptyStringField(_ data: Data, _ field: UInt64) -> String? {
    guard let payload = messageField(data, field),
          let text = String(data: payload, encoding: .utf8)
    else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
