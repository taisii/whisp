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
                sttProvider: .deepgram,
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
                sttProvider: .deepgram,
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

    private func renderSnapshot(view: SettingsView) throws -> NSBitmapImageRep {
        let root = view.frame(width: CGFloat(width), height: CGFloat(height))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw AppError.io("failed to create settings bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
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
