import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct PickedImageFile: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { receivedFile in
            let fileExtension = receivedFile.file.pathExtension
            let destinationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Picture-Marker-Source-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension.isEmpty ? "image" : fileExtension)

            try FileManager.default.copyItem(
                at: receivedFile.file,
                to: destinationURL
            )
            return PickedImageFile(fileURL: destinationURL)
        }
    }
}

final class EditableImageAsset: @unchecked Sendable {
    let originalFileURL: URL
    let originalImageSize: CGSize
    let previewImage: UIImage

    init(
        originalFileURL: URL,
        originalImageSize: CGSize,
        previewImage: UIImage
    ) {
        self.originalFileURL = originalFileURL
        self.originalImageSize = originalImageSize
        self.previewImage = previewImage
    }

    deinit {
        try? FileManager.default.removeItem(at: originalFileURL)
    }
}

final class ExportedImageArtifact: @unchecked Sendable {
    let fileURL: URL
    let previewImage: UIImage
    let pixelSize: CGSize

    init(fileURL: URL, previewImage: UIImage, pixelSize: CGSize) {
        self.fileURL = fileURL
        self.previewImage = previewImage
        self.pixelSize = pixelSize
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum ImageAssetLoader {
    static let editorPreviewMaxPixelSize = 1_600

    static func makeEditableAsset(from fileURL: URL) throws -> EditableImageAsset {
        guard let imageSource = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let originalImageSize = orientedPixelSize(from: imageSource),
        let previewImage = downsample(
            imageSource: imageSource,
            maxPixelSize: editorPreviewMaxPixelSize
        ) else {
            throw ImageAssetError.unreadableImage
        }

        return EditableImageAsset(
            originalFileURL: fileURL,
            originalImageSize: originalImageSize,
            previewImage: previewImage
        )
    }

    static func downsample(
        fileURL: URL,
        maxPixelSize: Int
    ) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }

        return downsample(
            imageSource: imageSource,
            maxPixelSize: maxPixelSize
        )
    }

    private static func downsample(
        imageSource: CGImageSource,
        maxPixelSize: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: thumbnail, scale: 1, orientation: .up)
    }

    private static func orientedPixelSize(
        from imageSource: CGImageSource
    ) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            imageSource,
            0,
            nil
        ) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
        width > 0,
        height > 0 else {
            return nil
        }

        let orientation = (
            properties[kCGImagePropertyOrientation] as? NSNumber
        )?.intValue ?? 1
        let swapsDimensions = (5...8).contains(orientation)

        return CGSize(
            width: swapsDimensions ? height : width,
            height: swapsDimensions ? width : height
        )
    }
}

private enum ImageAssetError: Error {
    case unreadableImage
}
