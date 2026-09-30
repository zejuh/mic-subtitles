// 抓电脑正在播放的声音（YouTube、网课、会议…）：跟 OST 一样用 Core Audio 的 process tap。
// Mac 静音时也抓得到；不改变你听到的声音。

import AVFoundation
import CoreAudio

enum SystemAudioError: Error {
    case permissionDenied
    case failed(String, OSStatus)
}

final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.micsubtitles.system-audio")
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    // onBuffer 在后台队列里调用；onChange（换了输出设备、声音格式变了）在主线程调用
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onChange: @escaping @Sendable () -> Void
    ) throws {
        do {
            try startTap(onBuffer: onBuffer)
            addListeners(onChange: onChange)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func startTap(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        // 抓除了自己以外所有程序放出来的声音，混成单声道
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [try Self.ownProcessObject()])
        description.name = "Mic Subtitles"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioDevices.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription), "read format")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw SystemAudioError.failed("format", -1)
        }
        let bytesPerFrame = max(streamDescription.mBytesPerFrame, 1)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mic Subtitles Capture",
            kAudioAggregateDeviceUIDKey: "local.micsubtitles.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create device")

        // 音频线程里只做复制，转换和识别交给后台队列
        let queue = queue
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = source.first, first.mDataByteSize > 0 else { return }
            let frames = first.mDataByteSize / bytesPerFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for (index, part) in source.enumerated() where index < destination.count {
                guard let from = part.mData, let to = destination[index].mData else { continue }
                memcpy(to, from, Int(min(part.mDataByteSize, destination[index].mDataByteSize)))
            }
            queue.async { onBuffer(buffer) }
        }, "create IO")
        try check(AudioDeviceStart(aggregateID, ioProcID), "start")
    }

    // 换了输出设备（插耳机、连蓝牙）或者声音格式变了，要重新接一次
    private func addListeners(onChange: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let targets = [
            (AudioObjectID(kAudioObjectSystemObject), AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)),
            (tapID, AudioDevices.address(kAudioTapPropertyFormat)),
        ]
        for (object, address) in targets {
            var address = address
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        if status == kAudioDevicePermissionsError { throw SystemAudioError.permissionDenied }
        throw SystemAudioError.failed(step, status)
    }

    private static func ownProcessObject() throws -> AudioObjectID {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioDevices.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else {
            throw SystemAudioError.failed("process", status)
        }
        return object
    }
}
