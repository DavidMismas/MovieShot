import Combine
import StoreKit
import SwiftUI

/// Manages the one-time Pro upgrade purchase using StoreKit 2.
///
/// Bypass options (for testing):
///   DEBUG builds    — Pro is always unlocked by default.
///                     Set env var `CineShoot_ProUnlocked=0` in the scheme to test the free/paywall flow.
///   TestFlight      — Pro is always unlocked automatically via AppTransaction.shared sandbox check.
///   App Store       — Normal StoreKit flow; purchase required.
@MainActor
final class StoreService: ObservableObject {

    static let proProductID = "com.david.CineShoot.pro"

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
        // DEBUG: unlock by default; opt-out with env var CineShoot_ProUnlocked=0 to test the free flow.
        let debugOverride = ProcessInfo.processInfo.environment["CineShoot_ProUnlocked"]
        if debugOverride == "0" {
            // fall through to normal StoreKit flow
        } else {
            isPro = true
            return
        }
        #endif

        // Start the listener and product/entitlement check together.
        // TestFlight detection happens inside the Task via AppTransaction.shared,
        // which is the correct StoreKit 2 API. The listener is started first so no
        // transactions are missed while the async check runs.
        transactionListenerTask = listenForTransactions()

        Task { [weak self] in
            #if !DEBUG
            if await Self.isTestFlightEnvironment() {
                self?.isPro = true
                return
            }
            #endif
            await self?.loadProduct()
            await self?.refreshPurchaseStatus()
        }
    }

    /// Returns `true` when running in the StoreKit sandbox (TestFlight).
    /// Uses AppTransaction.shared — the correct StoreKit 2 API for environment detection.
    nonisolated private static func isTestFlightEnvironment() async -> Bool {
        guard let result = try? await AppTransaction.shared else { return false }
        guard case .verified(let tx) = result else { return false }
        return tx.environment == .xcode ? false : tx.environment == .sandbox
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
