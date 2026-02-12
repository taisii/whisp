import SwiftUI
import WhispCore

struct BenchmarkIntegrityView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            List(selection: Binding(get: {
                viewModel.selectedIntegrityIssueID
            }, set: { newValue in
                viewModel.selectIntegrityIssue(newValue)
            })) {
                header
                ForEach(viewModel.integrityIssues) { issue in
                    issueRow(issue)
                        .tag(issue.id)
                }
            }
            .listStyle(.plain)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Task", selection: $viewModel.selectedTask) {
                Text("STT").tag(BenchmarkKind.stt)
                Text("Generation").tag(BenchmarkKind.generation)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            TextField("Dataset path", text: $viewModel.datasetPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            Button {
                viewModel.scanIntegrity()
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExecutingBenchmark)

            Button("Open dataset file") {
                viewModel.openDatasetFile()
            }
            .buttonStyle(.bordered)

            Button("Copy case_id") {
                viewModel.copySelectedIssueCaseID()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.selectedIntegrityIssue == nil)

            Button("Open related run dir") {
                viewModel.openRelatedRunDirectory()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.selectedIntegrityIssue == nil)

            Button(viewModel.selectedIntegrityIssue?.excluded == true ? "Unexclude" : "Exclude") {
                if let issue = viewModel.selectedIntegrityIssue {
                    viewModel.setIssueExcluded(issue, excluded: !issue.excluded)
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.selectedIntegrityIssue == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            headerText("case_id", width: 190)
            headerText("task", width: 110)
            headerText("issue_type", width: 180)
            headerText("missing_fields", width: 280)
            headerText("source_path", width: 380)
            headerText("excluded", width: 90)
            headerText("updated_at", width: 220)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func issueRow(_ issue: BenchmarkIntegrityIssue) -> some View {
        HStack(spacing: 10) {
            cellText(issue.caseID, width: 190)
            cellText(issue.task.rawValue, width: 110)
            cellText(issue.issueType, width: 180)
            cellText(issue.missingFields.joined(separator: ", "), width: 280)
            cellText(issue.sourcePath, width: 380)
            cellText(issue.excluded ? "yes" : "no", width: 90, color: issue.excluded ? .orange : .secondary)
            cellText(issue.detectedAt, width: 220)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func headerText(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
    }

    private func cellText(_ text: String, width: CGFloat, color: Color = .primary) -> some View {
        Text(text)
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
