import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraService: CameraService
    /// Observed so SwiftUI calls updateUIView when the camera device changes.
    let deviceChangeCount: Int

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.session = session
        view.cameraService = cameraService
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.cameraService = cameraService
        // Force re-evaluation when the device changes
        uiView.resetTrackedDevice()
    }
}

final class PreviewView: UIView {
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var sessionObservation: NSObjectProtocol?
    private var trackedDeviceID: String?

    weak var cameraService: CameraService?

    func resetTrackedDevice() {
        trackedDeviceID = nil
        setupRotationIfReady()
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setupRotationIfReady()
            // Also listen for session start so we can configure rotation
            // when the connection becomes available after session starts running.
            if sessionObservation == nil {
                sessionObservation = NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.didStartRunningNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.setupRotationIfReady()
                }
            }
        } else {
            teardownRotation()
            if let obs = sessionObservation {
                NotificationCenter.default.removeObserver(obs)
                sessionObservation = nil
            }
        }
    }

    private func setupRotationIfReady() {
        guard let service = cameraService else { return }
        guard let device = currentVideoDevice(in: service.session) else { return }
        guard videoPreviewLayer.connection != nil else { return }

        // Only reconfigure if the device changed
        guard trackedDeviceID != device.uniqueID else { return }

        teardownRotation()
        trackedDeviceID = device.uniqueID

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: videoPreviewLayer
        )
        rotationCoordinator = coordinator

        // Apply initial angle
        applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)

        // Observe continuous changes
        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] coord, _ in
            DispatchQueue.main.async {
                self?.applyRotation(coord.videoRotationAngleForHorizonLevelPreview)
            }
        }
    }

    private func teardownRotation() {
        previewRotationObservation?.invalidate()
        previewRotationObservation = nil
        rotationCoordinator = nil
        trackedDeviceID = nil
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = videoPreviewLayer.connection else { return }
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func currentVideoDevice(in session: AVCaptureSession) -> AVCaptureDevice? {
        session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first(where: { $0.device.hasMediaType(.video) })?
            .device
    }

    deinit {
        if let obs = sessionObservation {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
