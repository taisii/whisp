import AppKit
import SwiftUI
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class SettingsViewSnapshotTests: XCTestCase {
    private let width = 520
    private let height = 860

    func testCaptureSettingsViewBeforeGenerationPrimaryFallbackUI() throws {
        let candidate = BenchmarkCandidate(
            id: "generation-gpt-5-nano-default",
            task: .generation,
            model: "gpt-5-nano",
            promptName: "default",
            generationPromptTemplate: "入力: {STT結果}",
            generationPromptHash: promptTemplateHash("入力: {STT結果}"),
            options: ["require_context": "true", "use_cache": "true"],
            createdAt: "2026-02-14T00:00:00.000Z",
            updatedAt: "2026-02-14T00:00:00.000Z"
        )
        let selection = GenerationPrimarySelectionFactory.makeSelection(
            candidate: candidate,
            selectedAt: "2026-02-14T00:00:00.000Z"
        )

        let view = SettingsView(
            config: Config(
                apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
                shortcut: "Cmd+J",
                inputLanguage: "ja",
                recordingMode: .toggle,
                sttPreset: .deepgramStream,
                appPromptRules: [],
                llmModel: .gpt5Nano,
                context: ContextConfig(visionEnabled: true, visionMode: .ocr),
                generationPrimary: selection
            ),
            generationCandidates: [candidate],
            preserveGenerationPrimaryOnSave: false,
            onSave: { _ in },
            onCancel: {}
        )

        let bitmap = try renderSnapshot(view: view)
        let artifactDir = try makeArtifactDirectory()
        let outputURL = artifactDir.appendingPathComponent("settings_view_generation_primary_before.png")
        try pngData(from: bitmap).write(to: outputURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testCaptureSettingsViewAfterGenerationPrimaryFallbackUI() throws {
        let existingSelection = GenerationPrimarySelection(
            candidateID: "generation-gpt-5-nano-default",
            snapshot: GenerationPrimarySnapshot(
                model: .gpt5Nano,
                promptName: "default",
                promptTemplate: "入力: {STT結果}",
                promptHash: promptTemplateHash("入力: {STT結果}"),
                options: ["require_context": "true", "use_cache": "true"],
                capturedAt: "2026-02-14T00:00:00.000Z"
            ),
            selectedAt: "2026-02-14T00:00:00.000Z"
        )

        let view = SettingsView(
            config: Config(
                apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
                shortcut: "Cmd+J",
                inputLanguage: "ja",
                recordingMode: .toggle,
                sttPreset: .deepgramStream,
                appPromptRules: [],
                llmModel: .gpt5Nano,
                context: ContextConfig(visionEnabled: true, visionMode: .ocr),
                generationPrimary: existingSelection
            ),
            generationCandidates: [],
            preserveGenerationPrimaryOnSave: true,
            onSave: { _ in },
            onCancel: {}
        )

        let bitmap = try renderSnapshot(view: view)
        let artifactDir = try makeArtifactDirectory()
        let outputURL = artifactDir.appendingPathComponent("settings_view_generation_primary_after.png")
        try pngData(from: bitmap).write(to: outputURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testCaptureSettingsViewSTTProviderBeforeAfter() throws {
        let beforeView = SettingsView(
            config: Config(
                apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
                shortcut: "Cmd+J",
                inputLanguage: "ja",
                recordingMode: .toggle,
                sttPreset: .deepgramStream,
                appPromptRules: [],
                llmModel: .gpt5Nano,
                context: ContextConfig(visionEnabled: true, visionMode: .ocr),
                generationPrimary: nil
            ),
            generationCandidates: [],
            preserveGenerationPrimaryOnSave: false,
            onSave: { _ in },
            onCancel: {}
        )

        let afterView = SettingsView(
            config: Config(
                apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
                shortcut: "Cmd+J",
                inputLanguage: "ja",
                recordingMode: .toggle,
                sttPreset: .appleSpeechRecognizerStream,
                appPromptRules: [],
                llmModel: .gpt5Nano,
                context: ContextConfig(visionEnabled: true, visionMode: .ocr),
                generationPrimary: nil
            ),
            generationCandidates: [],
            preserveGenerationPrimaryOnSave: false,
            onSave: { _ in },
            onCancel: {}
        )

        let beforeBitmap = try renderSnapshot(view: beforeView.offset(y: -180), scrollY: 0)
        let afterBitmap = try renderSnapshot(view: afterView.offset(y: -180), scrollY: 0)
        let artifactDir = try makeArtifactDirectory()
        let beforeURL = artifactDir.appendingPathComponent("settings_view_stt_provider_before.png")
        let afterURL = artifactDir.appendingPathComponent("settings_view_stt_provider_after.png")
        try pngData(from: beforeBitmap).write(to: beforeURL, options: .atomic)
        try pngData(from: afterBitmap).write(to: afterURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testCaptureSettingsViewSTTCredentialHintBeforeAfter() throws {
        let beforeView = SettingsView(
            config: Config(
                apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: ""),
                shortcut: "Cmd+J",
                inputLanguage: "ja",
                recordingMode: .toggle,
                sttPreset: .chatgptWhisperStream,
                appPromptRules: [],
                llmModel: .gpt5Nano,
                context: ContextConfig(visionEnabled: true, visionMode: .ocr),
                generationPrimary: nil
            ),
            generationCandidates: [],
            preserveGenerationPrimaryOnSave: false,
            onSave: { _ in },
            onCancel: {}
        )

        let afterView = SettingsView(
            config: Config(
                apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
                shortcut: "Cmd+J",
                inputLanguage: "ja",
                recordingMode: .toggle,
                sttPreset: .chatgptWhisperStream,
                appPromptRules: [],
                llmModel: .gpt5Nano,
                context: ContextConfig(visionEnabled: true, visionMode: .ocr),
                generationPrimary: nil
            ),
            generationCandidates: [],
            preserveGenerationPrimaryOnSave: false,
            onSave: { _ in },
            onCancel: {}
        )

        let beforeBitmap = try renderSnapshot(view: beforeView)
        let afterBitmap = try renderSnapshot(view: afterView)
        let artifactDir = try makeArtifactDirectory()
        let beforeURL = artifactDir.appendingPathComponent("settings_view_stt_hint_before.png")
        let afterURL = artifactDir.appendingPathComponent("settings_view_stt_hint_after.png")
        try pngData(from: beforeBitmap).write(to: beforeURL, options: .atomic)
        try pngData(from: afterBitmap).write(to: afterURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testCaptureSettingsViewLivePreviewToggleBeforeAfter() throws {
        let beforeView = SettingsView(
            config: Config(
                apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
                shortcut: "Cmd+J",
                inputLanguage: "ja",
                recordingMode: .toggle,
                sttPreset: .appleSpeechRecognizerStream,
                sttSegmentation: STTSegmentationConfig(
                    silenceMs: 700,
                    maxSegmentMs: 25_000,
                    preRollMs: 250,
                    livePreviewEnabled: false
                ),
                appPromptRules: [],
                llmModel: .gpt5Nano,
                context: ContextConfig(visionEnabled: true, visionMode: .ocr),
                generationPrimary: nil
            ),
            generationCandidates: [],
            preserveGenerationPrimaryOnSave: false,
            onSave: { _ in },
            onCancel: {}
        )

        let afterView = SettingsView(
            config: Config(
                apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
                shortcut: "Cmd+J",
                inputLanguage: "ja",
                recordingMode: .toggle,
                sttPreset: .appleSpeechRecognizerStream,
                sttSegmentation: STTSegmentationConfig(
                    silenceMs: 700,
                    maxSegmentMs: 25_000,
                    preRollMs: 250,
                    livePreviewEnabled: true
                ),
                appPromptRules: [],
                llmModel: .gpt5Nano,
                context: ContextConfig(visionEnabled: true, visionMode: .ocr),
                generationPrimary: nil
            ),
            generationCandidates: [],
            preserveGenerationPrimaryOnSave: false,
            onSave: { _ in },
            onCancel: {}
        )

        let beforeBitmap = try renderSnapshot(view: beforeView)
        let afterBitmap = try renderSnapshot(view: afterView)
        let artifactDir = try makeArtifactDirectory()
        let beforeURL = artifactDir.appendingPathComponent("settings_view_live_preview_before.png")
        let afterURL = artifactDir.appendingPathComponent("settings_view_live_preview_after.png")
        try pngData(from: beforeBitmap).write(to: beforeURL, options: .atomic)
        try pngData(from: afterBitmap).write(to: afterURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testCaptureSettingsViewLivePreviewSectionBeforeAfter() throws {
        let beforeView = Form {
            Section("STT区切り") {
                Toggle("無音区切りのリアルタイム表示", isOn: .constant(false))
            }
        }
        .formStyle(.grouped)
        .frame(width: CGFloat(width), height: 240)

        let afterView = Form {
            Section("STT区切り") {
                Toggle("無音区切りのリアルタイム表示", isOn: .constant(true))
            }
        }
        .formStyle(.grouped)
        .frame(width: CGFloat(width), height: 240)

        let beforeBitmap = try renderSnapshot(view: beforeView)
        let afterBitmap = try renderSnapshot(view: afterView)
        let artifactDir = try makeArtifactDirectory()
        let beforeURL = artifactDir.appendingPathComponent("settings_view_live_preview_section_before.png")
        let afterURL = artifactDir.appendingPathComponent("settings_view_live_preview_section_after.png")
        try pngData(from: beforeBitmap).write(to: beforeURL, options: .atomic)
        try pngData(from: afterBitmap).write(to: afterURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    private func renderSnapshot<V: View>(view: V, scrollY: CGFloat = 0) throws -> NSBitmapImageRep {
        let root = view.frame(width: CGFloat(width), height: CGFloat(height))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        if scrollY > 0, let scrollView = firstScrollView(in: hosting) {
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let viewportHeight = scrollView.contentView.bounds.height
            let maxOffset = max(0, documentHeight - viewportHeight)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(scrollY, maxOffset)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            hosting.layoutSubtreeIfNeeded()
        }

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw AppError.io("failed to create settings bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func makeArtifactDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build/snapshot-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pngData(from bitmap: NSBitmapImageRep) throws -> Data {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.io("failed to encode settings png")
        }
        return png
    }
}
