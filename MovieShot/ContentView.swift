internal import
AVFoundation
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
    private let panelBackground = Color.black.opacity(0.28)

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
                    LoadingOverlay(loadingSpin: $loadingSpin)
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

                if viewModel.showSaveConfirmation {
                    saveConfirmationToast
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .zIndex(10)
                        .allowsHitTesting(false)
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
             SettingsSheet(cameraService: viewModel.cameraService, viewModel: viewModel)
                 .presentationDetents([.fraction(0.55)])
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
        let previewHeight = previewHeight(for: proxy.size, isPhysicalLandscape: isPhysicalLandscape)

        VStack(spacing: 10) {
            // Header with local padding
            VStack(spacing: 10) {
                TitleBlock(showSettings: $showSettings)
                StepHeader(step: viewModel.step)
            }
            .padding(.horizontal, 14)

            // Preview Area
            PreviewArea(
                viewModel: viewModel,
                isLandscape: false,
                cropDragStart: $cropDragStart,
                rotationAngle: $rotationAngle
            )
            .frame(height: previewHeight)
            .padding(.horizontal, 4)
            
            Spacer(minLength: 0)

            if !viewModel.showPresetLoading {
                VStack(spacing: 10) {
                    stepControls

                    if viewModel.step == .preset {
                        quickSaveButton
                    }
                    
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
        }
        .padding(.vertical, 10)
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
    }

    private func previewHeight(for size: CGSize, isPhysicalLandscape: Bool) -> CGFloat? {
        if isPhysicalLandscape && viewModel.step == .source {
            return size.width * (4.0 / 3.0)
        }
        
        if viewModel.step == .source {
             let targetHeight = size.width * (4.0 / 3.0)
             return min(targetHeight, size.height * 0.68)
        }

        let ratio: CGFloat
        switch viewModel.step {
        case .source: ratio = 0.42
        case .preset: ratio = 0.44
        case .adjust: ratio = 0.36
        case .crop: ratio = 0.44
        case .final: ratio = 0.42
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
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.15), lineWidth: 1)
                    )
            )
    }

    private var saveConfirmationToast: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(cinemaAmber)

            Text("Image Saved")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
    }

    @ViewBuilder
    private var stepControls: some View {
        switch viewModel.step {
        case .source:
            SourceControls(viewModel: viewModel, rotationAngle: rotationAngle)
        case .preset, .adjust, .crop:
            EditControls(viewModel: viewModel)
        case .final:
            ExportControls(viewModel: viewModel)
        }
    }

    private var stepActions: some View {
        ZStack {
            HStack {
                if viewModel.step != .source {
                    Button("Back") {
                        viewModel.previousStep()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if viewModel.step != .source && viewModel.step != .final {
                    Button("Continue") {
                        viewModel.continueStep()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if viewModel.step == .preset || viewModel.step == .adjust || viewModel.step == .crop || viewModel.step == .final {
                Button {
                    viewModel.restart()
                } label: {
                    Image(systemName: "camera.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var quickSaveButton: some View {
        Button {
            viewModel.saveToLibrary()
        } label: {
            Label("Save now", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.editedImage == nil)
    }
}

#Preview {
    ContentView()
        .environmentObject(StoreService())
}
