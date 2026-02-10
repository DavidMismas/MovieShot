import SwiftUI

struct ExportControls: View {
    @ObservedObject var viewModel: EditorViewModel
    
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let panelBackground = Color.black.opacity(0.28)

    var body: some View {
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
}
