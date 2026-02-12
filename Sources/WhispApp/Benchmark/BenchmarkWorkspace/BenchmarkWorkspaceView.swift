import SwiftUI
import WhispCore

struct BenchmarkWorkspaceView: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    var autoRefreshOnAppear = true

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                tabSelector
                Divider()

                Group {
                    switch viewModel.selectedTab {
                    case .stt:
                        STTBenchmarkView(viewModel: viewModel)
                    case .generationSingle:
                        GenerationSingleBenchmarkView(viewModel: viewModel)
                    case .generationBattle:
                        GenerationBattleBenchmarkView(viewModel: viewModel)
                    case .integrity:
                        IntegrityBenchmarkView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(viewModel.selectedTab)

                Divider()
                statusBar
            }

            if viewModel.isCaseDetailPresented || viewModel.isPairwiseCaseDetailPresented || viewModel.isPromptCandidateModalPresented {
                BenchmarkGlobalModalOverlay(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .onAppear {
            if autoRefreshOnAppear {
                viewModel.refresh()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.isCaseDetailPresented)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isPairwiseCaseDetailPresented)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isPromptCandidateModalPresented)
        .frame(minWidth: 1420, minHeight: 860)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Benchmark Lab")
                    .font(.system(size: 19, weight: .semibold))
                Text("タスク別ベンチマーク実行")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var tabSelector: some View {
        HStack(spacing: 10) {
            Picker("Tab", selection: $viewModel.selectedTab) {
                ForEach(BenchmarkDashboardTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 420)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if viewModel.statusIsError, viewModel.hasBenchmarkErrorLog {
                Button {
                    viewModel.copyBenchmarkErrorLog()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(viewModel.benchmarkErrorHeadline)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.14))
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.red.opacity(0.36), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help("エラーログをコピー\n\(viewModel.benchmarkErrorLog)")
            } else {
                Image(systemName: viewModel.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .foregroundStyle(viewModel.statusIsError ? Color.orange : Color.secondary)
                Text(viewModel.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
