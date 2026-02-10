import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var cameraService: CameraService
    @Environment(\.dismiss) var dismiss

    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)

    var body: some View {
        ZStack {
            cinemaSlate.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Settings")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.top, 20)

                Spacer()
            }
        }
    }
}
