//
//  Camera+UIImage.swift
//  Capture
//
//  Created by Quentin Fasquel on 17/12/2023.
//

#if os(iOS)
import UIKit
#endif

extension Camera {
    func takePicture(outputSize: CGSize, _ previewHandler: ((Int64, CGImage?) -> Void)? = nil) async -> PlatformImage? {
        do {
            let capturePhoto = try await takePicture(previewHandler)
//            let captureId = capturePhoto.resolvedSettings.uniqueID
            let image = PlatformImage(photo: capturePhoto)
            return image
#if os(iOS)
//            return image?.fixOrientation().scaleToFill(in: outputSize)
#elseif os(macOS)
            return image?.scaleToFill(in: outputSize)
#endif
        } catch {
            return nil
        }
    }
}

extension Camera {
    func stopRecording() async -> URL? {
        do {
            return try await stopRecording() as URL
        } catch {
            return nil
        }
    }
}
