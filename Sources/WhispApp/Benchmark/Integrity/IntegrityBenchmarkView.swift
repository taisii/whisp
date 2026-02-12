import SwiftUI

struct IntegrityBenchmarkView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        BenchmarkIntegrityView(viewModel: viewModel)
    }
}

