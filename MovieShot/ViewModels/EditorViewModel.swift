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
    // CIContext is thread-safe and expensive to create, so we keep one instance.
    private let context = CIContext()
    
    private var loadingTask: Task<Void, Never>?
    private var editTask: Task<Void, Never>?

    init() {
        cameraService.onPhoto = { [weak self] image in
            self?.setSourceImage(image)
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

    func setSourceImage(_ image: UIImage) {
        loadingTask?.cancel()

        let context = self.context

        loadingTask = Task.detached(priority: .userInitiated) {
            let worker = ImageWorker(context: context)
            let normalized = await worker.normalizedUpOrientation(for: image)
            let fullRes = await worker.downscaled(image: normalized, maxDimension: 4032)
            let preview = await worker.downscaled(image: normalized, maxDimension: 2500)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fullResSourceImage = fullRes
                self.sourceImage = preview

                self.cameraService.stopSession()
                self.showPresetLoading = true

                self.loadingTask = Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled else { return }
                    self.showPresetLoading = false
                    self.step = .preset
                }
            }
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
        editTask?.cancel()
        step = .source
        fullResSourceImage = nil
        sourceImage = nil
        editedImage = nil
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
        let inputImage: CIImage
        if let fullRes = fullResSourceImage, let ci = CIImage(image: fullRes) {
            inputImage = ci
        } else {
            return editedImage
        }

        return autoreleasepool {
            let output = applyFilterChain(
                to: inputImage,
                preset: selectedPreset,
                exposure: exposure,
                contrast: contrast,
                shadows: shadows,
                highlights: highlights,
                cropOption: cropOption,
                cropOffset: cropOffset
            )
            guard let cgImage = context.createCGImage(output, from: output.extent) else {
                return fullResSourceImage
            }
            return UIImage(cgImage: cgImage)
        }
    }
    
    // ... rest of class functions ...

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
        editTask?.cancel()
        
        guard let sourceImage else {
            editedImage = nil
            return
        }
        
        guard let ci = CIImage(image: sourceImage) else {
            editedImage = nil
            return
        }
        let inputImage = ci
        
        // Capture current state values
        let preset = selectedPreset
        let exp = exposure
        let con = contrast
        let shad = shadows
        let high = highlights
        let cropOpt = cropOption
        let cropOff = cropOffset
        
        editTask = Task {
            // Debounce to avoid stuttering during slider drag
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms
            if Task.isCancelled { return }
            
            
            // Perform rendering on a detached task to avoid blocking main thread
            // We can't use `Task.detached` easily inside this `Task` without more dancing,
            // but simply being in a Task allows non-blocking of the UI event loop if we yield.
            // However, CIContext.createCGImage IS synchronous and CPU intensive.
            // So we really want `Task.detached`.
            
            let result: UIImage? = await Task.detached(priority: .userInitiated) {
                if Task.isCancelled { return nil }
                
                let output = await self.applyFilterChain(
                    to: inputImage,
                    preset: preset,
                    exposure: exp,
                    contrast: con,
                    shadows: shad,
                    highlights: high,
                    cropOption: cropOpt,
                    cropOffset: cropOff
                )
                
                if Task.isCancelled { return nil }
                
                let cgImage = self.context.createCGImage(output, from: output.extent)
                if let cgImage {
                    return UIImage(cgImage: cgImage)
                }
                return nil
            }.value
            
            if !Task.isCancelled, let result {
                self.editedImage = result
            }
        }
    }

    private func applyFilterChain(
        to inputImage: CIImage,
        preset: MoviePreset,
        exposure: Double,
        contrast: Double,
        shadows: Double,
        highlights: Double,
        cropOption: CropOption,
        cropOffset: CGSize
    ) -> CIImage {
        var output = applyMoviePreset(preset, to: inputImage)

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
            // Sin City: B&W with red colour spill — only saturated reds stay red, all else monochrome

            // --- B&W pipeline ---
            let bwMatrix = CIFilter.colorMatrix()
            bwMatrix.inputImage = image
            bwMatrix.rVector = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0.0)
            bwMatrix.gVector = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0.0)
            bwMatrix.bVector = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0.0)
            bwMatrix.aVector = CIVector(x: 0.0,   y: 0.0,   z: 0.0,   w: 1.0)
            var bw = bwMatrix.outputImage ?? image

            let bwControls = CIFilter.colorControls()
            bwControls.inputImage = bw
            bwControls.saturation = 0.0
            bwControls.contrast = 1.5
            bwControls.brightness = 0.0
            bw = bwControls.outputImage ?? bw

            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = bw
            shadowHighlight.shadowAmount = -0.55
            shadowHighlight.highlightAmount = 0.65
            bw = shadowHighlight.outputImage ?? bw

            // --- Red mask via 3D colour cube (HSB-based) ---
            // Build a 64³ cube LUT: pixels whose hue is in the red range AND
            // have enough saturation map to white (1,1,1); everything else to black (0,0,0).
            let redMask = Self.sinCityRedMask(image: image)

            // Boost saturation on original so reds pop vividly
            let boostControls = CIFilter.colorControls()
            boostControls.inputImage = image
            boostControls.saturation = 2.2
            boostControls.contrast = 1.1
            boostControls.brightness = 0.0
            let boostedColor = boostControls.outputImage ?? image

            // Blend: mask=white → boosted colour (red areas), mask=black → B&W
            let blend = CIFilter(name: "CIBlendWithMask")!
            blend.setValue(boostedColor, forKey: kCIInputImageKey)
            blend.setValue(bw, forKey: kCIInputBackgroundImageKey)
            blend.setValue(redMask, forKey: kCIInputMaskImageKey)
            return blend.outputImage ?? bw

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

    // MARK: - Sin City red mask

    /// 64³ colour cube data for the red-hue mask used by Sin City preset.
    private static var sinCityColorCubeData: Data = {
        let size = 64
        let stride = size * size * size * 4  // RGBA Float32
        var data = [Float32](repeating: 0, count: size * size * size * 4)
        // CIColorCube iterates: b outermost, g middle, r innermost
        for bi in 0..<size {
            for gi in 0..<size {
                for ri in 0..<size {
                    let r = Float(ri) / Float(size - 1)
                    let g = Float(gi) / Float(size - 1)
                    let b = Float(bi) / Float(size - 1)

                    // Convert RGB → HSB
                    let maxC = Swift.max(r, g, b)
                    let minC = Swift.min(r, g, b)
                    let delta = maxC - minC

                    var h: Float = 0
                    if delta > 0.001 {
                        if maxC == r {
                            h = (g - b) / delta
                            if h < 0 { h += 6 }
                        } else if maxC == g {
                            h = 2 + (b - r) / delta
                        } else {
                            h = 4 + (r - g) / delta
                        }
                        h /= 6  // normalise to 0…1
                    }

                    let s = maxC > 0.001 ? delta / maxC : 0
                    let v = maxC

                    // Ultra-tight red hue: ≈ ±8° around 0°/360° — only pure crimson/blood red
                    let isRedHue = h <= 0.022 || h >= 0.978
                    // Very high saturation: must be vivid saturated red (blood, lipstick)
                    let isRed = isRedHue && s > 0.80 && v > 0.20

                    let mask: Float = isRed ? 1.0 : 0.0
                    let idx = (bi * size * size + gi * size + ri) * 4
                    data[idx + 0] = mask
                    data[idx + 1] = mask
                    data[idx + 2] = mask
                    data[idx + 3] = 1.0
                }
            }
        }
        return Data(bytes: data, count: data.count * MemoryLayout<Float32>.size)
    }()

    private static func sinCityRedMask(image: CIImage) -> CIImage {
        let size = 64
        let cube = CIFilter(name: "CIColorCube")!
        cube.setValue(size, forKey: "inputCubeDimension")
        cube.setValue(sinCityColorCubeData, forKey: "inputCubeData")
        cube.setValue(image, forKey: kCIInputImageKey)
        return cube.outputImage ?? image
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


