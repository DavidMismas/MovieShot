import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Photos
import PhotosUI
import SwiftUI

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var step: EditorStep = .source
    /// Full-resolution source image, used for final export.
    private var fullResSourceImage: UIImage?
    /// Downscaled source image used for interactive editing preview.
    @Published var sourceImage: UIImage? {
        didSet { applyEdits() }
    }
    @Published var editedImage: UIImage?
    /// RAW DNG data from camera — used as editing source for better quality.
    private var rawCIImage: CIImage?
    /// Full-res RAW CIImage for export.
    private var fullResRawCIImage: CIImage?
    /// Whether the current source was captured in RAW.
    @Published private(set) var isRAWSource = false
    @Published var selectedPreset: MoviePreset = .matrix {
        didSet { applyEdits() }
    }
    @Published var exposure: Double = 0.0 {
        didSet { applyEdits() }
    }
    @Published var contrast: Double = 0.0 {
        didSet { applyEdits() }
    }
    @Published var shadows: Double = 0.0 {
        didSet { applyEdits() }
    }
    @Published var highlights: Double = 0.0 {
        didSet { applyEdits() }
    }
    @Published var cropOption: CropOption = .original {
        didSet {
            cropOffset = .zero
            applyEdits()
        }
    }
    /// Normalized crop offset (-1...1) for panning the crop window.
    @Published var cropOffset: CGSize = .zero {
        didSet { applyEdits() }
    }
    @Published var pickerItem: PhotosPickerItem? {
        didSet { loadFromPicker() }
    }
    @Published var statusMessage: String?
    @Published var showShareSheet = false
    @Published var showPresetLoading = false

    var cameraService = CameraService()
    private let context = CIContext()
    private var loadingTask: Task<Void, Never>?

    init() {
        cameraService.onPhoto = { [weak self] image, rawData in
            self?.setSourceImage(image, rawData: rawData)
        }
    }

    func onSourceAppear() {
        cameraService.requestPermissionIfNeeded()
    }

    func onSourceDisappear() {
        cameraService.stopSession()
    }

    func captureFromCamera() {
        cameraService.capturePhoto()
    }

    func setSourceImage(_ image: UIImage, rawData: Data? = nil) {
        loadingTask?.cancel()
        let normalized = image.normalizedUpOrientation()
        // Cap full-res at 12MP (4032px longest edge) for export
        fullResSourceImage = normalized.downscaledForEditing(maxDimension: 4032)
        sourceImage = normalized.downscaledForEditing(maxDimension: 2500)

        // If RAW DNG data is available, create CIImages from it for editing
        if let rawData,
           let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: "com.adobe.raw-image") {
            rawFilter.extendedDynamicRangeAmount = 0.0
            rawFilter.baselineExposure = 0.0
            if let fullRaw = rawFilter.outputImage {
                fullResRawCIImage = fullRaw
                // Downscale for preview by clamping longest edge
                let maxSide = Swift.max(fullRaw.extent.width, fullRaw.extent.height)
                if maxSide > 2500 {
                    let scale = 2500.0 / maxSide
                    rawCIImage = fullRaw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                } else {
                    rawCIImage = fullRaw
                }
                isRAWSource = true
            } else {
                rawCIImage = nil
                fullResRawCIImage = nil
                isRAWSource = false
            }
        } else {
            rawCIImage = nil
            fullResRawCIImage = nil
            isRAWSource = false
        }

        cameraService.stopSession()
        showPresetLoading = true

        loadingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.showPresetLoading = false
            self.step = .preset
        }
    }

    func continueStep() {
        guard let next = EditorStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func previousStep() {
        guard let previous = EditorStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    func restart() {
        loadingTask?.cancel()
        step = .source
        fullResSourceImage = nil
        sourceImage = nil
        editedImage = nil
        rawCIImage = nil
        fullResRawCIImage = nil
        isRAWSource = false
        selectedPreset = .matrix
        exposure = 0.0
        contrast = 0.0
        shadows = 0.0
        highlights = 0.0
        cropOption = .original
        cropOffset = .zero
        statusMessage = nil
        showShareSheet = false
        showPresetLoading = false
        pickerItem = nil
    }

    /// Renders the current edits at full resolution for export (JPEG output).
    /// Prefers RAW source for maximum quality.
    func renderFullResolution() -> UIImage? {
        // Prefer full-res RAW CIImage over HEVC UIImage
        let inputImage: CIImage
        if let fullResRawCIImage {
            inputImage = fullResRawCIImage
        } else if let fullRes = fullResSourceImage, let ci = CIImage(image: fullRes) {
            inputImage = ci
        } else {
            return editedImage
        }

        return autoreleasepool {
            let output = applyFilterChain(to: inputImage)
            guard let cgImage = context.createCGImage(output, from: output.extent) else {
                return fullResSourceImage
            }
            return UIImage(cgImage: cgImage)
        }
    }

    func saveToLibrary() {
        guard let image = renderFullResolution() else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.statusMessage = "Photo save permission denied."
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                Task { @MainActor in
                    self.statusMessage = success ? "Saved to gallery." : "Save failed."
                }
            }
        }
    }

    private func loadFromPicker() {
        guard let pickerItem else { return }
        Task {
            do {
                guard let data = try await pickerItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data)
                else {
                    statusMessage = "Could not load selected photo."
                    return
                }
                setSourceImage(image)
            } catch {
                statusMessage = "Could not load selected photo."
            }
        }
    }

    private func applyEdits() {
        guard sourceImage != nil else {
            editedImage = nil
            return
        }
        // Prefer RAW CIImage (14-bit sensor data) over HEVC UIImage (8-bit)
        let inputImage: CIImage
        if let rawCIImage {
            inputImage = rawCIImage
        } else if let sourceImage, let ci = CIImage(image: sourceImage) {
            inputImage = ci
        } else {
            editedImage = nil
            return
        }

        let rendered: UIImage? = autoreleasepool {
            let output = applyFilterChain(to: inputImage)
            guard let cgImage = context.createCGImage(output, from: output.extent) else {
                return sourceImage
            }
            return UIImage(cgImage: cgImage)
        }

        editedImage = rendered ?? sourceImage
    }

    /// Applies all current edits (preset, adjustments, crop) to a CIImage.
    private func applyFilterChain(to inputImage: CIImage) -> CIImage {
        var output = applyMoviePreset(selectedPreset, to: inputImage)

        let exposureFilter = CIFilter.exposureAdjust()
        exposureFilter.inputImage = output
        exposureFilter.ev = Float(exposure)
        output = exposureFilter.outputImage ?? output

        // contrast slider: 0 = neutral (1.0), -1 = 0.5, +1 = 1.5
        let contrastFilter = CIFilter.colorControls()
        contrastFilter.inputImage = output
        contrastFilter.contrast = Float(1.0 + contrast * 0.5)
        output = contrastFilter.outputImage ?? output

        // shadows: slider 0 = neutral, -1…+1 maps directly to filter shadowAmount
        // highlights: slider 0 = neutral (filter 1.0), -1 = 0, +1 = 2
        let shadowHighlightFilter = CIFilter.highlightShadowAdjust()
        shadowHighlightFilter.inputImage = output
        shadowHighlightFilter.shadowAmount = Float(shadows)
        shadowHighlightFilter.highlightAmount = Float(1.0 + highlights)
        output = shadowHighlightFilter.outputImage ?? output

        if let ratio = cropOption.ratio {
            output = offsetCrop(image: output, targetRatio: ratio, forceHorizontal: cropOption.forceHorizontal, offset: cropOffset)
        }

        return output
    }

    private func applyMoviePreset(_ preset: MoviePreset, to image: CIImage) -> CIImage {
        switch preset {
        case .matrix:
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: 0.92, y: 0.05, z: 0.0, w: 0.0)
            matrix.gVector = CIVector(x: 0.08, y: 1.05, z: 0.04, w: 0.0)
            matrix.bVector = CIVector(x: 0.0, y: 0.08, z: 0.75, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            var output = matrix.outputImage ?? image

            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.82
            controls.contrast = 1.18
            controls.brightness = -0.01
            output = controls.outputImage ?? output

            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5600, y: -15)
            return temp.outputImage ?? output

        case .bladeRunner2049:
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: 1.08, y: 0.06, z: 0.0, w: 0.0)
            matrix.gVector = CIVector(x: 0.02, y: 0.95, z: 0.08, w: 0.0)
            matrix.bVector = CIVector(x: 0.0, y: 0.10, z: 0.88, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            var output = matrix.outputImage ?? image

            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.1
            controls.contrast = 1.20
            controls.brightness = 0.03
            output = controls.outputImage ?? output

            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 7600, y: 22)
            return temp.outputImage ?? output

        case .sinCity:
            // Sin City: near-monochrome, extreme contrast, noir
            // Luminance-weighted desaturation with boosted red channel (brighter skin tones)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: 0.35, y: 0.55, z: 0.10, w: 0.0)
            matrix.gVector = CIVector(x: 0.35, y: 0.55, z: 0.10, w: 0.0)
            matrix.bVector = CIVector(x: 0.35, y: 0.55, z: 0.10, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            matrix.biasVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.0)
            var output = matrix.outputImage ?? image

            // High contrast, full desaturation (already B&W from matrix), slight darkening
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.0
            controls.contrast = 1.45
            controls.brightness = 0.02
            output = controls.outputImage ?? output

            // Crush shadows, push highlights for stencil noir feel
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.5
            shadowHighlight.highlightAmount = 0.7
            output = shadowHighlight.outputImage ?? output

            // Slight exposure push to open up highlights
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = output
            exposureFilter.ev = 0.3
            output = exposureFilter.outputImage ?? output

            // Slightly cool temperature for noir feel
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 6200, y: 0)
            return temp.outputImage ?? output

        case .theBatman:
            // The Batman 2022: dark, desaturated, bleach bypass, teal shadows, crushed blacks
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Desaturate reds, cool skin tones
            matrix.rVector = CIVector(x: 0.90, y: 0.07, z: 0.03, w: 0.0)
            // Dusty greens, slight cross-contamination
            matrix.gVector = CIVector(x: 0.05, y: 0.92, z: 0.06, w: 0.0)
            // Suppress pure blue, create teal shadows via green bleed
            matrix.bVector = CIVector(x: 0.02, y: 0.10, z: 0.78, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Lift blacks slightly with blue bias (prevents pure black)
            matrix.biasVector = CIVector(x: 0.01, y: 0.012, z: 0.018, w: 0.0)
            var output = matrix.outputImage ?? image

            // Bleach bypass desaturation + chiaroscuro contrast
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.65
            controls.contrast = 1.25
            controls.brightness = -0.02
            output = controls.outputImage ?? output

            // Cool temperature shift with slight green tint (teal Gotham)
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5400, y: -10)
            output = temp.outputImage ?? output

            // Dark overall feel ~1/3 stop under
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = output
            exposureFilter.ev = -0.4
            output = exposureFilter.outputImage ?? output

            // Crush shadows, soft highlight roll-off
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.3
            shadowHighlight.highlightAmount = 0.85
            return shadowHighlight.outputImage ?? output

        case .strangerThings:
            // Stranger Things: warm 80s amber, muted vintage, nostalgic high contrast
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Boost red, pull warmth from green (amber skin tones)
            matrix.rVector = CIVector(x: 1.08, y: 0.08, z: 0.0, w: 0.0)
            // Slight red cross-bleed, reduce green (faded film stock)
            matrix.gVector = CIVector(x: 0.06, y: 0.92, z: 0.0, w: 0.0)
            // Suppress blue strongly, tiny green cross-talk (teal shadow undertone)
            matrix.bVector = CIVector(x: 0.0, y: 0.06, z: 0.82, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Warm lifted shadows (brown tint), pull blue down
            matrix.biasVector = CIVector(x: 0.04, y: 0.02, z: -0.02, w: 0.0)
            var output = matrix.outputImage ?? image

            // Muted vintage desaturation, high contrast
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.85
            controls.contrast = 1.15
            controls.brightness = -0.01
            output = controls.outputImage ?? output

            // Deep warm amber shift (tungsten/incandescent feel), slight magenta tint
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 4800, y: 10)
            return temp.outputImage ?? output
        }
    }

    /// Crops to `targetRatio`. Auto-swaps orientation to match image unless `forceHorizontal`.
    /// `offset` is normalized –1…+1 panning within the available slack.
    private func offsetCrop(image: CIImage, targetRatio: CGFloat, forceHorizontal: Bool, offset: CGSize) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        let currentRatio = extent.width / extent.height
        let desiredRatio: CGFloat
        if forceHorizontal {
            // Always use the wider ratio (> 1.0), never swap to vertical
            desiredRatio = Swift.max(targetRatio, 1.0 / targetRatio)
        } else {
            let swapped = 1.0 / targetRatio
            desiredRatio = abs(currentRatio - targetRatio) <= abs(currentRatio - swapped)
                ? targetRatio : swapped
        }

        var cropRect = extent
        if currentRatio > desiredRatio {
            let newWidth = extent.height * desiredRatio
            let slack = extent.width - newWidth
            let center = slack / 2.0
            cropRect.origin.x += center + offset.width * center
            cropRect.size.width = newWidth
        } else {
            let newHeight = extent.width / desiredRatio
            let slack = extent.height - newHeight
            let center = slack / 2.0
            // CIImage Y is bottom-up, negate so drag-up moves the crop window up
            cropRect.origin.y += center - offset.height * center
            cropRect.size.height = newHeight
        }

        return image.cropped(to: cropRect)
    }
}

private extension UIImage {
    func normalizedUpOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func downscaledForEditing(maxDimension: CGFloat) -> UIImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }

        let scaleFactor = maxDimension / maxSide
        let targetSize = CGSize(
            width: size.width * scaleFactor,
            height: size.height * scaleFactor
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = false

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
