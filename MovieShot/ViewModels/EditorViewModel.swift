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
    /// Optional Apple ProRAW data for highest-quality final export render.
    private var proRawSourceData: Data?
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
    @Published var showSaveConfirmation = false
    @Published var showShareSheet = false
    @Published var showPresetLoading = false

    var cameraService = CameraService()
    /// CIContext is thread-safe and expensive to create — keep one instance for export rasterization.
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var cameraServiceChangeCancellable: AnyCancellable?
    private var loadingTask: Task<Void, Never>?
    private var saveConfirmationTask: Task<Void, Never>?
    private var pendingRenderRequest: RenderRequest?
    private var isRenderingPreview = false
    private var previewRenderGeneration = 0

    private struct RenderRequest {
        let generation: Int
        let sourceImage: UIImage
        let preset: MoviePreset
        let exposure: Double
        let contrast: Double
        let shadows: Double
        let highlights: Double
        let cropOption: CropOption
        let cropOffset: CGSize
    }

    init() {
        cameraServiceChangeCancellable = cameraService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        cameraService.onPhotoCapture = { [weak self] captureResult in
            self?.handleCameraCaptureResult(captureResult)
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

    func setSourceImage(_ image: UIImage, proRawData: Data? = nil) {
        loadingTask?.cancel()
        invalidatePreviewRenders()
        proRawSourceData = proRawData

        let ciContext = self.ciContext
        loadingTask = Task.detached(priority: .userInitiated) {
            let worker = ImageWorker(context: ciContext)
            let normalized = await worker.normalizedUpOrientation(for: image)
            let fullRes = await worker.downscaled(image: normalized, maxDimension: 4032)
            let preview = await worker.downscaled(image: normalized, maxDimension: 1800)

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
        saveConfirmationTask?.cancel()
        invalidatePreviewRenders()
        step = .source
        fullResSourceImage = nil
        proRawSourceData = nil
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
        showSaveConfirmation = false
        showShareSheet = false
        showPresetLoading = false
        pickerItem = nil
    }

    /// Renders the current edits at full resolution for export (JPEG output).
    /// Prefers RAW source for maximum quality.
    func renderFullResolution() -> UIImage? {
        let inputImage: CIImage
        if let proRawSourceData,
           let ci = makeCIImageFromProRAWData(proRawSourceData) {
            inputImage = ci
        } else if let fullRes = fullResSourceImage, let ci = CIImage(image: fullRes) {
            inputImage = ci
        } else {
            return editedImage
        }

        return autoreleasepool {
            let output = EditorViewModel.applyFilterChainStatic(
                to: inputImage,
                preset: selectedPreset,
                exposure: exposure,
                contrast: contrast,
                shadows: shadows,
                highlights: highlights,
                cropOption: cropOption,
                cropOffset: cropOffset
            )
            guard let cgImage = ciContext.createCGImage(output, from: output.extent) else {
                return fullResSourceImage
            }
            return UIImage(cgImage: cgImage)
        }
    }
    
    // ... rest of class functions ...

    func saveToLibrary() {
        guard let image = renderFullResolution() else { return }
        statusMessage = nil

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.showSaveConfirmation = false
                    self.statusMessage = "Photo save permission denied."
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                Task { @MainActor in
                    if success {
                        self.statusMessage = nil
                        self.presentSaveConfirmation()
                    } else {
                        self.showSaveConfirmation = false
                        self.statusMessage = "Save failed."
                    }
                }
            }
        }
    }

    private func handleCameraCaptureResult(_ result: CameraCaptureResult) {
        if let processedData = result.processedData,
           let image = UIImage(data: processedData) {
            setSourceImage(image, proRawData: result.rawData)
            return
        }

        if let rawData = result.rawData,
           let ci = makeCIImageFromProRAWData(rawData),
           let cgImage = ciContext.createCGImage(ci, from: ci.extent) {
            let image = UIImage(cgImage: cgImage)
            setSourceImage(image, proRawData: rawData)
            return
        }

        statusMessage = "Photo capture failed."
    }

    private func makeCIImageFromProRAWData(_ data: Data) -> CIImage? {
        if let rawFilter = CIFilter(
            imageData: data,
            options: [CIRAWFilterOption.allowDraftMode: false]
        ) as? CIRAWFilter,
           let output = rawFilter.outputImage {
            return output
        }

        return CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        )
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
        guard let sourceImage else {
            pendingRenderRequest = nil
            editedImage = nil
            return
        }

        pendingRenderRequest = RenderRequest(
            generation: previewRenderGeneration,
            sourceImage: sourceImage,
            preset: selectedPreset,
            exposure: exposure,
            contrast: contrast,
            shadows: shadows,
            highlights: highlights,
            cropOption: cropOption,
            cropOffset: cropOffset
        )

        guard !isRenderingPreview else { return }
        isRenderingPreview = true
        processNextPreviewRender()
    }

    private func processNextPreviewRender() {
        guard let request = pendingRenderRequest else {
            isRenderingPreview = false
            return
        }

        pendingRenderRequest = nil
        let ctx = ciContext

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let ci = CIImage(image: request.sourceImage) else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishPreviewRender(request: request, image: nil)
                }
                return
            }

            let output = EditorViewModel.applyFilterChainStatic(
                to: ci,
                preset: request.preset,
                exposure: request.exposure,
                contrast: request.contrast,
                shadows: request.shadows,
                highlights: request.highlights,
                cropOption: request.cropOption,
                cropOffset: request.cropOffset
            )

            let renderedImage: UIImage?
            if let cgImage = ctx.createCGImage(output, from: output.extent) {
                renderedImage = UIImage(cgImage: cgImage)
            } else {
                renderedImage = nil
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishPreviewRender(request: request, image: renderedImage)
            }
        }
    }

    private func finishPreviewRender(request: RenderRequest, image: UIImage?) {
        if request.generation == previewRenderGeneration, let image {
            editedImage = image
        }
        processNextPreviewRender()
    }

    private func invalidatePreviewRenders() {
        previewRenderGeneration += 1
        pendingRenderRequest = nil
    }

    private func presentSaveConfirmation() {
        saveConfirmationTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            showSaveConfirmation = true
        }

        saveConfirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.showSaveConfirmation = false
            }
        }
    }

    nonisolated private static func applyFilterChainStatic(
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

        output = applyPresetFinish(preset, to: output)

        return output
    }

    nonisolated private static func applyMoviePreset(_ preset: MoviePreset, to image: CIImage) -> CIImage {
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
            // Blade Runner 2049: strong orange-warm highlights, cool blue-purple teal shadows.
            // Deakins shot with zone-specific palettes — this approximates the dominant city look.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Warm red/orange boost in highlights; slight green cross
            matrix.rVector = CIVector(x: 1.10, y: 0.07, z: 0.0, w: 0.0)
            // Neutral green, bleed into blue for teal quality
            matrix.gVector = CIVector(x: 0.02, y: 0.94, z: 0.10, w: 0.0)
            // Teal shadow push: strong green bleed into blue, suppress pure blue
            matrix.bVector = CIVector(x: 0.0, y: 0.16, z: 0.82, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Slightly cool shadow bias with blue lift (purple-teal shadow character)
            matrix.biasVector = CIVector(x: 0.008, y: 0.006, z: 0.020, w: 0.0)
            var output = matrix.outputImage ?? image

            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.12
            controls.contrast = 1.22
            controls.brightness = 0.02
            output = controls.outputImage ?? output

            // Warm shift for the amber highlight zones (Las Vegas / city glow)
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 7200, y: 18)
            output = temp.outputImage ?? output

            // Wide dynamic range: generous highlight roll-off, hold shadow detail
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = 0.10
            shadowHighlight.highlightAmount = 0.82
            return shadowHighlight.outputImage ?? output

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
            // Stranger Things: warm amber highlights with teal shadow split — Kodachrome
            // film emulation, vivid 80s palette, synthwave teal in the darks.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Boost red for warm skin/amber highlights; slight green cross-bleed for warmth
            matrix.rVector = CIVector(x: 1.06, y: 0.07, z: 0.0, w: 0.0)
            // Slight red contribution; reduce green slightly (faded film stock)
            matrix.gVector = CIVector(x: 0.04, y: 0.93, z: 0.02, w: 0.0)
            // Teal shadow push: bleed green into blue channel, suppress pure blue
            matrix.bVector = CIVector(x: 0.0, y: 0.14, z: 0.80, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Warm lifted shadows (amber bias), slight teal pull in blue channel
            matrix.biasVector = CIVector(x: 0.030, y: 0.014, z: -0.010, w: 0.0)
            var output = matrix.outputImage ?? image

            // Vivid 80s film saturation — notably high, Kodachrome-like
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.05
            controls.contrast = 1.18
            controls.brightness = -0.01
            output = controls.outputImage ?? output

            // Warm but not overpowering — 5500K keeps it amber without going full orange
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5500, y: 8)
            return temp.outputImage ?? output

        case .dune:
            // Dune: dusty amber highlights, muted palette, cool shadow separation.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: 1.06, y: 0.08, z: 0.00, w: 0.0)
            matrix.gVector = CIVector(x: 0.08, y: 0.98, z: 0.02, w: 0.0)
            matrix.bVector = CIVector(x: 0.00, y: 0.10, z: 0.76, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            matrix.biasVector = CIVector(x: 0.015, y: 0.006, z: -0.012, w: 0.0)
            var output = matrix.outputImage ?? image

            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.78
            controls.contrast = 1.17
            controls.brightness = -0.02
            output = controls.outputImage ?? output

            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5100, y: -8)
            output = temperature.outputImage ?? output

            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.14
            shadowHighlight.highlightAmount = 0.90
            return shadowHighlight.outputImage ?? output

        case .drive:
            // Drive: neon magenta-cyan split with dense blacks and glossy highlights.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: 1.10, y: 0.03, z: 0.08, w: 0.0)
            matrix.gVector = CIVector(x: 0.02, y: 0.90, z: 0.08, w: 0.0)
            matrix.bVector = CIVector(x: 0.02, y: 0.12, z: 1.02, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            matrix.biasVector = CIVector(x: 0.006, y: -0.002, z: 0.012, w: 0.0)
            var output = matrix.outputImage ?? image

            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.20
            controls.contrast = 1.28
            controls.brightness = -0.01
            output = controls.outputImage ?? output

            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 7300, y: 24)
            output = temperature.outputImage ?? output

            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.22
            shadowHighlight.highlightAmount = 1.04
            return shadowHighlight.outputImage ?? output

        case .madMax:
            // Mad Max Fury Road: hard orange/teal split, high micro-contrast, scorched feel.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: 1.18, y: 0.12, z: 0.00, w: 0.0)
            matrix.gVector = CIVector(x: 0.04, y: 0.92, z: 0.06, w: 0.0)
            matrix.bVector = CIVector(x: 0.00, y: 0.16, z: 0.74, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            matrix.biasVector = CIVector(x: 0.028, y: 0.010, z: -0.020, w: 0.0)
            var output = matrix.outputImage ?? image

            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.13
            controls.contrast = 1.36
            controls.brightness = -0.03
            output = controls.outputImage ?? output

            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 4700, y: 6)
            output = temperature.outputImage ?? output

            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.30
            shadowHighlight.highlightAmount = 0.82
            return shadowHighlight.outputImage ?? output

        case .revenant:
            // The Revenant: cold naturalism, restrained saturation, textured mids.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: 0.86, y: 0.06, z: 0.06, w: 0.0)
            matrix.gVector = CIVector(x: 0.02, y: 0.96, z: 0.08, w: 0.0)
            matrix.bVector = CIVector(x: 0.00, y: 0.10, z: 1.01, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            matrix.biasVector = CIVector(x: -0.004, y: 0.002, z: 0.010, w: 0.0)
            var output = matrix.outputImage ?? image

            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.73
            controls.contrast = 1.10
            controls.brightness = -0.025
            output = controls.outputImage ?? output

            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 7000, y: -3)
            output = temperature.outputImage ?? output

            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.08
            shadowHighlight.highlightAmount = 0.94
            return shadowHighlight.outputImage ?? output

        case .inTheMoodForLove:
            // In the Mood for Love: rich tungsten reds and greens with soft highlight bloom.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: 1.12, y: 0.08, z: 0.00, w: 0.0)
            matrix.gVector = CIVector(x: 0.09, y: 0.95, z: 0.02, w: 0.0)
            matrix.bVector = CIVector(x: 0.00, y: 0.11, z: 0.76, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            matrix.biasVector = CIVector(x: 0.016, y: 0.006, z: -0.008, w: 0.0)
            var output = matrix.outputImage ?? image

            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.01
            controls.contrast = 1.10
            controls.brightness = -0.01
            output = controls.outputImage ?? output

            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5200, y: 18)
            output = temperature.outputImage ?? output

            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = 0.04
            shadowHighlight.highlightAmount = 0.90
            return shadowHighlight.outputImage ?? output

        case .seven:
            // Se7en (1995) — Darius Khondji's CCE bleach-bypass look:
            // desaturated cyan-tinted shadows, crushed blacks, high micro-contrast,
            // narrow highlight range, gritty "Dark Clarity" aesthetic.
            // Pushed+flashed stock + bleach bypass = saturation pulled back, contrast up,
            // pervasive sickly cyan undercast in shadows and mids.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Red channel: suppressed — contributes to the desaturated, anemic look
            matrix.rVector = CIVector(x: 0.82, y: 0.06, z: 0.06, w: 0.0)
            // Green channel: slight boost, cross-bleed into blue for cyan quality
            matrix.gVector = CIVector(x: 0.04, y: 0.96, z: 0.08, w: 0.0)
            // Blue channel: prominent — creates the pervasive cyan shadow cast
            matrix.bVector = CIVector(x: 0.00, y: 0.14, z: 1.04, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Cyan/blue lift in shadows (the "rot and decay" undercast)
            matrix.biasVector = CIVector(x: -0.008, y: 0.004, z: 0.018, w: 0.0)
            var output = matrix.outputImage ?? image

            // Bleach bypass: strong desaturation, high contrast (narrow dynamic range)
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.58
            controls.contrast = 1.38
            controls.brightness = -0.03
            output = controls.outputImage ?? output

            // Cool temperature shift — the city is wet, cold, grey
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5000, y: -18)
            output = temperature.outputImage ?? output

            // Crush shadows hard (CCE process), soft highlight rolloff (flashing effect)
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.45
            shadowHighlight.highlightAmount = 0.78
            return shadowHighlight.outputImage ?? output

        case .vertigo:
            // Vertigo (1958) — Robert Burks, Technicolor dye-transfer:
            // Rich saturated reds (obsession, death) and deep mysterious greens (Madeleine),
            // dreamlike fog-filtered warmth, chiaroscuro contrast, golden-era Hollywood palette.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Boost red for the fatalistic reds (robes, restaurant backdrop, staircase)
            matrix.rVector = CIVector(x: 1.14, y: 0.06, z: 0.00, w: 0.0)
            // Enrich greens (Madeleine's mysterious green — mystery and deception)
            matrix.gVector = CIVector(x: 0.04, y: 1.08, z: 0.02, w: 0.0)
            // Suppress blue slightly for the warm Technicolor period look
            matrix.bVector = CIVector(x: 0.00, y: 0.08, z: 0.72, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Warm golden lift — Technicolor prints had a beautiful warmth in mids
            matrix.biasVector = CIVector(x: 0.018, y: 0.010, z: -0.006, w: 0.0)
            var output = matrix.outputImage ?? image

            // Vivid but not over-saturated — Technicolor was rich, not garish
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.18
            controls.contrast = 1.14
            controls.brightness = 0.01
            output = controls.outputImage ?? output

            // Slightly warm — Technicolor had a golden warmth, fog-filtered on location
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5600, y: 12)
            output = temperature.outputImage ?? output

            // Hold shadow detail (chiaroscuro: meaningful shadow) with soft highlights
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = 0.06
            shadowHighlight.highlightAmount = 0.86
            return shadowHighlight.outputImage ?? output

        case .orderOfPhoenix:
            // Harry Potter – Order of the Phoenix (2007) — David Yates / Slawomir Idziak:
            // Heavy blue-teal grade (fan editors describe it as "blue cast bleeds over everything"),
            // dark crushed shadows, desaturated mids — Umbridge's pink becomes lavender.
            // "A dimmer heading downward" — growing threat of Voldemort visualised as blue-green.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Red suppressed — warms and pinks lose their punch, become muted
            matrix.rVector = CIVector(x: 0.84, y: 0.06, z: 0.04, w: 0.0)
            // Green slight boost into the teal direction
            matrix.gVector = CIVector(x: 0.03, y: 0.94, z: 0.08, w: 0.0)
            // Blue strongly dominant — the heavy blue cast that defines this film
            matrix.bVector = CIVector(x: 0.00, y: 0.18, z: 1.06, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Cold blue shadow lift
            matrix.biasVector = CIVector(x: -0.010, y: 0.002, z: 0.022, w: 0.0)
            var output = matrix.outputImage ?? image

            // Dark and desaturated — muted, oppressive atmosphere
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.72
            controls.contrast = 1.22
            controls.brightness = -0.03
            output = controls.outputImage ?? output

            // Very cool temperature — the Ministry of Magic corridors are ice-cold
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 4800, y: -14)
            output = temperature.outputImage ?? output

            // Dark overall — roughly half stop under, adds to oppressive feel
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = output
            exposureFilter.ev = -0.35
            output = exposureFilter.outputImage ?? output

            // Crushed blacks, restrained highlights
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.35
            shadowHighlight.highlightAmount = 0.88
            return shadowHighlight.outputImage ?? output

        case .hero:
            // Hero (2002) — Zhang Yimou / Christopher Doyle:
            // The film is structured around bold saturated color chapters (red, blue, white, green).
            // This preset channels the dominant red chapter — Zhang hand-graded every leaf —
            // with the underlying saturated primaries and epic high-contrast quality.
            // Deeply saturated, rich crimson/red warmth, dramatic contrast, bold color separation.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Powerful red boost — the signature of the red chapter, blood crimson to fiery scarlet
            matrix.rVector = CIVector(x: 1.22, y: 0.06, z: 0.00, w: 0.0)
            // Rich green maintained — the green flashback chapter's jade quality bleeds in
            matrix.gVector = CIVector(x: 0.04, y: 1.02, z: 0.02, w: 0.0)
            // Blue pulled back slightly — keeps reds warm, prevents purple cast
            matrix.bVector = CIVector(x: 0.00, y: 0.08, z: 0.78, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Warm red-orange lift — the fiery crimson autumn leaves
            matrix.biasVector = CIVector(x: 0.022, y: 0.004, z: -0.014, w: 0.0)
            var output = matrix.outputImage ?? image

            // Pushed to the saturation limit (as described by colorist Al Hansen)
            // Bold primaries without losing detail — "reds with weight"
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.42
            controls.contrast = 1.26
            controls.brightness = -0.01
            output = controls.outputImage ?? output

            // Warm — the film's color temperature in the red chapter is fiery
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5000, y: 10)
            output = temperature.outputImage ?? output

            // Anamorphic Cooke lens quality — hold shadows, wide latitude in highlights
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.10
            shadowHighlight.highlightAmount = 0.88
            return shadowHighlight.outputImage ?? output

        case .laLaLand:
            // La La Land (2016) — Linus Sandgren, ASC (Academy Award winner):
            // Shot on 35mm with pull-processing (overexposed 1⅓ stops, underdeveloped).
            // "A dream of Los Angeles rather than the real thing" — pastel blues, pinks, purples
            // at magic hour. Soft elegant grain, immature blacks, fine tonal detail in highlights.
            // Inspired by Technicolor classics and Jacques Demy's Umbrellas of Cherbourg.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Soft warm reds — romantic, slightly desaturated (pull-processed film character)
            matrix.rVector = CIVector(x: 1.06, y: 0.06, z: 0.02, w: 0.0)
            // Balanced greens — doesn't compete with pinks/purples
            matrix.gVector = CIVector(x: 0.04, y: 0.96, z: 0.06, w: 0.0)
            // Slightly enhanced blue for the dreamy blue/purple magic hour quality
            matrix.bVector = CIVector(x: 0.02, y: 0.10, z: 0.94, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Pastel lift — pull-processed film has lifted blacks ("immature blacks")
            // warm pink bias + cool blue bias creates the pastel multicolor quality
            matrix.biasVector = CIVector(x: 0.022, y: 0.014, z: 0.020, w: 0.0)
            var output = matrix.outputImage ?? image

            // Pull-processing: lower contrast, protected highlights, soft grain structure
            // "clean, soft, elegant colourful image... a bit like Kodachrome, but less contrast"
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.08
            controls.contrast = 1.02
            controls.brightness = 0.02
            output = controls.outputImage ?? output

            // Magic hour warmth — mercury vapour blues mixed with warm practical lamps
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5800, y: 14)
            output = temperature.outputImage ?? output

            // Protected highlights (pull process detail), lifted shadows (pastel / dream quality)
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = 0.12
            shadowHighlight.highlightAmount = 0.80
            return shadowHighlight.outputImage ?? output
        }
    }

    private struct FilmFinishSettings {
        let grainAmount: CGFloat
        let grainSize: CGFloat
        let vignetteStrength: CGFloat
        let vignetteSoftness: CGFloat
        let chromaticAberration: CGFloat
        let bloomIntensity: CGFloat
        let bloomRadius: CGFloat
    }

    nonisolated private static func applyPresetFinish(_ preset: MoviePreset, to image: CIImage) -> CIImage {
        guard let settings = filmFinishSettings(for: preset) else { return image }

        var output = image
        output = applyBloom(to: output, intensity: settings.bloomIntensity, radius: settings.bloomRadius)
        output = applyVignette(to: output, strength: settings.vignetteStrength, softness: settings.vignetteSoftness)
        output = applyChromaticAberration(to: output, amount: settings.chromaticAberration)
        output = applyFilmGrain(to: output, amount: settings.grainAmount, size: settings.grainSize)

        return output.cropped(to: image.extent)
    }

    nonisolated private static func filmFinishSettings(for preset: MoviePreset) -> FilmFinishSettings? {
        switch preset {
        case .dune:
            return FilmFinishSettings(
                grainAmount: 0.06,
                grainSize: 1.30,
                vignetteStrength: 0.14,
                vignetteSoftness: 0.82,
                chromaticAberration: 0.0,
                bloomIntensity: 0.18,
                bloomRadius: 8.0
            )
        case .drive:
            return FilmFinishSettings(
                grainAmount: 0.08,
                grainSize: 1.10,
                vignetteStrength: 0.20,
                vignetteSoftness: 0.70,
                chromaticAberration: 0.0,
                bloomIntensity: 0.30,
                bloomRadius: 10.0
            )
        case .madMax:
            return FilmFinishSettings(
                grainAmount: 0.04,
                grainSize: 1.00,
                vignetteStrength: 0.18,
                vignetteSoftness: 0.62,
                chromaticAberration: 0.0,
                bloomIntensity: 0.10,
                bloomRadius: 6.0
            )
        case .revenant:
            return FilmFinishSettings(
                grainAmount: 0.0,
                grainSize: 1.35,
                vignetteStrength: 0.08,
                vignetteSoftness: 0.78,
                chromaticAberration: 0.0,
                bloomIntensity: 0.06,
                bloomRadius: 5.0
            )
        case .inTheMoodForLove:
            return FilmFinishSettings(
                grainAmount: 0.08,
                grainSize: 1.40,
                vignetteStrength: 0.22,
                vignetteSoftness: 0.74,
                chromaticAberration: 0.0,
                bloomIntensity: 0.24,
                bloomRadius: 11.0
            )
        case .seven:
            // Heavy photochemical grain (pushed 1 stop + CCE process),
            // strong vignette (practical lighting sources, dark corners),
            // chromatic aberration (vintage glass, atmospheric city haze),
            // no bloom — this film is all darkness and grit
            return FilmFinishSettings(
                grainAmount: 0.22,
                grainSize: 1.80,
                vignetteStrength: 0.32,
                vignetteSoftness: 0.58,
                chromaticAberration: 1.4,
                bloomIntensity: 0.0,
                bloomRadius: 0.0
            )
        case .vertigo:
            // Fine Technicolor grain structure, dreamy soft vignette (fog filters on location),
            // subtle chromatic aberration (period glass lenses), soft bloom for the dreamlike quality
            return FilmFinishSettings(
                grainAmount: 0.10,
                grainSize: 1.20,
                vignetteStrength: 0.16,
                vignetteSoftness: 0.88,
                chromaticAberration: 0.6,
                bloomIntensity: 0.14,
                bloomRadius: 9.0
            )
        case .orderOfPhoenix:
            // Moderate grain (ARRI cameras, digital but moody),
            // deep vignette (dark cramped frames),
            // slight CA (theatrical handheld tension lenses), no bloom
            return FilmFinishSettings(
                grainAmount: 0.09,
                grainSize: 1.10,
                vignetteStrength: 0.26,
                vignetteSoftness: 0.64,
                chromaticAberration: 0.5,
                bloomIntensity: 0.0,
                bloomRadius: 0.0
            )
        case .hero:
            // Minimal grain — crisp Arri 535 anamorphic, clean image,
            // very slight vignette (anamorphic lens fall-off at edges),
            // no CA — the primary colors are meant to be pure and vivid,
            // subtle bloom on highlights (the silk-and-fire aesthetics)
            return FilmFinishSettings(
                grainAmount: 0.03,
                grainSize: 0.90,
                vignetteStrength: 0.10,
                vignetteSoftness: 0.84,
                chromaticAberration: 0.0,
                bloomIntensity: 0.16,
                bloomRadius: 7.0
            )
        case .laLaLand:
            // Fine elegant grain (35mm pull-processed — "fine grain structures"),
            // soft gentle vignette (anamorphic 2.55:1 edges, theatrical),
            // subtle CA (Panavision anamorphic modified lenses),
            // warm soft bloom (the luminous Sandgren look, hidden lights behind trees)
            return FilmFinishSettings(
                grainAmount: 0.12,
                grainSize: 1.15,
                vignetteStrength: 0.13,
                vignetteSoftness: 0.90,
                chromaticAberration: 0.4,
                bloomIntensity: 0.20,
                bloomRadius: 12.0
            )
        default:
            return nil
        }
    }

    nonisolated private static func applyBloom(to image: CIImage, intensity: CGFloat, radius: CGFloat) -> CIImage {
        guard intensity > 0.001, radius > 0.001 else { return image }
        let bloom = CIFilter.bloom()
        bloom.inputImage = image
        bloom.intensity = Float(intensity)
        bloom.radius = Float(radius)
        return bloom.outputImage?.cropped(to: image.extent) ?? image
    }

    nonisolated private static func applyVignette(to image: CIImage, strength: CGFloat, softness: CGFloat) -> CIImage {
        guard strength > 0.001 else { return image }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        let soft = min(max(softness, 0.0), 1.0)
        let minDimension = min(extent.width, extent.height)
        let radius0 = minDimension * (0.35 + 0.22 * soft)
        let radius1 = minDimension * 0.96
        let edgeLuma = max(0.45, 1.0 - strength * 0.58)

        guard let mask = radialMask(
            extent: extent,
            radius0: radius0,
            radius1: radius1,
            innerLuma: 1.0,
            outerLuma: edgeLuma
        ) else {
            return image
        }

        guard let multiply = CIFilter(name: "CIMultiplyCompositing") else { return image }
        multiply.setValue(mask, forKey: kCIInputImageKey)
        multiply.setValue(image, forKey: kCIInputBackgroundImageKey)
        return multiply.outputImage?.cropped(to: extent) ?? image
    }

    nonisolated private static func applyChromaticAberration(to image: CIImage, amount: CGFloat) -> CIImage {
        guard amount > 0.001 else { return image }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        let minDimension = min(extent.width, extent.height)
        let shiftScale = max(1.0, minDimension / 1600.0)
        let shift = amount * shiftScale
        let verticalShift = shift * 0.25

        let clamped = image.clampedToExtent()
        let redSource = clamped
            .transformed(by: .init(translationX: shift, y: verticalShift))
            .cropped(to: extent)
        let blueSource = clamped
            .transformed(by: .init(translationX: -shift, y: -verticalShift))
            .cropped(to: extent)

        let redChannel = isolateChannel(redSource, red: 1, green: 0, blue: 0)
        let greenChannel = isolateChannel(image, red: 0, green: 1, blue: 0)
        let blueChannel = isolateChannel(blueSource, red: 0, green: 0, blue: 1)

        let rg = additionComposite(redChannel, over: greenChannel)
        let rgb = additionComposite(blueChannel, over: rg).cropped(to: extent)

        let spread = min(max(amount / 1.2, 0.0), 1.0)
        let maskRadius0 = minDimension * (0.56 - 0.14 * spread)
        let maskRadius1 = minDimension * (0.92 - 0.04 * spread)

        guard let edgeMask = radialMask(
            extent: extent,
            radius0: maskRadius0,
            radius1: maskRadius1,
            innerLuma: 0.0,
            outerLuma: 1.0
        ) else {
            return rgb
        }

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return rgb }
        blend.setValue(rgb, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(edgeMask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: extent) ?? rgb
    }

    nonisolated private static func applyFilmGrain(to image: CIImage, amount: CGFloat, size: CGFloat) -> CIImage {
        guard amount > 0.001 else { return image }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }
        guard let randomNoise = CIFilter.randomGenerator().outputImage else { return image }

        let grainSize = min(max(size, 0.7), 2.4)
        var noise = randomNoise
            .transformed(by: .init(scaleX: 1.0 / grainSize, y: 1.0 / grainSize))
            .cropped(to: extent)

        let mono = CIFilter.colorControls()
        mono.inputImage = noise
        mono.saturation = 0
        mono.contrast = 1.75
        mono.brightness = 0
        noise = mono.outputImage ?? noise

        let blurRadius = max(0.0, (grainSize - 1.0) * 0.35)
        if blurRadius > 0.001 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = noise
            blur.radius = Float(blurRadius)
            noise = (blur.outputImage ?? noise).cropped(to: extent)
        }

        let alphaMapped = CIFilter.colorMatrix()
        alphaMapped.inputImage = noise
        alphaMapped.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        alphaMapped.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        alphaMapped.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        alphaMapped.aVector = CIVector(x: 0, y: 0, z: 0, w: min(max(amount, 0.0), 0.45))
        noise = alphaMapped.outputImage ?? noise

        guard let overlay = CIFilter(name: "CIOverlayBlendMode") else { return image }
        overlay.setValue(noise, forKey: kCIInputImageKey)
        overlay.setValue(image, forKey: kCIInputBackgroundImageKey)
        return overlay.outputImage?.cropped(to: extent) ?? image
    }

    nonisolated private static func isolateChannel(_ image: CIImage, red: CGFloat, green: CGFloat, blue: CGFloat) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: red, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: green, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: blue, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage ?? image
    }

    nonisolated private static func additionComposite(_ image: CIImage, over background: CIImage) -> CIImage {
        guard let add = CIFilter(name: "CIAdditionCompositing") else { return background }
        add.setValue(image, forKey: kCIInputImageKey)
        add.setValue(background, forKey: kCIInputBackgroundImageKey)
        return add.outputImage ?? background
    }

    nonisolated private static func radialMask(
        extent: CGRect,
        radius0: CGFloat,
        radius1: CGFloat,
        innerLuma: CGFloat,
        outerLuma: CGFloat
    ) -> CIImage? {
        guard let radial = CIFilter(name: "CIRadialGradient") else { return nil }
        radial.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        radial.setValue(radius0, forKey: "inputRadius0")
        radial.setValue(radius1, forKey: "inputRadius1")
        radial.setValue(CIColor(red: innerLuma, green: innerLuma, blue: innerLuma, alpha: 1), forKey: "inputColor0")
        radial.setValue(CIColor(red: outerLuma, green: outerLuma, blue: outerLuma, alpha: 1), forKey: "inputColor1")
        return radial.outputImage?.cropped(to: extent)
    }

    // MARK: - Sin City red mask

    /// 64³ colour cube data for the red-hue mask used by Sin City preset.
    nonisolated(unsafe) private static var sinCityColorCubeData: Data = {
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

    nonisolated private static func sinCityRedMask(image: CIImage) -> CIImage {
        let size = 64
        let cube = CIFilter(name: "CIColorCube")!
        cube.setValue(size, forKey: "inputCubeDimension")
        cube.setValue(sinCityColorCubeData, forKey: "inputCubeData")
        cube.setValue(image, forKey: kCIInputImageKey)
        return cube.outputImage ?? image
    }

    /// Crops to `targetRatio`. Auto-swaps orientation to match image unless `forceHorizontal`.
    /// `offset` is normalized –1…+1 panning within the available slack.
    nonisolated private static func offsetCrop(image: CIImage, targetRatio: CGFloat, forceHorizontal: Bool, offset: CGSize) -> CIImage {
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
