import Foundation
import CoreAudio
import AudioToolbox

/// Listens to everything the Mac plays via a Core Audio process tap (macOS 14.2+).
/// Requires NSAudioCaptureUsageDescription; macOS asks for "System Audio Recording" once.
final class AudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "pulsar.audio", qos: .userInteractive)
    private(set) var engine: BeatEngine?
    private(set) var running = false

    func start() -> Bool {
        if running { return true }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Pulsar"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { NSLog("Pulsar: tap failed"); return false }

        guard let outputUID = Self.defaultOutputUID() else { stop(); return false }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pulsar Listener",
            kAudioAggregateDeviceUIDKey: "pulsar.listener.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID) == noErr else {
            NSLog("Pulsar: aggregate device failed"); stop(); return false
        }

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt)
        let sr = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48000
        let eng = BeatEngine(sampleRate: sr)
        engine = eng

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let buf = abl.first, let data = buf.mData else { return }
            let ch = Int(max(buf.mNumberChannels, 1))
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            eng.process(data.assumingMemoryBound(to: Float.self), frames: frames, channels: ch)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            NSLog("Pulsar: audio start failed"); stop(); return false
        }
        running = true
        return true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggregateID, p); AudioDeviceDestroyIOProcID(aggregateID, p) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggregateID = kAudioObjectUnknown; tapID = kAudioObjectUnknown
        engine = nil; running = false
    }

    private static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }
}
