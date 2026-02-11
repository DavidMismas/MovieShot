import Combine
import StoreKit
import SwiftUI

/// Manages the one-time Pro upgrade purchase using StoreKit 2.
///
/// Bypass options (for testing):
///   DEBUG builds   — Pro is always unlocked by default.
///                    Set env var `CineShoot_ProUnlocked=0` in the scheme to test the free flow.
///   RELEASE builds — Pro is always locked by default (normal App Store / TestFlight behaviour).
///                    Set env var `CineShoot_ProUnlocked=1` in the scheme to test Pro without buying.
///                    (Scheme env vars are stripped by App Store — safe to ship.)
@MainActor
final class StoreService: ObservableObject {

    static let proProductID = "com.david.CineShoot.pro"

    private static let bypassEnvVar = "CineShoot_ProUnlocked"

    @Published private(set) var isPro: Bool = false
    @Published private(set) var proProduct: Product?
    @Published private(set) var purchaseState: PurchaseState = .idle

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case failed(String)
    }

    private var transactionListenerTask: Task<Void, Never>?

    init() {
        #if DEBUG
        // DEBUG: unlock by default; opt-out with CineShoot_ProUnlocked=0
        let debugOverride = ProcessInfo.processInfo.environment[Self.bypassEnvVar]
        if debugOverride == "0" {
            // fall through to normal StoreKit flow for testing
        } else {
            isPro = true
            return
        }
        #else
        // RELEASE / TestFlight: opt-in bypass with CineShoot_ProUnlocked=1 (scheme only, stripped by App Store)
        if ProcessInfo.processInfo.environment[Self.bypassEnvVar] == "1" {
            isPro = true
            return
        }
        #endif

        transactionListenerTask = listenForTransactions()

        Task {
            await loadProduct()
            await refreshPurchaseStatus()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Public API

    func purchase() async {
        guard let product = proProduct else { return }
        purchaseState = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPro = true
                purchaseState = .idle
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func restorePurchases() async {
        purchaseState = .purchasing
        do {
            try await AppStore.sync()
            await refreshPurchaseStatus()
            purchaseState = .idle
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.proProductID])
            proProduct = products.first
        } catch {
            // Product load failure is non-fatal; purchase button will be disabled
        }
    }

    private func refreshPurchaseStatus() async {
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               transaction.productID == Self.proProductID {
                isPro = true
                return
            }
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? self.checkVerified(result),
                   transaction.productID == Self.proProductID {
                    await transaction.finish()
                    await MainActor.run { self.isPro = true }
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    enum StoreError: Error {
        case failedVerification
    }
}
