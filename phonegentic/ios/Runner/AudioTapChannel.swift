import Flutter
import UIKit

/// Minimal iOS bridge for the audio tap MethodChannel.
///
/// Registers the same `com.agentic_ai/audio_tap_control` channel as macOS
/// and wires `BeepDetector` callbacks to Flutter. When the full iOS audio
/// pipeline is implemented, this class should be expanded to match the
/// macOS `AudioTapChannel` functionality (mic capture, WebRTC processor
/// registration, call recording, etc.).
class AudioTapChannel: NSObject {
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let beepDetector = BeepDetector()

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.agentic_ai/audio_tap_control",
            binaryMessenger: messenger
        )
        eventChannel = FlutterEventChannel(
            name: "com.agentic_ai/audio_tap",
            binaryMessenger: messenger
        )
        super.init()
        methodChannel.setMethodCallHandler(handleMethodCall)

        let channel = self.methodChannel
        beepDetector.onBeepDetected = {
            DispatchQueue.main.async {
                channel.invokeMethod("onBeepDetected", arguments: nil)
            }
        }
        beepDetector.onBeepEnded = {
            DispatchQueue.main.async {
                channel.invokeMethod("onBeepEnded", arguments: nil)
            }
        }
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "playToneStart":
            let args = call.arguments as? [String: Any] ?? [:]
            let key = args["key"] as? String ?? ""
            let style = args["style"] as? String ?? "dtmf"
            ToneGenerator.shared.startTone(key: key, style: style)
            result(nil)
        case "playToneStop":
            let args = call.arguments as? [String: Any] ?? [:]
            let key = args["key"] as? String ?? ""
            ToneGenerator.shared.stopTone(key: key)
            result(nil)
        case "playToneEvent":
            let args = call.arguments as? [String: Any] ?? [:]
            let event = args["event"] as? String ?? ""
            ToneGenerator.shared.playEvent(event)
            result(nil)
        case "startAudioTap",
             "stopAudioTap",
             "enterCallMode",
             "exitCallMode",
             "setConferenceMode",
             "playAudioResponse",
             "stopAudioPlayback",
             "setMicMute",
             "getDominantSpeaker",
             "initSpeakerIdentifier",
             "loadKnownSpeakers",
             "registerHostSpeaker",
             "getHostSpeakerEmbedding",
             "resetSpeakerIdentifier",
             "pinRemoteSpeaker",
             "clearPinnedRemoteSpeaker",
             "getRemoteSpeakerEmbedding",
             "getRawRemoteEmbedding",
             "startCallRecording",
             "stopCallRecording",
             "startVoiceSample",
             "stopVoiceSample",
             "setRemoteGain",
             "setCompressorStrength":
            NSLog("[AudioTapChannel-iOS] %@ not yet implemented", call.method)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Called from the audio render pipeline when incoming audio is available.
    /// This is the integration point for future iOS WebRTC audio processing.
    func processIncomingAudio(buffer: UnsafePointer<Float>, frames: Int, sampleRate: Float) {
        beepDetector.process(buffer: buffer, frames: frames, sampleRate: sampleRate)
    }

    func cleanup() {
        beepDetector.reset()
        ToneGenerator.shared.stopAll()
    }
}
