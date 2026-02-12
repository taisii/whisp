import SwiftUI
import WhispCore

struct GenerationBattleBenchmarkView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        BenchmarkComparisonView(viewModel: viewModel, mode: .generationBattle)
    }
}
