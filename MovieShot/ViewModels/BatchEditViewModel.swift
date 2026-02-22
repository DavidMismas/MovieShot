import Combine
import CoreImage
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class BatchEditViewModel: ObservableObject {
    @Published var pickerItems: [PhotosPickerItem] = []
    @Published var selectedPreset: MoviePreset = .matrix
    @Published private(set) var isProcessing = false
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var processedCount = 0
    @Published private(set) var failedCount = 0
    @Published var statusMessage: String?

    private var processingTask: Task<Void, Never>?

    deinit {
        processingTask?.cancel()
    }

    var selectedItemCount: Int {
        pickerItems.count
    }

    func processBatch(isProUnlocked: Bool) {
        guard !isProcessing else { return }
        guard !pickerItems.isEmpty else {
            statusMessage = "Select at least one photo."
            return
        }
        guard isProUnlocked || !selectedPreset.isProLocked else {
            statusMessage = "Selected preset requires Pro."
            return
        }

        statusMessage = nil
        progress = 0.0
        processedCount = 0
        failedCount = 0
        isProcessing = true

        let items = pickerItems
        let preset = selectedPreset
        let jpegCompressionQuality = Self.jpegCompressionQualityFromPreferences()
        processingTask?.cancel()

        processingTask = Task(priority: .userInitiated) {
            let authorization = await Self.requestPhotoLibraryAuthorization()
            guard authorization == .authorized || authorization == .limited else {
                isProcessing = false
                statusMessage = "Photo save permission denied."
                return
            }

            let ciContext = CIContext(options: [.useSoftwareRenderer: false])
            let imageWorker = ImageWorker(context: ciContext)
            var processed = 0
            var failed = 0

            for (index, item) in items.enumerated() {
                if Task.isCancelled {
                    break
                }

                do {
                    guard let image = try await Self.loadImage(from: item) else {
                        failed += 1
                        processedCount = processed
                        failedCount = failed
                        progress = Double(index + 1) / Double(items.count)
                        continue
                    }

                    let normalized = await imageWorker.normalizedUpOrientation(for: image)

                    let exportData = await Task.detached(priority: .userInitiated) {
                        Self.renderPresetJPEGData(
                            from: normalized,
                            preset: preset,
                            context: ciContext,
                            compressionQuality: jpegCompressionQuality
                        )
                    }.value

                    guard let exportData else {
                        failed += 1
                        processedCount = processed
                        failedCount = failed
                        progress = Double(index + 1) / Double(items.count)
                        continue
                    }

                    let saved = await Self.saveToPhotoLibrary(
                        data: exportData,
                        uniformTypeIdentifier: UTType.jpeg.identifier
                    )

                    if saved {
                        processed += 1
                    } else {
                        failed += 1
                    }
                } catch {
                    failed += 1
                }

                processedCount = processed
                failedCount = failed
                progress = Double(index + 1) / Double(items.count)
            }

            isProcessing = false
            processingTask = nil
            processedCount = processed
            failedCount = failed

            if processed > 0 && failed == 0 {
                statusMessage = "Saved \(processed) photos."
            } else if processed > 0 {
                statusMessage = "Saved \(processed) photos, \(failed) failed."
            } else if failed > 0 {
                statusMessage = "No photos were saved."
            } else {
                statusMessage = "Batch canceled."
            }
        }
    }

    private nonisolated static func jpegCompressionQualityFromPreferences() -> CGFloat {
        let storedValue = UserDefaults.standard.object(forKey: "editor.exportJPEGQualityPercent") as? Int ?? 95
        let clamped = min(max(storedValue, 70), 100)
        return CGFloat(clamped) / 100.0
    }

    private nonisolated static func requestPhotoLibraryAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func loadImage(from item: PhotosPickerItem) async throws -> UIImage? {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            return nil
        }
        return UIImage(data: data)
    }

    private nonisolated static func renderPresetJPEGData(
        from image: UIImage,
        preset: MoviePreset,
        context: CIContext,
        compressionQuality: CGFloat
    ) -> Data? {
        guard let inputCI = CIImage(image: image) else { return nil }

        let outputCI = EditorViewModel.applyFilterChainStatic(
            to: inputCI,
            preset: preset,
            applyPreset: true,
            exposure: 0.0,
            contrast: 0.0,
            shadows: 0.0,
            highlights: 0.0,
            cropOption: .original,
            cropOffset: .zero
        )

        guard let cgImage = context.createCGImage(outputCI, from: outputCI.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: compressionQuality)
    }

    private nonisolated static func saveToPhotoLibrary(
        data: Data,
        uniformTypeIdentifier: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = uniformTypeIdentifier
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
