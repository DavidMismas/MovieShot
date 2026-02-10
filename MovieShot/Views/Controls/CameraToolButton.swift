import SwiftUI

struct CameraToolButton: View {
    let icon: String
    let title: String
    
    var body: some View {
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
}

#Preview {
    ZStack {
        Color.black
        CameraToolButton(icon: "camera", title: "Camera")
    }
}
