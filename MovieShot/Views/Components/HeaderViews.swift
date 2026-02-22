import SwiftUI
import PhotosUI

struct TitleBlock: View {
    @Binding var showSettings: Bool
    @Binding var showBatchEdit: Bool
    @Binding var pickerItem: PhotosPickerItem?
    
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cineshoot")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("cinematic photo camera grading")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()

            Button {
                showBatchEdit = true
            } label: {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(cinemaAmber)
            }
        }
    }
}

struct StepHeader: View {
    let step: EditorStep
    
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)
    private let panelBackground = Color.black.opacity(0.28)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.headline)
                .foregroundStyle(.white)

            HStack(spacing: 6) {
                ForEach(EditorStep.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? cinemaTeal : .white.opacity(0.2))
                        .frame(height: 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
