import AVFoundation
import Foundation

public struct SystemMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    public init() {}

    public func status() async -> MicrophonePermissionStatus {
        map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestPermission() async -> MicrophonePermissionStatus {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        guard current == .notDetermined else { return map(current) }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }

    private func map(_ status: AVAuthorizationStatus) -> MicrophonePermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

extension RealtimeMeasurementFailure: LocalizedError {
    public var errorDescription: String? { userMessage }
}
