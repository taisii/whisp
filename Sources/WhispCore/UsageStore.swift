import Foundation

private struct UsageData: Codable, Sendable {
    var days: [DailyUsage]

    init(days: [DailyUsage] = []) {
        self.days = days
    }
}

public final class UsageStore {
    public let path: URL
    private var data: UsageData
    private let calendar: Calendar
    private let now: () -> Date

    public init(
        path: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        calendar: Calendar = Calendar.current,
        now: @escaping () -> Date = Date.init
    ) throws {
        if let path {
            self.path = path
        } else {
            self.path = try WhispPaths(environment: environment).usageFile
        }

        self.calendar = calendar
        self.now = now

        if FileManager.default.fileExists(atPath: self.path.path) {
            let file = try Data(contentsOf: self.path)
            self.data = (try? JSONDecoder().decode(UsageData.self, from: file)) ?? UsageData()
        } else {
            self.data = UsageData()
        }
    }

    public func recordUsage(stt: STTUsage?, llm: LLMUsage?) {
        let today = dayString(now())
        if let index = data.days.firstIndex(where: { $0.date == today }) {
            var day = data.days[index]
            applyUsage(day: &day, stt: stt, llm: llm)
            data.days[index] = day
        } else {
            var day = DailyUsage(date: today)
            applyUsage(day: &day, stt: stt, llm: llm)
            data.days.append(day)
        }
        try? save()
    }

    public func today() -> DailyUsage {
        let today = dayString(now())
        return data.days.first(where: { $0.date == today }) ?? DailyUsage(date: today)
    }

    public func month(year: Int, month: Int) -> DailyUsage {
        var total = DailyUsage(date: String(format: "%04d-%02d", year, month))
        for day in data.days {
            guard let date = parseDay(day.date) else { continue }
            let components = calendar.dateComponents([.year, .month], from: date)
            if components.year == year && components.month == month {
                merge(into: &total, from: day)
            }
        }
        return total
    }

    public func currentMonth() -> DailyUsage {
        let components = calendar.dateComponents([.year, .month], from: now())
        return month(year: components.year ?? 1970, month: components.month ?? 1)
    }

    private func applyUsage(day: inout DailyUsage, stt: STTUsage?, llm: LLMUsage?) {
        if let stt {
            let provider = normalizedProvider(stt.provider)
            var current = day.stt[provider] ?? STTProviderUsage()
            current.durationSeconds += stt.durationSeconds
            current.requests += 1
            day.stt[provider] = current
        }
        if let llm {
            let provider = normalizedProvider(llm.provider)
            var current = day.llm[provider] ?? LLMProviderUsage()
            current.promptTokens += llm.promptTokens
            current.completionTokens += llm.completionTokens
            current.requests += 1
            day.llm[provider] = current
        }
    }

    private func merge(into total: inout DailyUsage, from day: DailyUsage) {
        for (provider, usage) in day.stt {
            var current = total.stt[provider] ?? STTProviderUsage()
            current.durationSeconds += usage.durationSeconds
            current.requests += usage.requests
            total.stt[provider] = current
        }
        for (provider, usage) in day.llm {
            var current = total.llm[provider] ?? LLMProviderUsage()
            current.promptTokens += usage.promptTokens
            current.completionTokens += usage.completionTokens
            current.requests += usage.requests
            total.llm[provider] = current
        }
    }

    private func normalizedProvider(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private func save() throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(data)
        try encoded.write(to: path)
    }

    private func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
