import Foundation
import WhispCore

struct AppDependencies {
    let configStore: ConfigStore
    let usageStore: UsageStore
    let recordingService: RecordingService
    let sttService: STTService
    let contextService: ContextService
    let postProcessor: PostProcessorService
    let outputService: OutputService
    let debugCaptureService: DebugCaptureService
    let hotKeyMonitor: GlobalHotKeyMonitor

    static func live() throws -> AppDependencies {
        AppDependencies(
            configStore: try ConfigStore(),
            usageStore: try UsageStore(),
            recordingService: SystemRecordingService(),
            sttService: ProviderSwitchingSTTService(),
            contextService: ContextService(
                accessibilityProvider: SystemAccessibilityContextProvider(),
                visionProvider: ScreenVisionContextProvider()
            ),
            postProcessor: PostProcessorService(),
            outputService: DirectInputOutputService(),
            debugCaptureService: DebugCaptureService(),
            hotKeyMonitor: try GlobalHotKeyMonitor()
        )
    }
}
