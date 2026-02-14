import Foundation
import WhispCore

enum PreflightValidator {
    static func validate(config: Config) throws {
        guard STTPresetCatalog.isAvailableOnCurrentPlatform(config.sttPreset) else {
            throw AppError.invalidArgument("選択中のSTT preset はこの環境で利用できません: \(config.sttPreset.rawValue)")
        }
        if !config.llmModel.usesDirectAudio {
            _ = try APIKeyResolver.sttCredential(config: config, preset: config.sttPreset)
        }
        _ = try APIKeyResolver.llmKey(config: config, model: config.llmModel)
    }
}
