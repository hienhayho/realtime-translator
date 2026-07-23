import AVFoundation

enum AudioPermission {
    static func status() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
