import SwiftUI

struct EditControls: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var store: StoreService

    @State private var showPurchaseView = false

    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)
    private let panelBackground = Color.black.opacity(0.28)

    var body: some View {
        Group {
            switch viewModel.step {
            case .preset:
                presetControls
            case .adjust:
                adjustControls
            case .crop:
                cropControls
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: $showPurchaseView) {
            PurchaseView()
                .environmentObject(store)
        }
    }

    private var presetControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(MoviePreset.allCases) { preset in
                    let locked = preset.isProLocked && !store.isPro
                    Button {
                        if locked {
                            showPurchaseView = true
                        } else {
                            viewModel.selectPreset(preset)
                        }
                    } label: {
                        presetCell(preset: preset, locked: locked)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 12)
        .background(backgroundStyle)
    }

    @ViewBuilder
    private func presetCell(preset: MoviePreset, locked: Bool) -> some View {
        let isSelected = viewModel.isPresetApplied && preset == viewModel.selectedPreset

        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Image(systemName: presetIcon(for: preset))
                    .font(.title2)
                    .foregroundStyle(
                        locked
                            ? .white.opacity(0.3)
                            : (isSelected ? cinemaAmber : .white.opacity(0.6))
                    )

                Text(preset.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(locked ? .white.opacity(0.4) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(preset.subtitle)
                    .font(.caption2)
                    .foregroundStyle(locked ? .white.opacity(0.3) : .white.opacity(0.6))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(height: 42, alignment: .top)
            }
            .frame(width: 126)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected && !locked
                          ? .white.opacity(0.12)
                          : .white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected && !locked ? cinemaTeal : .clear,
                        lineWidth: 1.5
                    )
            )

            // Lock badge
            if locked {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .offset(x: -6, y: 6)
            }
        }
    }

    private var adjustControls: some View {
        VStack(spacing: 12) {
            adjustmentSlider(
                title: "Exposure",
                value: $viewModel.exposure,
                range: -2.0...2.0,
                isMinimal: true,
                usesEVFormatting: true
            )
            adjustmentSlider(title: "Contrast", value: $viewModel.contrast, range: -1.0...1.0)
            adjustmentSlider(title: "Shadows", value: $viewModel.shadows, range: -1.0...1.0)
            adjustmentSlider(title: "Highlights", value: $viewModel.highlights, range: -1.0...1.0)
        }
        .padding(12)
        .background(backgroundStyle)
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Crop ratio", systemImage: "crop.rotate")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Picker("Crop", selection: $viewModel.cropOption) {
                ForEach(CropOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(cinemaAmber)
        }
        .padding(12)
        .background(backgroundStyle)
    }

    private func adjustmentSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        isMinimal: Bool = false,
        usesEVFormatting: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: isMinimal ? 4 : 6) {
            if isMinimal {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))

                    Spacer()

                    Text(sliderValueText(for: value.wrappedValue, usesEVFormatting: usesEVFormatting))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                }
            } else {
                Text("\(title): \(String(format: "%.2f", value.wrappedValue))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Slider(value: value, in: range)
                .controlSize(isMinimal ? .mini : .regular)
                .tint(cinemaAmber)
        }
    }

    private func sliderValueText(for value: Double, usesEVFormatting: Bool) -> String {
        if usesEVFormatting {
            return String(format: "%+.1f EV", value)
        }
        return String(format: "%.2f", value)
    }

    private var backgroundStyle: some View {
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
        }
    }
}
