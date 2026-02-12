import SwiftUI
import WhispCore

enum BenchmarkComparisonMode {
    case stt
    case generationSingle
    case generationBattle
}

struct STTBenchmarkView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        BenchmarkComparisonView(viewModel: viewModel, mode: .stt)
    }
}
