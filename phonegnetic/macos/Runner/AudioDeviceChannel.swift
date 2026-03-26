import Cocoa
import FlutterMacOS
import CoreAudio
import AudioToolbox

class AudioDeviceChannel {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.agentic_ai/audio_devices",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getAudioDevices":
            result(getAudioDevices())
        case "getDefaultInputDevice":
            result(getDefaultDevice(forInput: true))
        case "getDefaultOutputDevice":
            result(getDefaultDevice(forInput: false))
        case "setDefaultInputDevice":
            guard let args = call.arguments as? [String: Any],
                  let deviceId = args["deviceId"] as? UInt32 else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing deviceId", details: nil))
                return
            }
            setDefaultDevice(deviceId: AudioDeviceID(deviceId), forInput: true)
            result(nil)
        case "setDefaultOutputDevice":
            guard let args = call.arguments as? [String: Any],
                  let deviceId = args["deviceId"] as? UInt32 else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing deviceId", details: nil))
                return
            }
            setDefaultDevice(deviceId: AudioDeviceID(deviceId), forInput: false)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getAudioDevices() -> [[String: Any]] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIds = [AudioDeviceID](repeating: 0, count: deviceCount)

        let status2 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIds
        )
        guard status2 == noErr else { return [] }

        let defaultInput = getDefaultDeviceId(forInput: true)
        let defaultOutput = getDefaultDeviceId(forInput: false)

        return deviceIds.compactMap { deviceId in
            guard let name = getDeviceName(deviceId: deviceId) else { return nil }
            let hasInput = hasStreams(deviceId: deviceId, forInput: true)
            let hasOutput = hasStreams(deviceId: deviceId, forInput: false)
            guard hasInput || hasOutput else { return nil }

            var type: String
            if hasInput && hasOutput {
                type = "both"
            } else if hasInput {
                type = "input"
            } else {
                type = "output"
            }

            return [
                "id": deviceId,
                "name": name,
                "type": type,
                "isDefaultInput": deviceId == defaultInput,
                "isDefaultOutput": deviceId == defaultOutput,
                "uid": getDeviceUID(deviceId: deviceId) ?? "",
                "manufacturer": getDeviceManufacturer(deviceId: deviceId) ?? "",
                "transportType": getTransportType(deviceId: deviceId),
            ] as [String : Any]
        }
    }

    private func getStringProperty(deviceId: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceId, &propertyAddress, 0, nil, &dataSize, &value
        )
        guard status == noErr, let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }

    private func getDeviceName(deviceId: AudioDeviceID) -> String? {
        return getStringProperty(deviceId: deviceId, selector: kAudioObjectPropertyName)
    }

    private func getDeviceUID(deviceId: AudioDeviceID) -> String? {
        return getStringProperty(deviceId: deviceId, selector: kAudioDevicePropertyDeviceUID)
    }

    private func getDeviceManufacturer(deviceId: AudioDeviceID) -> String? {
        return getStringProperty(deviceId: deviceId, selector: kAudioObjectPropertyManufacturer)
    }

    private func getTransportType(deviceId: AudioDeviceID) -> String {
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceId, &propertyAddress, 0, nil, &dataSize, &transportType
        )
        guard status == noErr else { return "unknown" }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeFireWire: return "firewire"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        default: return "unknown"
        }
    }

    private func hasStreams(deviceId: AudioDeviceID, forInput: Bool) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: forInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceId, &propertyAddress, 0, nil, &dataSize
        )
        return status == noErr && dataSize > 0
    }

    private func getDefaultDeviceId(forInput: Bool) -> AudioDeviceID? {
        var deviceId: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: forInput
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceId
        )
        return status == noErr ? deviceId : nil
    }

    private func getDefaultDevice(forInput: Bool) -> [String: Any]? {
        guard let deviceId = getDefaultDeviceId(forInput: forInput),
              let name = getDeviceName(deviceId: deviceId) else {
            return nil
        }
        return [
            "id": deviceId,
            "name": name,
            "uid": getDeviceUID(deviceId: deviceId) ?? "",
        ]
    }

    private func setDefaultDevice(deviceId: AudioDeviceID, forInput: Bool) {
        var id = deviceId
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: forInput
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, dataSize, &id
        )
    }
}
