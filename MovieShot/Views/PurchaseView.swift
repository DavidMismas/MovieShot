import StoreKit
import SwiftUI

struct PurchaseView: View {
    @EnvironmentObject var store: StoreService
    @Environment(\.dismiss) private var dismiss

    private let cinemaBlack = Color(red: 0.05, green: 0.06, blue: 0.08)
    private let cinemaSlate = Color(red: 0.11, green: 0.13, blue: 0.17)
    private let cinemaAmber = Color(red: 0.96, green: 0.69, blue: 0.27)
    private let cinemaTeal = Color(red: 0.22, green: 0.74, blue: 0.79)

    private let proPresets: [MoviePreset] = MoviePreset.allCases.filter { $0.isProLocked }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [cinemaBlack, cinemaSlate],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(cinemaAmber)

                        Text("Cineshoot Pro")
                            .font(.title.bold())
                            .foregroundStyle(.white)

                        Text("Unlock all 13 cinematic presets")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(.top, 36)

                    // Pro preset grid
                    VStack(spacing: 8) {
                        Text("Included in Pro")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)

                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 10
                        ) {
                            ForEach(proPresets) { preset in
                                HStack(spacing: 10) {
                                    Image(systemName: presetIcon(for: preset))
                                        .font(.body)
                                        .foregroundStyle(cinemaTeal)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.white)
                                        Text(preset.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                        )
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Purchase button
                    VStack(spacing: 14) {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            ZStack {
                                if store.purchaseState == .purchasing {
                                    ProgressView()
                                        .tint(.black)
                                } else {
                                    Text(purchaseButtonLabel)
                                        .font(.headline)
                                        .foregroundStyle(.black)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(cinemaAmber)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(store.purchaseState == .purchasing || store.proProduct == nil)
                        .buttonStyle(.plain)

                        Button {
                            Task { await store.restorePurchases() }
                        } label: {
                            Text("Restore Purchases")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.purchaseState == .purchasing)

                        if case .failed(let message) = store.purchaseState {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        Text("One-time purchase · No subscription")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 20)

                    // Legal footer
                    VStack(spacing: 6) {
                        Text("Payment will be charged to your Apple ID account at confirmation of purchase. The purchase is non-refundable except as required by law.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.28))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }

            // Dismiss button
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .onChange(of: store.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    private var purchaseButtonLabel: String {
        if let product = store.proProduct {
            return "Unlock Cineshoot Pro — \(product.displayPrice)"
        }
        return "Unlock Cineshoot Pro"
    }

    private func presetIcon(for preset: MoviePreset) -> String {
        switch preset {
        case .matrix: return "cpu"
        case .bladeRunner2049: return "sun.haze.fill"
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
