import SwiftUI

struct LoadingOverlay: View {
    @Binding var loadingSpin: Bool
    
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)
    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)
    
    var body: some View {
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
}
