@preconcurrency internal import AVFoundation
import Combine
import Foundation
import UIKit

struct CameraLens: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceType: AVCaptureDevice.DeviceType
    let position: AVCaptureDevice.Position
    /// Zoom factor to apply via videoZoomFactor (1.0 = native, 2.0 = 2x crop).
    let zoomFactor: CGFloat
    /// Sort order for UI display (lower = wider).
    let sortOrder: Int
}

struct CameraCaptureResult {
    let processedData: Data?
    let rawData: Data?
}

final class CameraService: NSObject, ObservableObject {
    private enum PreferenceKey {
        static let hapticsEnabled = "camera.hapticsEnabled"
        static let shutterSoundEnabled = "camera.shutterSoundEnabled"
        static let appleProRAWEnabled = "camera.appleProRAWEnabled"
    }

    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var activeVideoDevice: AVCaptureDevice?
    @Published private(set) var isSessionRunning = false
    @Published private(set) var availableLenses: [CameraLens] = []
    @Published private(set) var currentPosition: AVCaptureDevice.Position = .back
    @Published private(set) var selectedLens: CameraLens?
    @Published private(set) var deviceChangeCount = 0
    @Published private(set) var appleProRAWSupported = false
    @Published private(set) var appleProRAWActive = false
    @Published var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: PreferenceKey.hapticsEnabled)
        }
    }
    @Published var shutterSoundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(shutterSoundEnabled, forKey: PreferenceKey.shutterSoundEnabled)
        }
    }
    @Published var appleProRAWEnabled: Bool {
        didSet {
            UserDefaults.standard.set(appleProRAWEnabled, forKey: PreferenceKey.appleProRAWEnabled)
            refreshAppleProRAWConfiguration()
        }
    }

    let session = AVCaptureSession()
    var onPhotoCapture: ((CameraCaptureResult) -> Void)?

    private let photoOutput = AVCapturePhotoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureRotationObservation: NSKeyValueObservation?

    private var activeProcessors: [Int64: PhotoCaptureProcessor] = [:]

    private let backDiscoverySession: AVCaptureDevice.DiscoverySession
    private let frontDiscoverySession: AVCaptureDevice.DiscoverySession

    private let sessionQueue = DispatchQueue(label: "com.movieshot.session")

    override init() {
        let physicalTypes: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
        ]
        self.backDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: physicalTypes,
            mediaType: .video,
            position: .back
        )

        let frontTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTrueDepthCamera,
        ]
        self.frontDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: frontTypes,
            mediaType: .video,
            position: .front
        )
        self.hapticsEnabled = UserDefaults.standard.object(forKey: PreferenceKey.hapticsEnabled) as? Bool ?? true
        self.shutterSoundEnabled = UserDefaults.standard.object(forKey: PreferenceKey.shutterSoundEnabled) as? Bool ?? true
        self.appleProRAWEnabled = UserDefaults.standard.object(forKey: PreferenceKey.appleProRAWEnabled) as? Bool ?? false

        super.init()
        session.sessionPreset = .photo

        // Pre-populate lenses synchronously so the UI is never empty on first render.
        // DiscoverySession.devices is safe to read on any thread.
        availableLenses = buildLenses(for: .back)
    }

    func capturePhoto() {
        guard isSessionRunning else { return }
        let shouldSuppressShutterSound = !shutterSoundEnabled

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.updateAppleProRAWAvailability(inConfiguration: false)

            let processedFormat: [String: Any] = [AVVideoCodecKey: self.preferredProcessedCodec()]
            let settings: AVCapturePhotoSettings
            if let rawPixelType = self.preferredAppleProRAWPixelFormatForCapture() {
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawPixelType,
                    processedFormat: processedFormat
                )
            } else {
                settings = AVCapturePhotoSettings(format: processedFormat)
            }

            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoMirroringSupported {
                connection.isVideoMirrored = self.currentPosition == .front
            }

            let outputDimensions = self.photoOutput.maxPhotoDimensions
            if outputDimensions.width > 0 && outputDimensions.height > 0 {
                settings.maxPhotoDimensions = outputDimensions
            }
            settings.photoQualityPrioritization = .balanced
            if #available(iOS 18.0, *),
               shouldSuppressShutterSound,
               self.photoOutput.isShutterSoundSuppressionSupported {
                settings.isShutterSoundSuppressionEnabled = true
            }

            let processor = PhotoCaptureProcessor { [weak self] result in
                guard let self else { return }
                self.activeProcessors[settings.uniqueID] = nil
                if result.processedData == nil && result.rawData == nil {
                    print("CameraService: Photo capture failed (no data)")
                    return
                }
                self.onPhotoCapture?(result)
            }

            self.activeProcessors[settings.uniqueID] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    var isShutterSoundToggleAvailable: Bool {
        if #available(iOS 18.0, *) {
            return photoOutput.isShutterSoundSuppressionSupported
        }
        return false
    }

    func requestPermissionIfNeeded() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = status

        guard status == .notDetermined else {
            if status == .authorized {
                configureSessionIfNeeded()
                startSession()
            }
            return
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationStatus = granted ? .authorized : .denied
                if granted {
                    self.configureSessionIfNeeded()
                    self.startSession()
                }
            }
        }
    }

    func configureSessionIfNeeded() {
        guard authorizationStatus == .authorized else { return }

        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }

            // Add output in its own configuration block
            self.session.beginConfiguration()
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.updateAppleProRAWAvailability(inConfiguration: true)
            self.session.commitConfiguration()

            self.isConfigured = true

            // Configure initial input separately (has its own begin/commit)
            let initialPosition: AVCaptureDevice.Position = .back
            let lenses = self.reloadLenses(for: initialPosition)
            self.configureInput(for: lenses.first)

            DispatchQueue.main.async {
                self.currentPosition = initialPosition
            }
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func togglePosition() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let newPosition: AVCaptureDevice.Position = self.currentPosition == .back ? .front : .back
            let lenses = self.reloadLenses(for: newPosition)
            self.configureInput(for: lenses.first)
            DispatchQueue.main.async {
                self.currentPosition = newPosition
            }
        }
    }

    func selectLens(_ lens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard lens.position == self.currentPosition else { return }
            self.configureInput(for: lens)
        }
    }

    func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }

            let point = CGPoint(
                x: min(max(devicePoint.x, 0.0), 1.0),
                y: min(max(devicePoint.y, 0.0), 1.0)
            )

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }

                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }

                device.isSubjectAreaChangeMonitoringEnabled = true
            } catch {
                print("CameraService: focus/exposure error: \(error)")
            }
        }
    }

    // MARK: - Private

    /// Builds the lens list without any side-effects. Safe to call from any thread.
    private func buildLenses(for position: AVCaptureDevice.Position) -> [CameraLens] {
        let discovery = position == .back ? backDiscoverySession : frontDiscoverySession

        let uniqueDevices = Dictionary(grouping: discovery.devices, by: \.deviceType)
            .compactMap { $0.value.first }

        var lenses: [CameraLens] = uniqueDevices.map { device in
            let (name, order) = lensInfo(for: device.deviceType, position: position)
            return CameraLens(
                id: "\(device.position.rawValue)-\(device.deviceType.rawValue)",
                name: name,
                deviceType: device.deviceType,
                position: device.position,
                zoomFactor: 1.0,
                sortOrder: order
            )
        }

        // Digital crop lenses on the wide-angle camera
        if position == .back, uniqueDevices.contains(where: { $0.deviceType == .builtInWideAngleCamera }) {
            lenses.append(CameraLens(
                id: "\(position.rawValue)-wide-1.5x",
                name: "35mm",
                deviceType: .builtInWideAngleCamera,
                position: position,
                zoomFactor: 1.5,
                sortOrder: 10
            ))
            lenses.append(CameraLens(
                id: "\(position.rawValue)-wide-2x",
                name: "50mm",
                deviceType: .builtInWideAngleCamera,
                position: position,
                zoomFactor: 2.0,
                sortOrder: 15
            ))
        }

        // Digital crop lens on the Telephoto camera
        if position == .back, uniqueDevices.contains(where: { $0.deviceType == .builtInTelephotoCamera }) {
            lenses.append(CameraLens(
                id: "\(position.rawValue)-tele-2x",
                name: "2x Tele",
                deviceType: .builtInTelephotoCamera,
                position: position,
                zoomFactor: 2.0,
                sortOrder: 25
            ))
        }

        return lenses.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func reloadLenses(for position: AVCaptureDevice.Position) -> [CameraLens] {
        let sorted = buildLenses(for: position)
        DispatchQueue.main.async {
            self.availableLenses = sorted
        }
        return sorted
    }

    private func configureInput(for lens: CameraLens?) {
        guard let lens else { return }

        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens.position)
        else { return }

        defer {
            DispatchQueue.main.async {
                self.selectedLens = lens
            }
        }

        // Same physical device — just update zoom, no session reconfiguration needed
        if let currentInput, currentInput.device == device {
            applyZoom(lens.zoomFactor, to: device)
            updateMaxPhotoDimensions()
            updateAppleProRAWAvailability(inConfiguration: false)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
                updateMaxPhotoDimensions()
            }

            if let currentInput {
                session.removeInput(currentInput)
                self.currentInput = nil
            }

            guard session.canAddInput(input) else {
                print("CameraService: canAddInput failed for \(lens.name)")
                return
            }
            session.addInput(input)
            currentInput = input
            applyZoom(lens.zoomFactor, to: device)
            updateAppleProRAWAvailability(inConfiguration: true)
            setupCaptureRotationCoordinator(for: device)

            DispatchQueue.main.async {
                self.activeVideoDevice = device
                self.deviceChangeCount += 1
            }
        } catch {
            print("CameraService: input error: \(error)")
        }
    }

    private func applyZoom(_ factor: CGFloat, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(factor, device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        } catch {
            print("CameraService: zoom error: \(error)")
        }
    }

    /// 12MP cap: 4032×3024
    private static let maxPixelCount: Int32 = 4032 * 3024

    private func updateMaxPhotoDimensions() {
        guard let device = currentInput?.device else { return }

        let supported = device.activeFormat.supportedMaxPhotoDimensions
        guard !supported.isEmpty else { return }

        // Pick the largest supported size up to 12MP; fall back to the smallest if none fit.
        let capped = supported
            .filter { $0.width * $0.height <= Self.maxPixelCount }
            .max(by: { $0.width * $0.height < $1.width * $1.height })

        let dimensions = capped ?? supported.min(by: { $0.width * $0.height < $1.width * $1.height })
        guard let dimensions else { return }

        // Only update if the value actually changed — avoids a crash when the
        // current value is already valid for the new format.
        let current = photoOutput.maxPhotoDimensions
        if current.width != dimensions.width || current.height != dimensions.height {
            photoOutput.maxPhotoDimensions = dimensions
        }
    }

    private func lensInfo(for type: AVCaptureDevice.DeviceType, position: AVCaptureDevice.Position) -> (name: String, sortOrder: Int) {
        if position == .front { return ("Front", 0) }
        switch type {
        case .builtInUltraWideCamera: return ("14mm", 5)
        case .builtInWideAngleCamera: return ("24mm", 0)  // sortOrder 0 = default first lens
        case .builtInTelephotoCamera: return ("Tele", 20)
        default: return ("Camera", 50)
        }
    }

    private func setupCaptureRotationCoordinator(for device: AVCaptureDevice) {
        captureRotationObservation?.invalidate()
        captureRotationObservation = nil

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        captureRotationCoordinator = coordinator

        applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)

        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async {
                self?.applyCaptureRotation(angle)
            }
        }
    }

    private func applyCaptureRotation(_ angle: CGFloat) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    private func refreshAppleProRAWConfiguration() {
        sessionQueue.async { [weak self] in
            self?.updateAppleProRAWAvailability(inConfiguration: false)
        }
    }

    private func preferredProcessedCodec() -> AVVideoCodecType {
        photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
    }

    private func preferredAppleProRAWPixelFormatForCapture() -> OSType? {
        guard #available(iOS 14.3, *) else { return nil }
        guard appleProRAWEnabled, photoOutput.isAppleProRAWEnabled else { return nil }
        return photoOutput.availableRawPhotoPixelFormatTypes.first(where: { type in
            AVCapturePhotoOutput.isAppleProRAWPixelFormat(type)
        })
    }

    private func updateAppleProRAWAvailability(inConfiguration: Bool) {
        guard #available(iOS 14.3, *) else {
            DispatchQueue.main.async {
                self.appleProRAWSupported = false
                self.appleProRAWActive = false
            }
            return
        }

        let supported = photoOutput.isAppleProRAWSupported
        let shouldEnablePipeline = supported && appleProRAWEnabled
        if photoOutput.isAppleProRAWEnabled != shouldEnablePipeline {
            if inConfiguration {
                photoOutput.isAppleProRAWEnabled = shouldEnablePipeline
            } else {
                session.beginConfiguration()
                photoOutput.isAppleProRAWEnabled = shouldEnablePipeline
                session.commitConfiguration()
            }
        }

        let active = shouldEnablePipeline && preferredAppleProRAWPixelFormatForCapture() != nil
        DispatchQueue.main.async {
            self.appleProRAWSupported = supported
            self.appleProRAWActive = active
        }
    }
}
