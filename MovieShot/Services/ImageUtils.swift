import UIKit
import CoreImage

/// Actor for background image processing to enforce off-main-thread execution.
actor ImageWorker {
    private let context: CIContext
    
    init(context: CIContext) {
        self.context = context
    }

    func normalizedUpOrientation(for image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        
        guard let ciImage = CIImage(image: image) else { return image }
        
        // CIImage(image:) ignores the UIImage's orientation tag and loads raw pixel data.
        // We must manually apply the orientation transform to "bake" it into the pixels.
        let orientation = cgImagePropertyOrientation(from: image.imageOrientation)
        let orientedCI = ciImage.oriented(forExifOrientation: Int32(orientation.rawValue))
        
        guard let cgImage = context.createCGImage(orientedCI, from: orientedCI.extent) else {
            return image
        }
        return UIImage(cgImage: cgImage)
    }

    func downscaled(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > maxDimension else { return image }
        
        guard let ciImage = CIImage(image: image) else { return image }
        // Note: We assume 'image' is already normalized to .up by `normalizedUpOrientation` 
        // before calling this, so we don't need to check orientation here.

        let scale = maxDimension / maxSide
        let filter = CIFilter(name: "CILanczosScaleTransform")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(scale, forKey: kCIInputScaleKey)
        filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
        
        guard let output = filter?.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent)
        else {
            return image
        }
        
        return UIImage(cgImage: cgImage)
    }

    private func cgImagePropertyOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
