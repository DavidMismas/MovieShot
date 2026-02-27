import SwiftUI
internal import AVFoundation

struct SourceControls: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var store: StoreService
    @Environment(\.openURL) private var openURL
    let rotationAngle: Angle
    @State private var showPurchaseView = false
    
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let panelBackground = Color.black.opacity(0.28)
    
    var body: some View {
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
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(panelBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: 1)
                        )
                )
            } else if viewModel.cameraService.authorizationStatus == .denied ||
                viewModel.cameraService.authorizationStatus == .restricted {
                Text("Camera access is denied. Use gallery or enable camera in Settings.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(panelBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.white.opacity(0.15), lineWidth: 1)
                            )
                    )
            } else {
                // Active camera controls (Source step, no image yet)
                HStack(alignment: .center, spacing: 28) {
                    lensControl
                    shutterControl
                    galleryControl
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showPurchaseView) {
            PurchaseView()
                .environmentObject(store)
        }
    }
    
    private var lensControl: some View {
        Menu {
            ForEach(viewModel.cameraService.availableLenses) { lens in
                Button {
                    viewModel.cameraService.selectLens(lens)
                } label: {
                    if lens.id == viewModel.cameraService.selectedLens?.id {
                        Label(lens.name, systemImage: "checkmark")
                    } else {
                        Text(lens.name)
                    }
                }
            }
        } label: {
            CameraToolButton(
                icon: "camera.metering.center.weighted",
                title: viewModel.cameraService.selectedLens?.name ?? "Lens"
            )
            .rotationEffect(rotationAngle)
            .animation(.easeInOut, value: rotationAngle)
        }
        .buttonStyle(.plain)
    }

    private var galleryControl: some View {
        Button {
            guard let photosURL = URL(string: "photos-redirect://") else {
                viewModel.statusMessage = "Could not open Photos app."
                return
            }

            openURL(photosURL) { accepted in
                if !accepted {
                    viewModel.statusMessage = "Could not open Photos app."
                }
            }
        } label: {
            CameraToolButton(icon: "photo.stack.fill", title: "Gallery")
                .rotationEffect(rotationAngle)
                .animation(.easeInOut, value: rotationAngle)
        }
        .buttonStyle(.plain)
    }

    private var shutterControl: some View {
        Button {
            if viewModel.autoModeEnabled,
               viewModel.autoModePreset.isProLocked,
               !store.isPro {
                showPurchaseView = true
                return
            }
            if viewModel.cameraService.hapticsEnabled {
                let generator = UIImpactFeedbackGenerator(style: .rigid)
                generator.impactOccurred(intensity: 1.0)
            }
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
        .disabled(
            viewModel.cameraService.authorizationStatus != .authorized ||
            viewModel.isSavingToLibrary
        )
    }
}
