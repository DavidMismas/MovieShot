import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var cameraService: CameraService
    @EnvironmentObject var store: StoreService
    @Environment(\.dismiss) var dismiss

    @State private var showPurchaseView = false

    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)
    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)
    private let panelBackground = Color.black.opacity(0.28)

    var body: some View {
        ZStack {
            cinemaSlate.ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    Text("Settings")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }

                // Pro status row
                VStack(alignment: .leading, spacing: 14) {
                    if store.isPro {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(cinemaAmber)
                            Text("Cineshoot Pro — Unlocked")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                    } else {
                        Button {
                            showPurchaseView = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.open.fill")
                                    .foregroundStyle(cinemaAmber)
                                Text("Unlock Cineshoot Pro")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(cinemaAmber)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(panelBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(store.isPro ? cinemaAmber.opacity(0.4) : .white.opacity(0.15), lineWidth: 1)
                        )
                )

                // Camera settings
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Haptic Feedback", isOn: $cameraService.hapticsEnabled)
                        .tint(cinemaAmber)

                    Toggle("Shutter Sound", isOn: $cameraService.shutterSoundEnabled)
                        .tint(cinemaAmber)

                    Toggle("Use Apple ProRAW", isOn: $cameraService.appleProRAWEnabled)
                        .tint(cinemaAmber)

                    if !cameraService.isShutterSoundToggleAvailable {
                        Text("Your device or region may still require shutter sound.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }

                    if cameraService.appleProRAWEnabled && !cameraService.appleProRAWActive {
                        Text("Apple ProRAW is enabled, but not available for the current camera or lens.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    } else if !cameraService.appleProRAWSupported {
                        Text("Apple ProRAW is not supported on this device configuration.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }

                    Divider()
                        .background(.white.opacity(0.12))

                    Button {
                        Task { await store.restorePurchases() }
                    } label: {
                        HStack {
                            Text("Restore Purchases")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            if store.purchaseState == .purchasing {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.purchaseState == .purchasing)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(panelBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: 1)
                        )
                )

                Spacer()
            }
            .padding(16)
        }
        .sheet(isPresented: $showPurchaseView) {
            PurchaseView()
                .environmentObject(store)
        }
    }
}
