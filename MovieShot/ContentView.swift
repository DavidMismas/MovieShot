import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = EditorViewModel()
    @State private var loadingSpin = false
    @State private var cropDragStart: CGSize = .zero

    private let cinemaBlack = Color(red: 0.05, green: 0.06, blue: 0.08)
    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let isLandscape = proxy.size.width > proxy.size.height

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
            .navigationBarHidden(true)
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
    }

    private func screenLayout(in proxy: GeometryProxy, isLandscape: Bool) -> some View {
        let previewHeight = previewHeight(for: proxy.size, isLandscape: isLandscape)

        return VStack(spacing: isLandscape ? 6 : 10) {
            if isLandscape {
                compactHeader
            } else {
                titleBlock
                stepHeader
            }

            previewArea(isLandscape: isLandscape)
                .frame(height: previewHeight)

            if !viewModel.showPresetLoading {
                stepControls
                if viewModel.step != .source {
                    stepActions
                }
            }

            if let statusMessage = viewModel.statusMessage {
                statusBanner(statusMessage)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, isLandscape ? 10 : 14)
        .padding(.vertical, isLandscape ? 8 : 10)
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }

    private func previewHeight(for size: CGSize, isLandscape: Bool) -> CGFloat {
        if isLandscape {
            let ratio: CGFloat
            switch viewModel.step {
            case .source:
                ratio = 0.50
            case .preset:
                ratio = 0.40
            case .adjust:
                ratio = 0.30
            case .crop:
                ratio = 0.36
            case .final:
                ratio = 0.36
            }
            return max(size.height * ratio, 140)
        }

        // Portrait: camera source gets full 3:4 preview
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
            ratio = 0.36
        case .crop:
            ratio = 0.44
        case .final:
            ratio = 0.42
        }
        return min(max(size.height * ratio, 200), 480)
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
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(cinemaAmber)
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
                Text("MovieShot")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("cinematic camera + grading")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            Image(systemName: "film.stack.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(cinemaAmber)
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

    private func sourceCameraView(isLandscape: Bool) -> some View {
        ZStack {
            CameraPreviewView(
                session: viewModel.cameraService.session,
                cameraService: viewModel.cameraService,
                deviceChangeCount: viewModel.cameraService.deviceChangeCount
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack {
                    Button {
                        viewModel.cameraService.togglePosition()
                    } label: {
                        Label("Flip", systemImage: "arrow.triangle.2.circlepath.camera")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Spacer()

                    Button {
                        guard viewModel.cameraService.isRAWAvailable else { return }
                        viewModel.cameraService.isRAWEnabled.toggle()
                    } label: {
                        Label(
                            viewModel.cameraService.isRAWEnabled ? "RAW On" : "RAW",
                            systemImage: "camera.aperture"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.cameraService.isRAWEnabled ? cinemaAmber : .white)
                    .disabled(!viewModel.cameraService.isRAWAvailable)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                Spacer()

                if isLandscape {
                    HStack {
                        Spacer()
                        landscapeCameraControls
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                } else {
                    portraitCameraControls
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
        }
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
            if viewModel.cameraService.authorizationStatus == .denied ||
                viewModel.cameraService.authorizationStatus == .restricted {
                Text("Camera access is denied. Use gallery or enable camera in Settings.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(12)
                    .background(panelBackground)
            }
        }
    }

    private var portraitCameraControls: some View {
        HStack(alignment: .center, spacing: 28) {
            lensControl
            shutterControl
            galleryControl
        }
    }

    private var landscapeCameraControls: some View {
        VStack(alignment: .center, spacing: 18) {
            lensControl
            shutterControl
            galleryControl
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.38))
        )
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
        }
        .disabled(viewModel.cameraService.availableLenses.isEmpty)
    }

    private var galleryControl: some View {
        PhotosPicker(selection: $viewModel.pickerItem, matching: .images) {
            cameraToolButton(icon: "photo.stack.fill", title: "Gallery")
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
                    .frame(maxWidth: .infinity)
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
        .padding(12)
        .background(panelBackground)
    }

    private func presetIcon(for preset: MoviePreset) -> String {
        switch preset {
        case .matrix:
            return "cpu"
        case .bladeRunner2049:
            return "sun.haze.fill"
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

            if viewModel.rawData != nil {
                Text("RAW (.dng) was captured along with this photo.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.76))
            }
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

#Preview {
    ContentView()
}
