import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool

    var id: String { uid }
}

final class AudioDeviceManager {
    static let shared = AudioDeviceManager()

    static let preferredInputDeviceDefaultsKey = "preferredInputDeviceUID"

    private init() {}

    func availableInputDevices() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()

        return allDeviceIDs().compactMap { deviceID in
            guard hasInputStreams(deviceID: deviceID),
                  let uid = stringProperty(
                    deviceID: deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                  ),
                  let name = stringProperty(
                    deviceID: deviceID,
                    selector: kAudioObjectPropertyName
                  ) else {
                return nil
            }

            return AudioInputDevice(
                deviceID: deviceID,
                uid: uid,
                name: name,
                isDefault: deviceID == defaultID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func defaultInputDevice() -> AudioInputDevice? {
        availableInputDevices().first(where: \.isDefault)
    }

    func resolvedInputDevice() -> AudioInputDevice? {
        let preferredUID = preferredInputDeviceUID()
        let devices = availableInputDevices()

        if let preferredUID,
           let preferred = devices.first(where: { $0.uid == preferredUID }) {
            return preferred
        }

        return devices.first(where: \.isDefault) ?? devices.first
    }

    func currentSelectionDisplayName() -> String {
        guard let resolved = resolvedInputDevice() else {
            return "No input device"
        }

        if let preferredUID = preferredInputDeviceUID(),
           preferredUID == resolved.uid {
            return resolved.name
        }

        return "\(resolved.name) (System Default)"
    }

    @discardableResult
    func configureInputDevice(for engine: AVAudioEngine) -> String {
        guard let target = resolvedInputDevice() else {
            return "No input device"
        }

        var deviceID = target.deviceID
        let status = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            print("AudioDeviceManager: failed to switch input device to \(target.name), status=\(status)")
        }

        return target.name
    }

    func preferredInputDeviceUID() -> String? {
        let value = UserDefaults.standard.string(forKey: Self.preferredInputDeviceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }

        return ids
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
