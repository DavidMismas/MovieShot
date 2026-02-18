import SwiftUI
internal import AVFoundation

struct PreviewArea: View {
    @ObservedObject var viewModel: EditorViewModel
    let isLandscape: Bool
    @Binding var cropDragStart: CGSize
    @Binding var rotationAngle: Angle

    @State private var focusIndicatorPoint: CGPoint?
    @State private var focusIndicatorScale: CGFloat = 1.0
    @State private var focusIndicatorOpacity: Double = 0.0
    @State private var focusIndicatorHideWorkItem: DispatchWorkItem?

    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let panelBackground = Color.black.opacity(0.28)
    
    var body: some View {
        Group {
            if let image = viewModel.editedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(cropDragGesture)
            } else if viewModel.step == .source,
                      viewModel.cameraService.authorizationStatus == .authorized {
                cameraPreviewWithFlip
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white.opacity(0.08))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        Text("Select or capture a photo")
                            .foregroundStyle(.white.opacity(0.75))
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
        .background(panelBackground)
    }
    
    private var cameraPreviewWithFlip: some View {
        ZStack {
            CameraPreviewView(
                session: viewModel.cameraService.session,
                activeDevice: viewModel.cameraService.activeVideoDevice,
                onTapToFocus: { layerPoint, devicePoint in
                    guard viewModel.cameraService.focusPointSupported else { return }
                    viewModel.cameraService.focus(at: devicePoint, lockFocus: false)
                    showFocusIndicator(at: layerPoint)
                },
                onLongPressToFocusLock: { layerPoint, devicePoint in
                    guard viewModel.cameraService.focusPointSupported else { return }
                    viewModel.cameraService.focus(at: devicePoint, lockFocus: true)
                    showFocusIndicator(at: layerPoint)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            Button {
                viewModel.cameraService.togglePosition()
            } label: {
                Label("Flip", systemImage: "arrow.triangle.2.circlepath.camera")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            if let badgeText = viewModel.cameraService.activeCaptureBadgeText {
                Text(badgeText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.35), lineWidth: 1)
                    )
                    .padding(10)
            }
        }
        .overlay(alignment: .top) {
            if viewModel.cameraService.focusLocked {
                Text("AF LOCK")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.35), lineWidth: 1)
                    )
                    .padding(.top, 10)
            }
        }
        .overlay(alignment: .topLeading) {
            if let focusIndicatorPoint {
                focusIndicator
                    .position(x: focusIndicatorPoint.x, y: focusIndicatorPoint.y)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.cameraService.exposureControlEnabled,
               viewModel.cameraService.exposureControlSupported {
                exposureControlOverlay
            }
        }
        .clipped()
    }

    private var exposureControlOverlay: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))

                Text("\(viewModel.cameraService.exposureBias, specifier: "%+.1f") EV")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()

                Spacer()

                if abs(viewModel.cameraService.exposureBias) > 0.05 {
                    Button {
                        viewModel.cameraService.resetExposureBias()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.75))
                }
            }

            Slider(
                value: Binding(
                    get: { Double(viewModel.cameraService.exposureBias) },
                    set: { viewModel.cameraService.exposureBias = Float($0) }
                ),
                in: Double(viewModel.cameraService.exposureBiasRange.lowerBound)...Double(viewModel.cameraService.exposureBiasRange.upperBound),
                step: 0.1
            )
            .controlSize(.mini)
            .tint(cinemaAmber)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .padding(10)
    }

    private var focusIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(cinemaAmber, lineWidth: 2)
                .frame(width: 72, height: 72)

            Circle()
                .stroke(cinemaAmber.opacity(0.95), lineWidth: 2)
                .frame(width: 8, height: 8)
        }
        .scaleEffect(focusIndicatorScale)
        .opacity(focusIndicatorOpacity)
        .allowsHitTesting(false)
    }

    private func showFocusIndicator(at point: CGPoint) {
        focusIndicatorHideWorkItem?.cancel()
        focusIndicatorPoint = point
        focusIndicatorScale = 1.2
        focusIndicatorOpacity = 1.0

        withAnimation(.easeOut(duration: 0.16)) {
            focusIndicatorScale = 1.0
        }

        let hideWork = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.2)) {
                focusIndicatorOpacity = 0.0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                if focusIndicatorOpacity <= 0.01 {
                    focusIndicatorPoint = nil
                }
            }
        }

        focusIndicatorHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: hideWork)
    }
    
    private var cropDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard viewModel.step == .crop, viewModel.cropOption != .original else { return }
                let dragScale: CGFloat = 0.01
                let newW = (cropDragStart.width + value.translation.width * dragScale)
                    .clamped(to: -1...1)
                let newH = (cropDragStart.height + value.translation.height * dragScale)
                    .clamped(to: -1...1)
                viewModel.cropOffset = CGSize(width: newW, height: newH)
            }
            .onEnded { _ in
                cropDragStart = viewModel.cropOffset
            }
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
