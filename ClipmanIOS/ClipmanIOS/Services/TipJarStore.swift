import StoreKit
import SwiftUI
import UIKit

@MainActor
final class TipJarStore: ObservableObject {
    static let productIDs = [
        "me.onj.clipman.ios.tip.small",
        "me.onj.clipman.ios.tip.medium",
        "me.onj.clipman.ios.tip.large"
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var message = "" {
        didSet {
            guard !message.isEmpty, UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    func buttonTitle(for product: Product) -> String {
        product.displayName + ", " + product.displayPrice
    }

    func loadProducts() async {
        guard products.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted {
                let left = Self.productIDs.firstIndex(of: $0.id) ?? Int.max
                let right = Self.productIDs.firstIndex(of: $1.id) ?? Int.max
                return left < right
            }
            message = products.isEmpty ? "Tip options are currently unavailable." : ""
        } catch {
            message = "Tip options are currently unavailable."
        }
    }

    func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    message = "Thank you for supporting Clipman."
                case .unverified:
                    message = "The purchase could not be verified."
                }
            case .pending:
                message = "The tip is awaiting approval."
            case .userCancelled:
                message = ""
            @unknown default:
                message = "The tip could not be completed."
            }
        } catch {
            message = "The tip could not be completed."
        }
    }
}
