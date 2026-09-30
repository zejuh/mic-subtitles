// 麦克风列表：内置麦克风、耳机、USB 麦克风、iPhone 麦克风等

import AVFoundation
import CoreAudio

struct InputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum AudioDevices {
    static func inputDevices() -> [InputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return InputDevice(uid: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func defaultInputName() -> String {
        guard let id = defaultInputID() else { return "" }
        return stringProperty(id, kAudioObjectPropertyName) ?? ""
    }

    // 让音频引擎改用指定的麦克风；要在引擎启动前调用。找不到这个麦克风就返回 false
    static func use(_ uid: String, on engine: AVAudioEngine) -> Bool {
        guard var id = allDeviceIDs().first(where: { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }),
              let unit = engine.inputNode.audioUnit else { return false }
        return AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

// 插拔麦克风、换系统默认麦克风时自动更新列表
@MainActor
@Observable
final class DeviceMonitor {
    private(set) var inputs: [InputDevice] = []
    private(set) var defaultName = ""

    init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioDevices.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    func refresh() {
        inputs = AudioDevices.inputDevices()
        defaultName = AudioDevices.defaultInputName()
    }

    func name(for uid: String) -> String? {
        inputs.first { $0.uid == uid }?.name
    }
}
