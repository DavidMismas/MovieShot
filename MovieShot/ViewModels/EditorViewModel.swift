import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorViewModel: ObservableObject {
    private enum PreferenceKey {
        static let exportJPEGQualityPercent = "editor.exportJPEGQualityPercent"
    }

    @Published var step: EditorStep = .source {
        didSet {
            if step == .preset {
                resetAdjustmentsForPresetPreview()
            }
        }
    }
    /// Full-resolution source image, used for final export.
    private var fullResSourceImage: UIImage?
    /// Optional RAW source data for highest-quality final export render.
    private var rawSourceData: Data?
    /// Controls whether full-resolution export should be developed from RAW.
    private var useRAWSourceForExport = true
    /// Downscaled source image used for interactive editing preview.
    @Published var sourceImage: UIImage? {
        didSet { applyEdits() }
    }
    @Published var editedImage: UIImage?
    @Published var selectedPreset: MoviePreset = .matrix {
        didSet {
            if isPresetApplied {
                applyEdits()
            }
        }
    }
    @Published private(set) var isPresetApplied = false
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
    @Published var exportJPEGQualityPercent: Int = 95 {
        didSet {
            let normalized = Self.normalizedJPEGQualityPercent(exportJPEGQualityPercent)
            if exportJPEGQualityPercent != normalized {
                exportJPEGQualityPercent = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: PreferenceKey.exportJPEGQualityPercent)
        }
    }

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
        let applyPreset: Bool
        let exposure: Double
        let contrast: Double
        let shadows: Double
        let highlights: Double
        let cropOption: CropOption
        let cropOffset: CGSize
    }

    init() {
        let storedJPEGQuality = UserDefaults.standard.object(forKey: PreferenceKey.exportJPEGQualityPercent) as? Int ?? 95
        let normalizedJPEGQuality = Self.normalizedJPEGQualityPercent(storedJPEGQuality)
        exportJPEGQualityPercent = normalizedJPEGQuality
        UserDefaults.standard.set(normalizedJPEGQuality, forKey: PreferenceKey.exportJPEGQualityPercent)

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
        guard cameraService.isSessionRunning else { return }
        statusMessage = nil
        showPresetLoading = true
        cameraService.capturePhoto()
    }

    func setSourceImage(_ image: UIImage, rawData: Data? = nil, useRAWForExport: Bool = true) {
        loadingTask?.cancel()
        invalidatePreviewRenders()
        rawSourceData = rawData
        useRAWSourceForExport = useRAWForExport
        showPresetLoading = true

        let ciContext = self.ciContext
        loadingTask = Task.detached(priority: .userInitiated) {
            let worker = ImageWorker(context: ciContext)
            let normalized = await worker.normalizedUpOrientation(for: image)
            let fullRes = await worker.downscaled(image: normalized, maxDimension: 4032)
            let preview = await worker.downscaled(image: normalized, maxDimension: 1800)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fullResSourceImage = fullRes
                self.isPresetApplied = false
                // Show the captured frame immediately, then replace it once the preset render finishes.
                self.editedImage = preview
                self.sourceImage = preview

                self.cameraService.stopSession()
                self.showPresetLoading = false
                self.step = .preset
                self.loadingTask = nil
            }
        }
    }

    func continueStep() {
        guard let next = EditorStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func selectPreset(_ preset: MoviePreset) {
        if !isPresetApplied {
            isPresetApplied = true
            if selectedPreset != preset {
                selectedPreset = preset
            } else {
                applyEdits()
            }
            return
        }

        selectedPreset = preset
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
        rawSourceData = nil
        useRAWSourceForExport = true
        sourceImage = nil
        editedImage = nil
        selectedPreset = .matrix
        isPresetApplied = false
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

    /// Renders the current edits at full resolution for export.
    /// Prefers RAW source for maximum quality.
    func renderFullResolution() -> UIImage? {
        let inputImage: CIImage
        if useRAWSourceForExport,
           let rawSourceData,
           let ci = makeCIImageFromRAWData(rawSourceData) {
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
                applyPreset: isPresetApplied,
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
        guard let image = renderFullResolution(),
              let exportResource = makeBestQualityJPEGResource(from: image)
        else { return }
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
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = exportResource.uniformTypeIdentifier
                request.addResource(with: .photo, data: exportResource.data, options: options)
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

    private func makeBestQualityJPEGResource(from image: UIImage) -> (data: Data, uniformTypeIdentifier: String)? {
        let compressionQuality = CGFloat(exportJPEGQualityPercent) / 100.0
        if let jpegData = image.jpegData(compressionQuality: compressionQuality) {
            return (data: jpegData, uniformTypeIdentifier: UTType.jpeg.identifier)
        }

        return nil
    }

    private static func normalizedJPEGQualityPercent(_ value: Int) -> Int {
        let clamped = min(max(value, 70), 100)
        let stepped = Int((Double(clamped) / 5.0).rounded()) * 5
        return min(max(stepped, 70), 100)
    }

    private func handleCameraCaptureResult(_ result: CameraCaptureResult) {
        if let processedData = result.processedData,
           let image = UIImage(data: processedData) {
            // Pure RAW capture can look overexposed when developed via CIRAWFilter.
            // Keep RAW data, but export from processed source for WYSIWYG parity.
            let useRAWForExport = cameraService.captureFormat != .pureRAW
            setSourceImage(image, rawData: result.rawData, useRAWForExport: useRAWForExport)
            return
        }

        if let rawData = result.rawData,
           let previewImage = makePreviewImageFromRAWData(rawData) {
            setSourceImage(previewImage, rawData: rawData)
            return
        }

        showPresetLoading = false
        statusMessage = "Photo capture failed."
    }

    private func makeCIImageFromRAWData(_ data: Data) -> CIImage? {
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

    private func makePreviewImageFromRAWData(_ data: Data, maxDimension: CGFloat = 2200) -> UIImage? {
        guard let ci = makeCIImageFromRAWData(data) else { return nil }
        guard ci.extent.width > 0, ci.extent.height > 0 else { return nil }

        let maxSide = max(ci.extent.width, ci.extent.height)
        let scale = min(1.0, maxDimension / maxSide)
        let previewCIImage: CIImage
        if scale < 0.999 {
            previewCIImage = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            previewCIImage = ci
        }

        guard let cgImage = ciContext.createCGImage(previewCIImage, from: previewCIImage.extent.integral) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
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

    private func resetAdjustmentsForPresetPreview() {
        let hasManualAdjustments =
            abs(exposure) > 0.0001 ||
            abs(contrast) > 0.0001 ||
            abs(shadows) > 0.0001 ||
            abs(highlights) > 0.0001

        guard hasManualAdjustments else { return }
        exposure = 0.0
        contrast = 0.0
        shadows = 0.0
        highlights = 0.0
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
            applyPreset: isPresetApplied,
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
                applyPreset: request.applyPreset,
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
        applyPreset: Bool,
        exposure: Double,
        contrast: Double,
        shadows: Double,
        highlights: Double,
        cropOption: CropOption,
        cropOffset: CGSize
    ) -> CIImage {
        var output = inputImage
        if applyPreset {
            output = applyMoviePreset(preset, to: output)
            output = applyFlatBaselineTone(to: output, preset: preset)
        }

        if abs(exposure) > 0.0001 {
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = output
            exposureFilter.ev = Float(exposure)
            output = exposureFilter.outputImage ?? output
        }

        // contrast slider: 0 = neutral (1.0), -1 = 0.5, +1 = 1.5
        if abs(contrast) > 0.0001 {
            let contrastFilter = CIFilter.colorControls()
            contrastFilter.inputImage = output
            contrastFilter.contrast = Float(1.0 + contrast * 0.5)
            output = contrastFilter.outputImage ?? output
        }

        // shadows: slider 0 = neutral, -1…+1 maps directly to filter shadowAmount
        // highlights: slider 0 = neutral (filter 1.0), -1 = 0, +1 = 2
        if abs(shadows) > 0.0001 || abs(highlights) > 0.0001 {
            let shadowHighlightFilter = CIFilter.highlightShadowAdjust()
            shadowHighlightFilter.inputImage = output
            shadowHighlightFilter.shadowAmount = Float(shadows)
            shadowHighlightFilter.highlightAmount = Float(1.0 + highlights)
            output = shadowHighlightFilter.outputImage ?? output
        }

        if let ratio = cropOption.ratio {
            output = offsetCrop(image: output, targetRatio: ratio, forceHorizontal: cropOption.forceHorizontal, offset: cropOffset)
        }

        if applyPreset {
            output = applyPresetFinish(preset, to: output)
        }

        return output
    }

    private struct FlatBaselineSettings {
        let shadowLift: CGFloat
        let highlightRollOff: CGFloat
        let blackLift: CGFloat
        let contrast: CGFloat
    }

    nonisolated private static func flatBaselineSettings(for preset: MoviePreset) -> FlatBaselineSettings {
        switch preset {
        case .sinCity, .theBatman, .drive, .madMax, .seven, .orderOfPhoenix:
            // Dark presets need a larger toe lift so blacks stay editable.
            return FlatBaselineSettings(shadowLift: 0.26, highlightRollOff: 0.96, blackLift: 0.032, contrast: 1.00)
        case .matrix, .bladeRunner2049, .dune, .revenant, .hero:
            return FlatBaselineSettings(shadowLift: 0.20, highlightRollOff: 0.97, blackLift: 0.024, contrast: 1.03)
        default:
            return FlatBaselineSettings(shadowLift: 0.14, highlightRollOff: 0.98, blackLift: 0.018, contrast: 1.06)
        }
    }

    nonisolated private static func applyFlatBaselineTone(to image: CIImage, preset: MoviePreset) -> CIImage {
        let settings = flatBaselineSettings(for: preset)
        var output = image

        let shadowHighlight = CIFilter.highlightShadowAdjust()
        shadowHighlight.inputImage = output
        shadowHighlight.shadowAmount = Float(settings.shadowLift)
        shadowHighlight.highlightAmount = Float(settings.highlightRollOff)
        output = shadowHighlight.outputImage ?? output

        if let toneCurve = CIFilter(name: "CIToneCurve") {
            toneCurve.setValue(output, forKey: kCIInputImageKey)
            toneCurve.setValue(CIVector(x: 0.00, y: settings.blackLift), forKey: "inputPoint0")
            toneCurve.setValue(CIVector(x: 0.25, y: 0.25 + settings.blackLift * 0.6), forKey: "inputPoint1")
            toneCurve.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
            toneCurve.setValue(CIVector(x: 0.75, y: 0.75 - settings.blackLift * 0.2), forKey: "inputPoint3")
            toneCurve.setValue(CIVector(x: 1.00, y: 1.00), forKey: "inputPoint4")
            output = toneCurve.outputImage ?? output
        }

        let controls = CIFilter.colorControls()
        controls.inputImage = output
        controls.contrast = Float(settings.contrast)
        controls.brightness = Float(settings.blackLift * 0.35)
        output = controls.outputImage ?? output

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
            controls.contrast = 1.08
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
            controls.contrast = 1.10
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
            bwControls.contrast = 1.30
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
            controls.contrast = 1.10
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
            controls.contrast = 1.10
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
            controls.contrast = 1.12
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
            controls.contrast = 1.13
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
            controls.contrast = 1.15
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
            // Se7en (1995) — Darius Khondji, bleach bypass / CCE process.
            // Desaturated, cyan-green shadows, narrow tonal range, gritty mids.
            // Calibrated like Revenant/Batman: visible but not clipped.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Red pulled back — the anemic, washed-out skin tones of the film
            matrix.rVector = CIVector(x: 0.88, y: 0.05, z: 0.04, w: 0.0)
            // Green neutral — slight bleed into blue for the cyan undercast
            matrix.gVector = CIVector(x: 0.03, y: 0.96, z: 0.06, w: 0.0)
            // Blue slightly lifted — creates the pervasive cold cyan shadow quality
            matrix.bVector = CIVector(x: 0.00, y: 0.08, z: 0.96, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Cold blue lift in shadows — the "rot and decay" undercast
            matrix.biasVector = CIVector(x: -0.005, y: 0.002, z: 0.010, w: 0.0)
            var output = matrix.outputImage ?? image

            // Bleach bypass character: desaturated, slightly lifted contrast
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.68
            controls.contrast = 1.16
            controls.brightness = -0.02
            output = controls.outputImage ?? output

            // Cold wet city — cool temperature, slight green tint
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5200, y: -12)
            output = temperature.outputImage ?? output

            // Slightly crushed shadows, restrained highlights (flashing effect)
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.18
            shadowHighlight.highlightAmount = 0.88
            return shadowHighlight.outputImage ?? output

        case .vertigo:
            // Vertigo (1958) — Robert Burks, VistaVision / Technicolor dye-transfer.
            // Rich reds (obsession/death) and deep greens (Madeleine/mystery),
            // warm golden Technicolor mids, soft fog-filtered dreamlike quality.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Boost red — the fatalistic reds (robes, restaurant backdrop)
            matrix.rVector = CIVector(x: 1.08, y: 0.05, z: 0.00, w: 0.0)
            // Enrich greens — Madeleine's mysterious jade quality
            matrix.gVector = CIVector(x: 0.04, y: 1.04, z: 0.02, w: 0.0)
            // Suppress blue slightly for warm Technicolor period character
            matrix.bVector = CIVector(x: 0.00, y: 0.06, z: 0.80, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Warm golden lift in mids — Technicolor prints had a beautiful warmth
            matrix.biasVector = CIVector(x: 0.010, y: 0.006, z: -0.004, w: 0.0)
            var output = matrix.outputImage ?? image

            // Vivid but not oversaturated — Technicolor was rich, not garish
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.14
            controls.contrast = 1.12
            controls.brightness = 0.01
            output = controls.outputImage ?? output

            // Slightly warm — Technicolor had a golden warmth, fog filters on location
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5700, y: 10)
            output = temperature.outputImage ?? output

            // Hold shadow detail (chiaroscuro), soft highlight rolloff
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = 0.06
            shadowHighlight.highlightAmount = 0.88
            return shadowHighlight.outputImage ?? output

        case .orderOfPhoenix:
            // Harry Potter – Order of the Phoenix (2007) — David Yates / Slawomir Idziak.
            // Heavy blue-teal cast, desaturated mids, oppressive dark atmosphere.
            // Calibrated like The Batman: visible cool cast without clipping.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Red suppressed — pinks lose punch, skin tones go muted/grey
            matrix.rVector = CIVector(x: 0.88, y: 0.05, z: 0.03, w: 0.0)
            // Green slight teal push via blue bleed
            matrix.gVector = CIVector(x: 0.02, y: 0.95, z: 0.06, w: 0.0)
            // Blue dominant — the heavy blue cast that defines this film
            matrix.bVector = CIVector(x: 0.00, y: 0.10, z: 1.00, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Cold blue shadow lift
            matrix.biasVector = CIVector(x: -0.006, y: 0.001, z: 0.012, w: 0.0)
            var output = matrix.outputImage ?? image

            // Desaturated and slightly dark — oppressive Ministry of Magic atmosphere
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 0.72
            controls.contrast = 1.12
            controls.brightness = -0.02
            output = controls.outputImage ?? output

            // Very cool — Ministry of Magic corridors are ice-cold blue
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5000, y: -10)
            output = temperature.outputImage ?? output

            // Crushed blacks, protected highlights
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.22
            shadowHighlight.highlightAmount = 0.88
            return shadowHighlight.outputImage ?? output

        case .hero:
            // Hero (2002) — Zhang Yimou / Christopher Doyle.
            // Vivid saturated primaries across color chapters — red autumn leaves,
            // jade green silk, cold blue duels. Bold but not blown.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Red boost — crimson to scarlet, the signature red chapter
            matrix.rVector = CIVector(x: 1.10, y: 0.06, z: 0.00, w: 0.0)
            // Green maintained — jade green flashback chapter quality
            matrix.gVector = CIVector(x: 0.04, y: 1.00, z: 0.02, w: 0.0)
            // Blue pulled back — keeps reds warm, prevents purple cast
            matrix.bVector = CIVector(x: 0.00, y: 0.06, z: 0.82, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Warm red-orange lift — fiery crimson autumn leaves
            matrix.biasVector = CIVector(x: 0.014, y: 0.002, z: -0.010, w: 0.0)
            var output = matrix.outputImage ?? image

            // Bold saturated primaries — "reds with weight, tonal transitions"
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.28
            controls.contrast = 1.12
            controls.brightness = -0.01
            output = controls.outputImage ?? output

            // Warm — the red chapter has a fiery, sun-baked temperature
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5200, y: 8)
            output = temperature.outputImage ?? output

            // Hold shadows, anamorphic wide latitude in highlights
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = -0.08
            shadowHighlight.highlightAmount = 0.90
            return shadowHighlight.outputImage ?? output

        case .laLaLand:
            // La La Land (2016) — Linus Sandgren ASC, 35mm pull-processed.
            // "A dream of Los Angeles" — pastels, magic hour pinks/blues,
            // lifted blacks (immature blacks from pull process), soft warm glow.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            // Soft warm reds — romantic, gentle (pull-processed film character)
            matrix.rVector = CIVector(x: 1.04, y: 0.05, z: 0.01, w: 0.0)
            // Balanced greens — doesn't compete with the pinks and purples
            matrix.gVector = CIVector(x: 0.03, y: 0.97, z: 0.04, w: 0.0)
            // Slight blue lift — magic hour blue/purple sky quality
            matrix.bVector = CIVector(x: 0.01, y: 0.07, z: 0.90, w: 0.0)
            matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
            // Pastel lift — pull-processed film has lifted, milky blacks
            matrix.biasVector = CIVector(x: 0.014, y: 0.010, z: 0.014, w: 0.0)
            var output = matrix.outputImage ?? image

            // Pull-process character: softer contrast, colors clean and elegant
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.saturation = 1.08
            controls.contrast = 1.08
            controls.brightness = 0.015
            output = controls.outputImage ?? output

            // Magic hour warmth — warm practical lamps mixed with blue dusk skies
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5800, y: 12)
            output = temperature.outputImage ?? output

            // Lifted shadows (pastel/dream quality), protected highlights
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = output
            shadowHighlight.shadowAmount = 0.10
            shadowHighlight.highlightAmount = 0.86
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
            // CCE pushed stock — coarse grain, hard vignette, no bloom
            return FilmFinishSettings(
                grainAmount: 0.12,
                grainSize: 1.60,
                vignetteStrength: 0.24,
                vignetteSoftness: 0.60,
                chromaticAberration: 0.0,
                bloomIntensity: 0.0,
                bloomRadius: 0.0
            )
        case .vertigo:
            // Fine Technicolor grain, soft dreamy vignette, gentle bloom
            return FilmFinishSettings(
                grainAmount: 0.08,
                grainSize: 1.20,
                vignetteStrength: 0.14,
                vignetteSoftness: 0.82,
                chromaticAberration: 0.0,
                bloomIntensity: 0.14,
                bloomRadius: 9.0
            )
        case .orderOfPhoenix:
            // Moderate grain, deep vignette, no bloom
            return FilmFinishSettings(
                grainAmount: 0.07,
                grainSize: 1.10,
                vignetteStrength: 0.20,
                vignetteSoftness: 0.66,
                chromaticAberration: 0.0,
                bloomIntensity: 0.0,
                bloomRadius: 0.0
            )
        case .hero:
            // Clean anamorphic — minimal grain, slight vignette, subtle bloom
            return FilmFinishSettings(
                grainAmount: 0.04,
                grainSize: 0.90,
                vignetteStrength: 0.10,
                vignetteSoftness: 0.84,
                chromaticAberration: 0.0,
                bloomIntensity: 0.14,
                bloomRadius: 7.0
            )
        case .laLaLand:
            // Fine 35mm pull-processed grain, soft vignette, warm bloom
            return FilmFinishSettings(
                grainAmount: 0.09,
                grainSize: 1.15,
                vignetteStrength: 0.12,
                vignetteSoftness: 0.86,
                chromaticAberration: 0.0,
                bloomIntensity: 0.18,
                bloomRadius: 11.0
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

        let center = CIVector(x: extent.midX, y: extent.midY)
        
        // Define the vignette falloff
        // radius0: start of falloff (inner)
        // radius1: end of falloff (outer)
        // We calculate these based on the *diagonal* or *max dimension* to ensure coverage,
        // but since we will scale the gradient to match aspect ratio, we can treat it as a square first.
        let radius0 = min(extent.width, extent.height) * (0.25 + 0.25 * softness)
        let radius1 = min(extent.width, extent.height) * (0.85 + 0.15 * softness)

        // Create a standard radial gradient (circular)
        guard let radial = CIFilter(name: "CIRadialGradient") else { return image }
        radial.setValue(center, forKey: "inputCenter")
        radial.setValue(radius0, forKey: "inputRadius0")
        radial.setValue(radius1, forKey: "inputRadius1")
        // Inverted colors for a multiply mask: white (1.0) inside, darkened outside
        // Keep edges moody but avoid clipping to unrecoverable blacks.
        let outerLuma = max(0.78, 1.0 - strength * 0.55)
        
        radial.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        radial.setValue(CIColor(red: outerLuma, green: outerLuma, blue: outerLuma, alpha: 1), forKey: "inputColor1")

        guard var gradient = radial.outputImage else { return image }
        
        // --- Elliptical Transformation ---
        // To make it elliptical, we scale the gradient mask.
        // But simply scaling it will move the center.
        // A better way is to generate the gradient at a normalized center, scale it, then translate.
        // OR: Use the existing centered gradient and scale relative to the center.
        
        // Let's try a simpler approach: 
        // 1. Generate gradient in a 1x1 normalized space? No, CI logic prefers pixel coords.
        
        // Current approach: Circular gradient at the correct center.
        // We want to stretch it to match the image aspect ratio.
        
        // Simpler: Generate the gradient centered at (0,0). Scale it. Translate to real center.
        // Actually, if we want the vignette to be oval:
        
        // Let's assume the gradient is circular matching the HEIGHT.
        // If we scale X by `aspectRatio`, it becomes elliptical matching the width.
        // But we must also adjust the center.
        
        // Simpler: Generate the gradient centered at (0,0). Scale it. Translate to real center.
        guard let centeredRadial = CIFilter(name: "CIRadialGradient") else { return image }
        centeredRadial.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
        // Use a base unit size, then scale
        // Softness should extend the falloff significantly.
        // We let radius1 go beyond 100 (image edge) to create a very gentle ramp.
        let baseR0 = CGFloat(100) * (0.3 + 0.1 * softness) 
        let baseR1 = CGFloat(100) * (0.7 + 0.8 * softness) 
        centeredRadial.setValue(baseR0, forKey: "inputRadius0")
        centeredRadial.setValue(baseR1, forKey: "inputRadius1")
        centeredRadial.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        centeredRadial.setValue(CIColor(red: outerLuma, green: outerLuma, blue: outerLuma, alpha: 1), forKey: "inputColor1")
        
        if let baseGradient = centeredRadial.outputImage {
            // Determine scale to fill the image extent
            // We defined base radius relative to 100.
            // We want the "100" dimension to map to the image half-dimensions?
            // Actually, let's map the base 100 to min(halfWidth, halfHeight) * scale?
            // It's easier to just pick a scale factor.
            
            let scaleX = extent.width / 200.0 // Map -100..100 to -halfWidth..halfWidth
            let scaleY = extent.height / 200.0
            
            let elliptical = baseGradient.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            let placed = elliptical.transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
            
            // Crop back to image
            gradient = placed.cropped(to: extent)
        }
        
        guard let multiply = CIFilter(name: "CIMultiplyCompositing") else { return image }
        multiply.setValue(gradient, forKey: kCIInputImageKey)
        multiply.setValue(image, forKey: kCIInputBackgroundImageKey)
        return multiply.outputImage?.cropped(to: extent) ?? image
    }

    nonisolated private static func applyChromaticAberration(to image: CIImage, amount: CGFloat) -> CIImage {
        guard amount > 0.001 else { return image }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }
        
        // True optical CA: Radial scaling from the center.
        let center = CGPoint(x: extent.midX, y: extent.midY)
        
        // Scale Red UP and Blue DOWN relative to center.
        // Factor 0.0015 * amount gives ~2.2px shift at edge of 3000px image for amount=1.0
        let scaleFactor = 0.0015 * amount 
        let redScale = 1.0 + scaleFactor
        let blueScale = 1.0 - scaleFactor
        
        func radialTransform(scale: CGFloat) -> CGAffineTransform {
            var t = CGAffineTransform(translationX: -center.x, y: -center.y)
            t = t.scaledBy(x: scale, y: scale)
            t = t.translatedBy(x: center.x, y: center.y)
            return t
        }

        let clamped = image.clampedToExtent()
        
        let redSource = clamped
            .transformed(by: radialTransform(scale: redScale))
            .cropped(to: extent)
            
        let blueSource = clamped
            .transformed(by: radialTransform(scale: blueScale))
            .cropped(to: extent)

        let redChannel = isolateChannel(redSource, red: 1, green: 0, blue: 0)
        let greenChannel = isolateChannel(image, red: 0, green: 1, blue: 0)
        let blueChannel = isolateChannel(blueSource, red: 0, green: 0, blue: 1)

        let rg = additionComposite(redChannel, over: greenChannel)
        let rgb = additionComposite(blueChannel, over: rg).cropped(to: extent)
        
        return rgb
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
