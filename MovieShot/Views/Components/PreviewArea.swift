import SwiftUI
internal import AVFoundation

struct PreviewArea: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var store: StoreService
    let isLandscape: Bool
    @Binding var cropDragStart: CGSize
    @Binding var rotationAngle: Angle

    @GestureState private var isBeforeAfterPressActive = false
    @State private var focusIndicatorPoint: CGPoint?
    @State private var focusIndicatorScale: CGFloat = 1.0
    @State private var focusIndicatorOpacity: Double = 0.0
    @State private var focusIndicatorHideWorkItem: DispatchWorkItem?
    @State private var showExposureSlider = false
    @State private var showPurchaseView = false

    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let panelBackground = Color.black.opacity(0.28)
    
    var body: some View {
        Group {
            if let image = displayedPreviewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(cropDragGesture)
                    .simultaneousGesture(beforeAfterPressGesture)
                    .overlay(alignment: .bottomTrailing) {
                        if canShowBeforeAfter {
                            beforeAfterIndicator
                                .padding(10)
                        }
                    }
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
        .sheet(isPresented: $showPurchaseView) {
            PurchaseView()
                .environmentObject(store)
        }
    }

    private var canShowBeforeAfter: Bool {
        viewModel.step == .preset &&
        !viewModel.autoModeEnabled &&
        viewModel.sourceImage != nil &&
        viewModel.editedImage != nil
    }

    private var displayedPreviewImage: UIImage? {
        guard canShowBeforeAfter else {
            return viewModel.editedImage
        }
        return isBeforeAfterPressActive ? viewModel.sourceImage : viewModel.editedImage
    }

    private var beforeAfterPressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isBeforeAfterPressActive) { _, state, _ in
                guard canShowBeforeAfter else { return }
                state = true
            }
    }

    private var beforeAfterIndicator: some View {
        Text(isBeforeAfterPressActive ? "Before" : "After")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )
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
        .overlay(alignment: .bottomTrailing) {
            if viewModel.cameraService.exposureControlEnabled,
               viewModel.cameraService.exposureControlSupported {
                exposureControlDock
                    .padding(.trailing, 6)
                    .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if viewModel.autoModeEnabled {
                fastPresetPickerBadge
                    .padding(.leading, 10)
                    .padding(.bottom, 10)
            }
        }
        .clipped()
    }

    private var fastPresetPickerBadge: some View {
        Menu {
            ForEach(MoviePreset.allCases) { preset in
                let locked = preset.isProLocked && !store.isPro
                Button {
                    if locked {
                        showPurchaseView = true
                    } else {
                        viewModel.autoModePreset = preset
                    }
                } label: {
                    if viewModel.autoModePreset == preset {
                        Label(locked ? "\(preset.title) - Pro" : preset.title, systemImage: "checkmark")
                    } else {
                        Text(locked ? "\(preset.title) - Pro" : preset.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.caption2.weight(.semibold))
                Text(viewModel.autoModePreset.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            )
        }
    }

    private var exposureControlDock: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if showExposureSlider {
                verticalExposureSlider
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showExposureSlider.toggle()
                }
            } label: {
                Image(systemName: showExposureSlider ? "slider.vertical.3" : "sun.max.fill")
                    .font(.headline.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.92))
            .contentShape(Circle())
            .background(.black.opacity(0.46), in: Circle())
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private var verticalExposureSlider: some View {
        VStack(spacing: 0) {
            Text("\(viewModel.cameraService.exposureBias, specifier: "%+.1f") EV")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
                .padding(.top, 4)

            Spacer(minLength: 12)

            Slider(
                value: Binding(
                    get: { Double(viewModel.cameraService.exposureBias) },
                    set: { viewModel.cameraService.exposureBias = Float($0) }
                ),
                in: Double(viewModel.cameraService.exposureBiasRange.lowerBound)...Double(viewModel.cameraService.exposureBiasRange.upperBound),
                step: 0.1
            )
            .rotationEffect(.degrees(-90))
            .frame(width: 168, height: 30)
            .controlSize(.regular)
            .tint(cinemaAmber)

            Spacer(minLength: 10)

            Button {
                viewModel.cameraService.resetExposureBias()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .padding(.horizontal, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .opacity(abs(viewModel.cameraService.exposureBias) > 0.05 ? 1 : 0.45)
            .disabled(abs(viewModel.cameraService.exposureBias) <= 0.05)
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
        }
        .frame(width: 88, height: 246)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
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
