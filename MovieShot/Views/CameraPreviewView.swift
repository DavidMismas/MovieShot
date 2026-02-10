internal import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Observed so SwiftUI calls updateUIView when the camera device changes.
    let deviceChangeCount: Int

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.session = session
        view.updateDeviceChangeCount(deviceChangeCount)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.updateDeviceChangeCount(deviceChangeCount)
        uiView.setupRotationIfReady()
    }
}

final class PreviewView: UIView {
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var sessionObservation: NSObjectProtocol?
    private var trackedDeviceID: String?
    private var lastDeviceChangeCount = -1

    func updateDeviceChangeCount(_ value: Int) {
        guard value != lastDeviceChangeCount else { return }
        lastDeviceChangeCount = value
        trackedDeviceID = nil
        setupRotationIfReady()
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setupRotationIfReady()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setupRotationIfReady()
            // Also listen for session start so we can configure orientation
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

    func setupRotationIfReady() {
        guard let session = videoPreviewLayer.session else { return }
        guard let device = currentVideoDevice(in: session) else { return }
        guard videoPreviewLayer.connection != nil else { return }
        guard trackedDeviceID != device.uniqueID || rotationCoordinator == nil else { return }

        teardownRotation(clearDeviceID: false)
        trackedDeviceID = device.uniqueID

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: videoPreviewLayer
        )
        rotationCoordinator = coordinator

        applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] coord, _ in
            DispatchQueue.main.async {
                self?.applyRotation(coord.videoRotationAngleForHorizonLevelPreview)
            }
        }
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

    private func teardownRotation(clearDeviceID: Bool = true) {
        previewRotationObservation?.invalidate()
        previewRotationObservation = nil
        rotationCoordinator = nil
        if clearDeviceID {
            trackedDeviceID = nil
        }
    }

    deinit {
        teardownRotation()
        if let obs = sessionObservation {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
