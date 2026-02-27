import PhotosUI
import SwiftUI

struct BatchEditView: View {
    @EnvironmentObject var store: StoreService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = BatchEditViewModel()
    @State private var showPurchaseView = false

    private let cinemaBlack = Color(red: 0.05, green: 0.06, blue: 0.08)
    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)
    private let panelBackground = Color.black.opacity(0.28)

    private var selectedPresetLocked: Bool {
        viewModel.selectedPreset.isProLocked && !store.isPro
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [cinemaBlack, cinemaSlate],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        selectionCard
                        presetCard
                        actionCard
                    }
                    .padding(14)
                }
            }
            .navigationTitle("Batch Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(cinemaAmber)
                }
            }
        }
        .sheet(isPresented: $showPurchaseView) {
            PurchaseView()
                .environmentObject(store)
        }
    }

    private var selectionCard: some View {
        let pickerButtonTitle = viewModel.selectedItemCount == 0 ? "Choose Photos" : "Change Selection"

        return VStack(alignment: .leading, spacing: 12) {
            Text("1. Select Photos")
                .font(.headline)
                .foregroundStyle(.white)

            PhotosPicker(
                selection: $viewModel.pickerItems,
                maxSelectionCount: 100,
                matching: .images
            ) {
                Label(
                    pickerButtonTitle,
                    systemImage: "photo.on.rectangle.angled"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(cinemaAmber)

            Text("\(viewModel.selectedItemCount) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(viewModel.selectedItemCount > 0 ? cinemaTeal : .white.opacity(0.65))
        }
        .padding(12)
        .background(cardBackground)
    }

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. Choose Preset")
                .font(.headline)
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MoviePreset.allCases) { preset in
                        let locked = preset.isProLocked && !store.isPro
                        Button {
                            if locked {
                                showPurchaseView = true
                            } else {
                                viewModel.selectedPreset = preset
                            }
                        } label: {
                            presetCell(for: preset, locked: locked)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if selectedPresetLocked {
                Text("Selected preset requires Pro.")
                    .font(.caption)
                    .foregroundStyle(cinemaAmber)
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. Save Batch")
                .font(.headline)
                .foregroundStyle(.white)

            Button {
                viewModel.processBatch(isProUnlocked: store.isPro)
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isProcessing {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }

                    Text(viewModel.isProcessing ? "Processing..." : "Save to Gallery")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(cinemaAmber)
            .disabled(
                viewModel.selectedItemCount == 0 ||
                viewModel.isProcessing ||
                selectedPresetLocked
            )

            if viewModel.isProcessing {
                ProgressView(value: viewModel.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(cinemaTeal)

                Text("Saved \(viewModel.processedCount), failed \(viewModel.failedCount)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }

            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    @ViewBuilder
    private func presetCell(for preset: MoviePreset, locked: Bool) -> some View {
        let isSelected = preset == viewModel.selectedPreset

        HStack(spacing: 6) {
            Image(systemName: presetIcon(for: preset))
                .font(.caption.weight(.semibold))
            Text(preset.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
            }
        }
        .foregroundStyle(locked ? .white.opacity(0.45) : .white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected && !locked ? cinemaTeal.opacity(0.35) : .white.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isSelected && !locked ? cinemaTeal : .white.opacity(0.14), lineWidth: 1)
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(panelBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
    }

    private func presetIcon(for preset: MoviePreset) -> String {
        switch preset {
        case .matrix: return "cpu"
        case .bladeRunner2049: return "sun.haze.fill"
        case .studioClean: return "camera.aperture"
        case .daylightRun: return "target"
        case .sinCity: return "circle.lefthalf.filled"
        case .theBatman: return "moon.fill"
        case .strangerThings: return "sparkles.tv.fill"
        case .dune: return "sun.max.fill"
        case .drive: return "car.fill"
        case .madMax: return "flame.fill"
        case .revenant: return "snowflake"
        case .inTheMoodForLove: return "heart.fill"
        case .seven: return "cloud.rain.fill"
        case .vertigo: return "eye.fill"
        case .orderOfPhoenix: return "wand.and.stars"
        case .hero: return "seal.fill"
        case .laLaLand: return "music.note"
        case .blockbusterTealOrange: return "theatermasks.fill"
        case .metroNeonNight: return "sparkles.rectangle.stack.fill"
        case .noirTealGlow: return "moon.stars.fill"
        case .urbanWarmCool: return "building.2.fill"
        case .electricDusk: return "bolt.fill"
        }
    }
}

#Preview {
    BatchEditView()
        .environmentObject(StoreService())
}
