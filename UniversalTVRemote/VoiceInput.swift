import AVFoundation

/// Phone-mic capture for Android TV voice: 16-bit PCM, mono, 8 kHz —
/// the format the Android TV Remote Service expects (see
/// remotemessage.proto: "a sequence of 16-bit PCM, 8 kHz, mono
/// samples"). The phone's mic runs at its native rate (typically 44.1
/// or 48 kHz float); an AVAudioConverter downsamples to the target
/// format on the fly. No audio is stored or sent anywhere except to the
/// TV the user is holding the mic button for.
final class VoiceCapture {

    enum VoiceCaptureError: Error, LocalizedError {
        case permissionDenied
        case microphoneUnavailable
        case engineFailed(Error)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is off — enable it in Settings to use voice."
            case .microphoneUnavailable:
                return "No microphone is available on this device."
            case .engineFailed(let error):
                return "Couldn't start the microphone. (\(error.localizedDescription))"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Starts capture. `onSamples` receives converted 8 kHz mono Int16
    /// PCM chunks as they arrive (each well under the 20 KB message
    /// limit). Throws if microphone permission is denied or the mic /
    /// engine cannot start. Starting twice is a no-op.
    func start(onSamples: @escaping (Data) -> Void) async throws {
        guard !isRunning else { return }
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else { throw VoiceCaptureError.permissionDenied }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            try session.setActive(true)
        } catch {
            throw VoiceCaptureError.engineFailed(error)
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else { throw VoiceCaptureError.microphoneUnavailable }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 8000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceCaptureError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer, using: converter, targetFormat: targetFormat, onSamples: onSamples)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceCaptureError.engineFailed(error)
        }
        isRunning = true
    }

    /// Stops capture and releases the mic. Safe to call when not running.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Convert one tap buffer to 8 kHz mono Int16 PCM and hand the bytes
    /// to `onSamples`. Runs on the audio thread — cheap, no blocking.
    /// Uses the block-based converter API (available since iOS 8);
    /// the simpler convert(to:from:) needs a newer deployment target.
    private func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                         targetFormat: AVAudioFormat, onSamples: (Data) -> Void) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var inputUsed = false
        var convertError: NSError?
        let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
            if inputUsed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputUsed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outBuffer.frameLength > 0,
              let channelData = outBuffer.int16ChannelData else { return }
        let byteCount = Int(outBuffer.frameLength) * 2
        let data = Data(bytes: channelData[0], count: byteCount)
        if !data.isEmpty { onSamples(data) }
    }
}
