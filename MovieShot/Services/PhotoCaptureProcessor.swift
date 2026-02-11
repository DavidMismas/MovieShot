@preconcurrency internal import AVFoundation
import Foundation

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    nonisolated private let completionHandler: (CameraCaptureResult) -> Void
    nonisolated(unsafe) private var processedPhotoData: Data?
    nonisolated(unsafe) private var rawPhotoData: Data?

    init(completion: @escaping (CameraCaptureResult) -> Void) {
        self.completionHandler = completion
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else { return }
        guard let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            rawPhotoData = data
        } else {
            processedPhotoData = data
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard error == nil else { return }
        let result = CameraCaptureResult(
            processedData: processedPhotoData,
            rawData: rawPhotoData
        )
        let handler = completionHandler
        DispatchQueue.main.async {
            handler(result)
        }
    }
}
