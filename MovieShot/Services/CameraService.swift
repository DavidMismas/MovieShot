@preconcurrency import AVFoundation
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

final class CameraService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isSessionRunning = false
    @Published private(set) var availableLenses: [CameraLens] = []
    @Published private(set) var currentPosition: AVCaptureDevice.Position = .back
    @Published private(set) var selectedLens: CameraLens?
    /// Incremented each time the active camera device changes, so the preview view can re-evaluate rotation.
    @Published private(set) var deviceChangeCount = 0

    let session = AVCaptureSession()
    /// Callback delivers (hevcImage, rawDNGData?). rawDNGData is non-nil when RAW capture succeeded.
    var onPhoto: ((UIImage, Data?) -> Void)?

    private let photoOutput = AVCapturePhotoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureRotationObservation: NSKeyValueObservation?

    /// Tracks in-flight RAW+HEVC captures (RAW fires two didFinishProcessingPhoto callbacks).
    private struct PendingCapture {
        var hevcImage: UIImage?
        var rawData: Data?
    }
    private var pendingCaptures: [Int64: PendingCapture] = [:]

    override init() {
        super.init()
        session.sessionPreset = .photo
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
        guard !isConfigured else { return }
        guard authorizationStatus == .authorized else { return }

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            isConfigured = true
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        currentPosition = .back
        reloadLenses(for: currentPosition)
        configureInput(for: selectedLens ?? availableLenses.first)
    }

    private let sessionQueue = DispatchQueue(label: "com.movieshot.session")

    func startSession() {
        guard isConfigured, !session.isRunning else { return }
        sessionQueue.async { [self] in
            session.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func stopSession() {
        guard session.isRunning else { return }
        sessionQueue.async { [self] in
            session.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func togglePosition() {
        currentPosition = currentPosition == .back ? .front : .back
        reloadLenses(for: currentPosition)
        configureInput(for: selectedLens ?? availableLenses.first)
    }

    func selectLens(_ lens: CameraLens) {
        guard lens.position == currentPosition else { return }
        configureInput(for: lens)
    }

    @Published var isRawEnabled = true
    
    // ... (existing properties)

    func capturePhoto() {
        guard isSessionRunning else { return }

        let settings: AVCapturePhotoSettings

        // Always capture RAW + HEVC when RAW is available (better data for editing)
        // BUT only if the user has enabled RAW capture.
        if isRawEnabled, let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawType,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc]
            )
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }

        // Capture rotation is continuously updated via KVO on captureRotationCoordinator.
        // Only need to handle mirroring here.
        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = currentPosition == .front
            }
        }

        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        
        // photoQualityPrioritization is unsupported when capturing RAW
        if settings.rawPhotoPixelFormatType == 0 {
            // When not capturing RAW, we can use the camera's processing smarts (Night Mode etc)
            settings.photoQualityPrioritization = .balanced
        }
        
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func reloadLenses(for position: AVCaptureDevice.Position) {
        // Only discover individual physical lenses — skip compound devices (Triple, Dual, etc.)
        let physicalTypes: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
        ]

        let frontTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTrueDepthCamera,
        ]

        let deviceTypes = position == .back ? physicalTypes : frontTypes

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        )

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

        // Add a 2x crop lens on the back wide-angle camera
        if position == .back {
            let hasWide = uniqueDevices.contains { $0.deviceType == .builtInWideAngleCamera }
            if hasWide {
                lenses.append(CameraLens(
                    id: "\(position.rawValue)-wide-2x",
                    name: "2×",
                    deviceType: .builtInWideAngleCamera,
                    position: position,
                    zoomFactor: 2.0,
                    sortOrder: 15
                ))
            }
        }

        availableLenses = lenses.sorted { $0.sortOrder < $1.sortOrder }

        if let selectedLens, availableLenses.contains(selectedLens) {
            return
        }
        // Default to Wide (1x)
        selectedLens = availableLenses.first { $0.deviceType == .builtInWideAngleCamera && $0.zoomFactor == 1.0 }
            ?? availableLenses.first
    }

    private func configureInput(for lens: CameraLens?) {
        guard let lens else { return }

        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens.position)
        else {
            return
        }

        // If the device is already active (e.g. switching between 1× and 2× on the same wide lens),
        // just update the zoom factor without reconfiguring the session.
        if let currentInput, currentInput.device == device {
            applyZoom(lens.zoomFactor, to: device)
            selectedLens = lens
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
                selectedLens = lens
                updateMaxPhotoDimensions()
            }

            if let currentInput {
                session.removeInput(currentInput)
            }

            guard session.canAddInput(input) else { return }
            session.addInput(input)
            currentInput = input
            applyZoom(lens.zoomFactor, to: device)
            setupCaptureRotationCoordinator(for: device)
            deviceChangeCount += 1
        } catch {
            print("Camera input error: \(error)")
        }
    }

    private func applyZoom(_ factor: CGFloat, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(factor, device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        } catch {
            print("Zoom error: \(error)")
        }
    }

    /// 12MP cap: 4032×3024 (standard iPhone 12MP).
    private static let maxPixelCount: Int32 = 4032 * 3024

    private func updateMaxPhotoDimensions() {
        guard let device = currentInput?.device else { return }

        // Find the largest supported dimensions that don't exceed 12MP.
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        let capped = supported
            .filter { $0.width * $0.height <= Self.maxPixelCount }
            .max(by: { $0.width * $0.height < $1.width * $1.height })

        // If nothing fits under 12MP (shouldn't happen), pick the smallest available.
        let dimensions = capped ?? supported.min(by: { $0.width * $0.height < $1.width * $1.height })
        guard let dimensions else { return }
        photoOutput.maxPhotoDimensions = dimensions
    }

    private func lensInfo(for type: AVCaptureDevice.DeviceType, position: AVCaptureDevice.Position) -> (name: String, sortOrder: Int) {
        if position == .front {
            return ("Front", 0)
        }
        switch type {
        case .builtInUltraWideCamera: return ("Ultra Wide", 0)
        case .builtInWideAngleCamera: return ("Wide", 10)
        case .builtInTelephotoCamera: return ("Tele", 30)
        default: return ("Camera", 50)
        }
    }

    private func setupCaptureRotationCoordinator(for device: AVCaptureDevice) {
        captureRotationObservation?.invalidate()
        captureRotationObservation = nil

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        captureRotationCoordinator = coordinator

        // Apply initial capture rotation angle
        applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)

        // Continuously update capture rotation via KVO
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] coord, _ in
            self?.applyCaptureRotation(coord.videoRotationAngleForHorizonLevelCapture)
        }
    }

    private func applyCaptureRotation(_ angle: CGFloat) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil else { return }

        let captureID = photo.resolvedSettings.uniqueID
        var pending = pendingCaptures[captureID] ?? PendingCapture()

        if photo.isRawPhoto {
            // Store the DNG data for RAW-based editing
            pending.rawData = photo.fileDataRepresentation()
        } else if let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) {
            pending.hevcImage = image
        }

        pendingCaptures[captureID] = pending
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let captureID = resolvedSettings.uniqueID
        guard let pending = pendingCaptures.removeValue(forKey: captureID),
              let image = pending.hevcImage
        else {
            pendingCaptures[captureID] = nil
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onPhoto?(image, pending.rawData)
        }
    }
}
