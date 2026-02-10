import SwiftUI
import PhotosUI

struct SourceControls: View {
    @ObservedObject var viewModel: EditorViewModel
    let rotationAngle: Angle
    
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
    }
    
    private var lensControl: some View {
        Menu {
            ForEach(viewModel.cameraService.availableLenses) { lens in
                Button(lens.name) {
                    viewModel.cameraService.selectLens(lens)
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
    }

    private var galleryControl: some View {
        PhotosPicker(selection: $viewModel.pickerItem, matching: .images) {
            CameraToolButton(icon: "photo.stack.fill", title: "Gallery")
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
}
