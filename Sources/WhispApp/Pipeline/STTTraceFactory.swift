import Foundation
import WhispCore

enum STTTraceFactory {
    static func attempt(
        kind: DebugSTTAttemptKind,
        status: DebugLogStatus,
        eventStartMs: Int64,
        eventEndMs: Int64,
        source: String,
        textChars: Int = 0,
        sampleRate: Int,
        audioBytes: Int,
        error: String? = nil,
        submittedChunks: Int? = nil,
        submittedBytes: Int? = nil,
        droppedChunks: Int? = nil
    ) -> DebugSTTAttempt {
        DebugSTTAttempt(
            kind: kind,
            status: status,
            eventStartMs: eventStartMs,
            eventEndMs: eventEndMs,
            source: source,
            error: error,
            textChars: textChars,
            sampleRate: sampleRate,
            audioBytes: audioBytes,
            submittedChunks: submittedChunks,
            submittedBytes: submittedBytes,
            droppedChunks: droppedChunks
        )
    }

    static func trace(
        provider: String,
        transport: STTTransport,
        route: DebugSTTRoute,
        eventStartMs: Int64,
        eventEndMs: Int64,
        status: DebugLogStatus,
        source: String,
        textChars: Int,
        sampleRate: Int,
        audioBytes: Int,
        error: String? = nil,
        attempts: [DebugSTTAttempt]
    ) -> STTTrace {
        STTTrace(
            provider: provider,
            transport: transport,
            route: route,
            mainSpan: STTMainSpanTrace(
                eventStartMs: eventStartMs,
                eventEndMs: eventEndMs,
                status: status,
                source: source,
                textChars: textChars,
                sampleRate: sampleRate,
                audioBytes: audioBytes,
                error: error
            ),
            attempts: attempts
        )
    }

    static func singleAttemptTrace(
        provider: String,
        transport: STTTransport,
        route: DebugSTTRoute,
        kind: DebugSTTAttemptKind,
        eventStartMs: Int64,
        eventEndMs: Int64,
        source: String,
        textChars: Int,
        sampleRate: Int,
        audioBytes: Int
    ) -> STTTrace {
        let attempt = attempt(
            kind: kind,
            status: .ok,
            eventStartMs: eventStartMs,
            eventEndMs: eventEndMs,
            source: source,
            textChars: textChars,
            sampleRate: sampleRate,
            audioBytes: audioBytes
        )
        return trace(
            provider: provider,
            transport: transport,
            route: route,
            eventStartMs: eventStartMs,
            eventEndMs: eventEndMs,
            status: .ok,
            source: source,
            textChars: textChars,
            sampleRate: sampleRate,
            audioBytes: audioBytes,
            attempts: [attempt]
        )
    }
}
