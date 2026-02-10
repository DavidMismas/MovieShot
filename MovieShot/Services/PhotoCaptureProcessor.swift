@preconcurrency internal import AVFoundation
import Foundation

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let settings: AVCapturePhotoSettings
    nonisolated private let completionHandler: (Data?) -> Void
    nonisolated(unsafe) private var photoData: Data?

    init(with settings: AVCapturePhotoSettings, completion: @escaping (Data?) -> Void) {
        self.settings = settings
        self.completionHandler = completion
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else { return }
        photoData = photo.fileDataRepresentation()
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard error == nil else { return }
        let data = photoData
        let handler = completionHandler
        DispatchQueue.main.async {
            handler(data)
        }
    }
}
