import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var cameraService: CameraService
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var store: StoreService
    @Environment(\.dismiss) var dismiss

    @State private var showPurchaseView = false

    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)
    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)
    private let panelBackground = Color.black.opacity(0.28)

    private var fastModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.autoModeEnabled },
            set: { newValue in
                if newValue, viewModel.autoModePreset.isProLocked, !store.isPro {
                    showPurchaseView = true
                    return
                }
                viewModel.autoModeEnabled = newValue
            }
        )
    }

    private var captureFormatStatusMessage: String? {
        switch cameraService.captureFormat {
        case .jpg:
            return nil
        case .appleProRAW:
            if !cameraService.appleProRAWSupported {
                return "Apple ProRAW is not supported on this device configuration."
            }
            if !cameraService.appleProRAWActive {
                return "Apple ProRAW is selected, but not available for the current camera or lens."
            }
            return nil
        case .pureRAW:
            if !cameraService.pureRAWSupported {
                return "Pure RAW is not supported on this device configuration."
            }
            return "Pure RAW uses physical lenses only and captures RAW at up to 12MP for stability."
        }
    }

    var body: some View {
        ZStack {
            cinemaSlate.ignoresSafeArea()

            ScrollView {
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

                        Toggle("Show Exposure Control", isOn: $cameraService.exposureControlEnabled)
                            .tint(cinemaAmber)

                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Fast Mode", isOn: fastModeBinding)
                                .tint(cinemaAmber)

                            Text("When enabled, each camera shot is graded with the selected preset and saved directly to Gallery. Choose the Fast preset from the camera preview.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Capture Format")
                            Picker("Capture Format", selection: $cameraService.captureFormat) {
                                ForEach(CameraCaptureFormat.allCases) { format in
                                    Text(format.label).tag(format)
                                }
                            }
                            .pickerStyle(.segmented)

                            Toggle("Save Original DNG (RAW)", isOn: $cameraService.saveOriginalDNGEnabled)
                                .tint(cinemaAmber)

                            Text("In ProRAW/Pure RAW mode, each capture also saves the untouched DNG to Gallery.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))

                            if cameraService.captureFormat == .jpg {
                                Text("Switch capture format to ProRAW or Pure RAW to enable DNG output.")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("JPEG Export Quality")
                                Spacer()
                                Text("\(viewModel.exportJPEGQualityPercent)%")
                                    .foregroundStyle(cinemaTeal)
                                    .monospacedDigit()
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(viewModel.exportJPEGQualityPercent) },
                                    set: { viewModel.exportJPEGQualityPercent = Int($0.rounded()) }
                                ),
                                in: 70...100,
                                step: 5
                            )
                            .tint(cinemaAmber)

                            Text("Higher quality = larger file size")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }

                        if !cameraService.isShutterSoundToggleAvailable {
                            Text("Your device or region may still require shutter sound.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }

                        if cameraService.exposureControlEnabled && !cameraService.exposureControlSupported {
                            Text("Exposure control is not available on the current camera/lens.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }

                        if let captureFormatStatusMessage {
                            Text(captureFormatStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
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

                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showPurchaseView) {
            PurchaseView()
                .environmentObject(store)
        }
    }
}
