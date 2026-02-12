import SwiftUI

struct BenchmarkView: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    var autoRefreshOnAppear = true

    var body: some View {
        BenchmarkWorkspaceView(
            viewModel: viewModel,
            autoRefreshOnAppear: autoRefreshOnAppear
        )
    }
}

