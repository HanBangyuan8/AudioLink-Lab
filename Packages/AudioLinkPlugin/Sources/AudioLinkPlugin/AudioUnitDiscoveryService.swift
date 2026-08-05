import Foundation

public struct AudioUnitDiscoveryService: Sendable {
    public init() {}

    public func discover() -> [PluginScanResult] {
#if os(macOS)
        return discoverMacOS()
#else
        return []
#endif
    }
}

#if os(macOS)
import AudioToolbox

private extension AudioUnitDiscoveryService {
    func discoverMacOS() -> [PluginScanResult] {
        var query = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        var results: [PluginScanResult] = []
        while let component = AudioComponentFindNext(nil, &query) {
            var description = AudioComponentDescription(componentType: 0, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            guard AudioComponentGetDescription(component, &description) == noErr else { break }
            var version: UInt32 = 0
            _ = AudioComponentGetVersion(component, &version)
            let identity = AudioUnitComponentIdentity(type: description.componentType, subtype: description.componentSubType, manufacturer: description.componentManufacturer, version: "\(version)")
            var nameRef: Unmanaged<CFString>?
            let nameStatus = AudioComponentCopyName(component, &nameRef)
            let name = nameStatus == noErr ? nameRef?.takeRetainedValue() as String? : nil
            let displayName = name ?? "Audio Unit \(fourCC(description.componentSubType))"
            let descriptor = AudioUnitDescriptor(identity: identity, name: displayName, validationStatus: .unknown)
            results.append(PluginScanResult(descriptor: descriptor, diagnostics: ["Discovery only; rendering is isolated and not automatically attempted."]))
            query.componentSubType = 0; query.componentManufacturer = 0
        }
        return results
    }

    func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}
#endif
