import SwiftUI
import WhispCore

struct GenerationSingleBenchmarkView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        BenchmarkComparisonView(viewModel: viewModel, mode: .generationSingle)
    }
}
