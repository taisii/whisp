import SwiftUI
import WhispCore

enum BenchmarkComparisonMode {
    case stt
    case generation
}

struct STTBenchmarkView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        BenchmarkComparisonView(viewModel: viewModel, mode: .stt)
    }
}
