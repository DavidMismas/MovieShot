import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = EditorViewModel()
    @State private var loadingSpin = false
    @State private var cropDragStart: CGSize = .zero
    @State private var rotationAngle: Angle = .zero
    @State private var isPhysicalLandscape: Bool = false
    @State private var showSettings = false

    private let cinemaBlack = Color(red: 0.05, green: 0.06, blue: 0.08)
    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = resolvedIsLandscape(for: proxy.size)

            ZStack {
                LinearGradient(
                    colors: [cinemaBlack, cinemaSlate],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                screenLayout(in: proxy, isLandscape: isLandscape)

                if viewModel.showPresetLoading {
                    loadingOverlay
                        .transition(.opacity)
                        .onAppear {
                            loadingSpin = false
                            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                                loadingSpin = true
                            }
                        }
                        .onDisappear {
                            loadingSpin = false
                        }
                }
            }
        }
        .tint(cinemaAmber)
        .onAppear {
            if viewModel.step == .source {
                viewModel.onSourceAppear()
            }
        }
        .onChange(of: viewModel.step) { _, newStep in
            if newStep == .source {
                viewModel.onSourceAppear()
            } else {
                viewModel.onSourceDisappear()
            }
        }
        .onChange(of: viewModel.cropOption) { _, _ in
            cropDragStart = .zero
        }
        .sheet(isPresented: $viewModel.showShareSheet) {
            if let image = viewModel.renderFullResolution() {
                ShareSheet(items: [image])
            }
        }
        .sheet(isPresented: $showSettings) {
             SettingsSheet(cameraService: viewModel.cameraService)
                 .presentationDetents([.fraction(0.4)])
                 .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let orientation = UIDevice.current.orientation
            withAnimation {
                switch orientation {
                case .landscapeLeft:
                    rotationAngle = .degrees(90)
                    isPhysicalLandscape = true
                case .landscapeRight:
                    rotationAngle = .degrees(-90)
                    isPhysicalLandscape = true
                case .portrait:
                    rotationAngle = .degrees(0)
                    isPhysicalLandscape = false
                default:
                    break
                }
            }
        }
    }

    @ViewBuilder
    private func screenLayout(in proxy: GeometryProxy, isLandscape: Bool) -> some View {
        // Always use portrait layout structure since app is locked to portrait.
        // We adjust visibility and rotation based on physical device orientation.
        let previewHeight = previewHeight(for: proxy.size, isPhysicalLandscape: isPhysicalLandscape)

        VStack(spacing: 10) {
            // Header with local padding
            VStack(spacing: 10) {
                titleBlock
                stepHeader
            }
            .padding(.horizontal, 14)

            // Preview Area - Minimal padding for "full width" look but keeping border
            previewArea(isLandscape: false) 
                .frame(height: previewHeight)
                .padding(.horizontal, 4) 
            
            Spacer(minLength: 0) // Push controls to bottom

            if !viewModel.showPresetLoading {
                VStack(spacing: 10) {
                    stepControls
                    if viewModel.step != .source {
                        stepActions
                    }
                }
                .padding(.horizontal, 14)
            }

            if let statusMessage = viewModel.statusMessage {
                statusBanner(statusMessage)
                    .padding(.horizontal, 14)
            }
            
            // Bottom padding spacer already handled by padding(.vertical)
        }
        .padding(.vertical, 10)
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }

    private func previewHeight(for size: CGSize, isPhysicalLandscape: Bool) -> CGFloat? {
        // In landscape source mode, let the preview expand to fill available space
        if isPhysicalLandscape && viewModel.step == .source {
            // Return 4:3 ratio based on width (same as portrait)
            return size.width * (4.0 / 3.0)
        }

        // Portrait: camera source and Editor steps get full 3:4 preview potential
        // Maximum height needed for a 3:4 image is width * (4/3)
        // We use a slightly smaller multiplier if needed to fit controls, but user requested "bigger".
        // Let's try to give it the full 4:3 aspect ratio space based on width.
        // let targetHeight = size.width * (4.0 / 3.0)
        
        // Ensure we don't overflow the screen height preventing controls from showing.
        // Controls take up significant vertical space. Let's reserve ~40% for UI.
        // return min(targetHeight, size.height * 0.60) 
        
        // REVERTED to per-step logic to ensure fit
        if viewModel.step == .source {
             let targetHeight = size.width * (4.0 / 3.0)
             return min(targetHeight, size.height * 0.68)
        }

        let ratio: CGFloat
        switch viewModel.step {
        case .source:
            ratio = 0.42
        case .preset:
            ratio = 0.44
        case .adjust:
            ratio = 0.36 // Smaller for adjust controls
        case .crop:
            ratio = 0.44
        case .final:
            ratio = 0.42
        }
        return min(max(size.height * ratio, 200), 480) 
    }

    private func resolvedIsLandscape(for size: CGSize) -> Bool {
        if let orientation = currentInterfaceOrientation() {
            return orientation.isLandscape
        }
        return size.width > size.height
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        if #available(iOS 26.0, *) {
            return scene.effectiveGeometry.interfaceOrientation
        } else {
            return scene.interfaceOrientation
        }
    }

    private func statusBanner(_ statusMessage: String) -> some View {
        Text(statusMessage)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(panelBackground)
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("MovieShot")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(cinemaAmber)
                }
            }

            Text(viewModel.step.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

            HStack(spacing: 6) {
                ForEach(EditorStep.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step.rawValue <= viewModel.step.rawValue ? cinemaTeal : .white.opacity(0.2))
                        .frame(height: 4)
                }
            }
        }
        .padding(10)
        .background(panelBackground)
    }

    private var titleBlock: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Movira")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("cinematic photo camera grading")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(cinemaAmber)
            }
        }
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.step.title)
                .font(.headline)
                .foregroundStyle(.white)

            HStack(spacing: 6) {
                ForEach(EditorStep.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step.rawValue <= viewModel.step.rawValue ? cinemaTeal : .white.opacity(0.2))
                        .frame(height: 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(panelBackground)
    }

    @ViewBuilder
    private func previewArea(isLandscape: Bool) -> some View {
        Group {
            if let image = viewModel.editedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(cropDragGesture)
            } else if viewModel.step == .source,
                      viewModel.cameraService.authorizationStatus == .authorized {
                sourceCameraView(isLandscape: isLandscape)
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

    /// Drag gesture that adjusts crop offset, only active in crop step with a ratio selected.
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

    /// Camera preview with flip button overlay, controls in a separate bar outside.
    private var cameraPreviewWithFlip: some View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(
                session: viewModel.cameraService.session,
                deviceChangeCount: viewModel.cameraService.deviceChangeCount
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .clipped()
    }

    @ViewBuilder
    private func sourceCameraView(isLandscape: Bool) -> some View {
        cameraPreviewWithFlip
    }

    @ViewBuilder
    private var stepControls: some View {
        switch viewModel.step {
        case .source:
            sourceControls
        case .preset:
            presetControls
        case .adjust:
            adjustControls
        case .crop:
            cropControls
        case .final:
            exportControls
        }
    }

    private var sourceControls: some View {
        Group {
            if viewModel.sourceImage != nil {
                // Already have a captured/picked image — offer retake or continue
                HStack {
                    Button {
                        viewModel.restart()
                    } label: {
                        Label("Retake", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        viewModel.continueStep()
                    } label: {
                        Label("Continue Editing", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(panelBackground)
            } else if viewModel.cameraService.authorizationStatus == .denied ||
                viewModel.cameraService.authorizationStatus == .restricted {
                Text("Camera access is denied. Use gallery or enable camera in Settings.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(12)
                    .background(panelBackground)
            } else {
                // Active camera controls (Source step, no image yet)
                HStack(alignment: .center, spacing: 28) {
                    lensControl
                    shutterControl
                    galleryControl
                }
                .padding(20)
                // No background here, just the controls floating or in the main layout flow
            }
        }
    }


    private var lensControl: some View {
        Menu {
            ForEach(viewModel.cameraService.availableLenses) { lens in
                Button(lens.name) {
                    viewModel.cameraService.selectLens(lens)
                }
            }
        } label: {
            cameraToolButton(
                icon: "camera.metering.center.weighted",
                title: viewModel.cameraService.selectedLens?.name ?? "Lens"
            )
            .rotationEffect(rotationAngle)
            .animation(.easeInOut, value: rotationAngle)
        }
        .disabled(viewModel.cameraService.availableLenses.isEmpty)
    }

    private var galleryControl: some View {
        PhotosPicker(selection: $viewModel.pickerItem, matching: .images) {
            cameraToolButton(icon: "photo.stack.fill", title: "Gallery")
                .rotationEffect(rotationAngle)
                .animation(.easeInOut, value: rotationAngle)
        }
    }

    private var shutterControl: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred(intensity: 1.0)
            viewModel.captureFromCamera()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(cinemaAmber)
                    .frame(width: 62, height: 62)
            }
            .shadow(color: cinemaAmber.opacity(0.45), radius: 10, x: 0, y: 4)
            .rotationEffect(rotationAngle)
            .animation(.easeInOut, value: rotationAngle)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.cameraService.authorizationStatus != .authorized)
    }

    private func cameraToolButton(icon: String, title: String) -> some View {
        VStack(spacing: 6) {
            Circle()
                .fill(.white.opacity(0.12))
                .overlay {
                    Image(systemName: icon)
                        .foregroundStyle(.white)
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(width: 52, height: 52)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(width: 74)
        }
    }

    private var presetControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(MoviePreset.allCases) { preset in
                    Button {
                        viewModel.selectedPreset = preset
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: presetIcon(for: preset))
                                .font(.title2)
                                .foregroundStyle(preset == viewModel.selectedPreset ? cinemaAmber : .white.opacity(0.6))

                            Text(preset.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)

                            Text(preset.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 120)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(preset == viewModel.selectedPreset ? .white.opacity(0.12) : .white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(preset == viewModel.selectedPreset ? cinemaTeal : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 12)
        .background(panelBackground)
    }

    private func presetIcon(for preset: MoviePreset) -> String {
        switch preset {
        case .matrix:
            return "cpu"
        case .bladeRunner2049:
            return "sun.haze.fill"
        case .sinCity:
            return "circle.lefthalf.filled"
        case .theBatman:
            return "moon.fill"
        case .strangerThings:
            return "sparkles.tv.fill"
        }
    }

    private var adjustControls: some View {
        VStack(spacing: 12) {
            adjustmentSlider(title: "Exposure", value: $viewModel.exposure, range: -2.0...2.0)
            adjustmentSlider(title: "Contrast", value: $viewModel.contrast, range: -1.0...1.0)
            adjustmentSlider(title: "Shadows", value: $viewModel.shadows, range: -1.0...1.0)
            adjustmentSlider(title: "Highlights", value: $viewModel.highlights, range: -1.0...1.0)
        }
        .padding(12)
        .background(panelBackground)
    }

    private func adjustmentSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title): \(String(format: "%.2f", value.wrappedValue))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Slider(value: value, in: range)
                .tint(cinemaAmber)
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Crop ratio", systemImage: "crop.rotate")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Picker("Crop", selection: $viewModel.cropOption) {
                ForEach(CropOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(cinemaAmber)
        }
        .padding(12)
        .background(panelBackground)
    }

    private var exportControls: some View {
        VStack(spacing: 10) {
            if viewModel.isRAWSource {
                Text("Edited from RAW source")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(cinemaAmber)
            }

            Button {
                viewModel.showShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.editedImage == nil)

            Button {
                viewModel.saveToLibrary()
            } label: {
                Label("Save to Gallery", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.editedImage == nil)
        }
        .padding(12)
        .background(panelBackground)
    }

    private var stepActions: some View {
        HStack {
            if viewModel.step != .source {
                Button("Back") {
                    viewModel.previousStep()
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button {
                viewModel.restart()
            } label: {
                Image(systemName: "camera.fill")
            }
            .buttonStyle(.bordered)

            Spacer()

            if viewModel.step == .final {
                Button("Start Over") {
                    viewModel.restart()
                }
                .buttonStyle(.borderedProminent)
            } else if viewModel.step != .source {
                Button("Continue") {
                    viewModel.continueStep()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(panelBackground)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(cinemaAmber)
                    .rotationEffect(.degrees(loadingSpin ? 360 : 0))

                Text("Developing Frame")
                    .font(.headline)
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(cinemaTeal)

                Text("Preparing presets")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(cinemaSlate.opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.black.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

struct SettingsSheet: View {
    @ObservedObject var cameraService: CameraService
    @Environment(\.dismiss) var dismiss
    
    // Theme colors
    private let cinemaBlack = Color(red: 0.05, green: 0.06, blue: 0.08)
    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    
    var body: some View {
        ZStack {
            cinemaSlate.ignoresSafeArea()
            
            VStack(spacing: 24) {
                Text("Settings")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.top, 20)
                
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Enable RAW Capture", isOn: $cameraService.isRawEnabled)
                        .tint(cinemaAmber)
                        .foregroundStyle(.white)
                        .font(.body.weight(.medium))
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Disable RAW in dark environments. HEIC allows for better low-light processing.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        
                        Text("Note: HEIC photos have less data for editing and presets. Keep RAW enabled for best editing results when lighting is good.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.2))
                )
                .padding(.horizontal)
                
                Spacer()
            }
        }
    }
}

#Preview {
    ContentView()
}
