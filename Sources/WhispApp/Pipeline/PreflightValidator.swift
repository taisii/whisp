import Foundation
import WhispCore

enum PreflightValidator {
    static func validate(config: Config) throws {
        if !config.llmModel.usesDirectAudio {
            _ = try APIKeyResolver.sttKey(config: config, provider: config.sttProvider)
        }
        _ = try APIKeyResolver.llmKey(config: config, model: config.llmModel)
    }
}
