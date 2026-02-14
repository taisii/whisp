import SwiftUI
import WhispCore

struct GenerationBenchmarkView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        BenchmarkComparisonView(viewModel: viewModel, mode: .generation)
    }
}
