import SwiftUI
internal import AVFoundation

struct PreviewArea: View {
    @ObservedObject var viewModel: EditorViewModel
    let isLandscape: Bool
    @Binding var cropDragStart: CGSize
    @Binding var rotationAngle: Angle

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
