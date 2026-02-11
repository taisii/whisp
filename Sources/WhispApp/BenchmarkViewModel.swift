import Foundation
import WhispCore

struct BenchmarkArtifactPanel: Identifiable, Equatable {
    let id: String
    let title: String
    let text: String
    let isError: Bool
}

@MainActor
final class BenchmarkViewModel: ObservableObject {
    @Published var runs: [BenchmarkRunRecord] = []
    @Published var selectedRunID: String?
    @Published var cases: [BenchmarkCaseResult] = []
    @Published var selectedCaseID: String?
    @Published var events: [BenchmarkCaseEvent] = []
    @Published var selectedEventIndex: Int = 0
    @Published var artifactPanels: [BenchmarkArtifactPanel] = []
    @Published var statusMessage = ""
    @Published var statusIsError = false

    private let store: BenchmarkStore

    init(store: BenchmarkStore) {
        self.store = store
    }

    var selectedRun: BenchmarkRunRecord? {
        guard let selectedRunID else { return nil }
        return runs.first { $0.id == selectedRunID }
    }

    var selectedCase: BenchmarkCaseResult? {
        guard let selectedCaseID else { return nil }
        return cases.first { $0.id == selectedCaseID }
    }

    var selectedEvent: BenchmarkCaseEvent? {
        guard events.indices.contains(selectedEventIndex) else { return nil }
        return events[selectedEventIndex]
    }

    func refresh() {
        do {
            runs = try store.listRuns(limit: 200)
            if let selectedRunID,
               runs.contains(where: { $0.id == selectedRunID })
            {
                try loadRunDetails(runID: selectedRunID, keepSelectedCase: true)
                setStatus("ベンチマーク一覧を更新しました。", isError: false)
                return
            }

            if let first = runs.first {
                selectedRunID = first.id
                try loadRunDetails(runID: first.id, keepSelectedCase: false)
            } else {
                selectedRunID = nil
                cases = []
                selectedCaseID = nil
                events = []
                selectedEventIndex = 0
                artifactPanels = []
            }
            setStatus("ベンチマーク一覧を更新しました。", isError: false)
        } catch {
            setStatus("読み込みに失敗: \(error.localizedDescription)", isError: true)
        }
    }

    func selectRun(runID: String?) {
        selectedRunID = runID
        guard let runID else {
            cases = []
            selectedCaseID = nil
            events = []
            selectedEventIndex = 0
            artifactPanels = []
            return
        }

        do {
            try loadRunDetails(runID: runID, keepSelectedCase: false)
        } catch {
            setStatus("Run読み込みに失敗: \(error.localizedDescription)", isError: true)
        }
    }

    func selectCase(caseID: String?) {
        selectedCaseID = caseID
        guard let runID = selectedRunID else {
            events = []
            selectedEventIndex = 0
            artifactPanels = []
            return
        }
        do {
            events = try store.loadEvents(runID: runID, caseID: caseID)
                .sorted { $0.base.startedAtMs < $1.base.startedAtMs }
            selectedEventIndex = 0
            reloadArtifactPanels()
        } catch {
            setStatus("Case詳細読み込みに失敗: \(error.localizedDescription)", isError: true)
        }
    }

    func selectEvent(index: Int) {
        selectedEventIndex = index
        reloadArtifactPanels()
    }

    private func loadRunDetails(runID: String, keepSelectedCase: Bool) throws {
        cases = try store.loadCaseResults(runID: runID)
        if keepSelectedCase,
           let selectedCaseID,
           cases.contains(where: { $0.id == selectedCaseID })
        {
            try loadCaseEvents(runID: runID, caseID: selectedCaseID)
            return
        }

        if let first = cases.first {
            selectedCaseID = first.id
            try loadCaseEvents(runID: runID, caseID: first.id)
        } else {
            selectedCaseID = nil
            events = []
            selectedEventIndex = 0
            artifactPanels = []
        }
    }

    private func loadCaseEvents(runID: String, caseID: String?) throws {
        events = try store.loadEvents(runID: runID, caseID: caseID)
            .sorted { $0.base.startedAtMs < $1.base.startedAtMs }
        selectedEventIndex = 0
        reloadArtifactPanels()
    }

    private func reloadArtifactPanels() {
        guard let runID = selectedRunID,
              let event = selectedEvent
        else {
            artifactPanels = []
            return
        }

        let refs = artifactRefs(for: event)
        artifactPanels = refs.map { title, ref in
            do {
                let text = try store.loadArtifactText(runID: runID, ref: ref)
                return BenchmarkArtifactPanel(
                    id: "\(title)-\(ref.relativePath)",
                    title: "\(title) (\(ref.relativePath))",
                    text: text,
                    isError: false
                )
            } catch {
                return BenchmarkArtifactPanel(
                    id: "\(title)-\(ref.relativePath)-error",
                    title: "\(title) (\(ref.relativePath))",
                    text: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    private func artifactRefs(for event: BenchmarkCaseEvent) -> [(String, BenchmarkArtifactRef)] {
        switch event {
        case let .loadCase(log):
            return log.rawRowRef.map { [("raw_row", $0)] } ?? []
        case let .stt(log):
            return log.rawResponseRef.map { [("stt_raw_response", $0)] } ?? []
        case let .context(log):
            return log.rawContextRef.map { [("context_raw", $0)] } ?? []
        case let .generation(log):
            var values: [(String, BenchmarkArtifactRef)] = []
            if let ref = log.promptRef {
                values.append(("generation_prompt", ref))
            }
            if let ref = log.responseRef {
                values.append(("generation_response", ref))
            }
            return values
        case let .judge(log):
            var values: [(String, BenchmarkArtifactRef)] = []
            if let ref = log.requestRef {
                values.append(("judge_request", ref))
            }
            if let ref = log.responseRef {
                values.append(("judge_response", ref))
            }
            return values
        case let .cache(log):
            return log.keyMaterialRef.map { [("cache_key_material", $0)] } ?? []
        case .aggregate, .error, .artifactWriteFailed:
            return []
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
