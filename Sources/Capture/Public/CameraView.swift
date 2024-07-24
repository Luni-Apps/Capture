//
//  CameraView.swift
//  Capture
//
//  Created by Quentin Fasquel on 07/11/2023.
//

import SwiftUI
import AVKit

public struct CameraViewOptions {
    public private(set) static var `default` = CameraViewOptions()
    var automaticallyRequestAuthorization: Bool = true
    var isTakePictureFeedbackEnabled: Bool = true
}

public struct CameraView<CameraOverlay: View>: View {

    @Binding var outputImage: PlatformImage?
    @Binding var outputPhoto: AVCapturePhoto?
    @Binding var outputVideo: URL?
    var options: CameraViewOptions
    var cameraOverlay: ((AVAuthorizationStatus) -> CameraOverlay)

    @Environment(\.recordingSettings) private var recordingSettings
    @StateObject private var camera: Camera

    @State private var authorizationStatus: AVAuthorizationStatus
    @State private var outputSize: CGSize = CGSize(width: 1080, height: 1920)
    @State private var showsTakePictureFeedback: Bool = false

    private enum OutputPictureMode { case uiImage, avCapturePhoto }
    private var outputPictureMode: OutputPictureMode

    public init(
        camera: Camera = .default,
        outputImage: Binding<PlatformImage?> = .constant(nil),
        outputVideo: Binding<URL?> = .constant(nil),
        options: CameraViewOptions = .default,
        @ViewBuilder overlay: @escaping ((AVAuthorizationStatus) -> CameraOverlay)
    ) {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        _authorizationStatus = State(initialValue: authorizationStatus)
        _camera = StateObject(wrappedValue: camera)
        _outputImage = outputImage
        _outputPhoto = .constant(nil)
        _outputVideo = outputVideo
        self.options = options
        self.outputPictureMode = .uiImage
        self.cameraOverlay = overlay
    }

    public init(
        camera: Camera = .default,
        outputPhoto: Binding<AVCapturePhoto?> = .constant(nil),
        outputVideo: Binding<URL?> = .constant(nil),
        options: CameraViewOptions = .default,
        @ViewBuilder overlay: @escaping ((AVAuthorizationStatus) -> CameraOverlay)
    ) {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        _authorizationStatus = State(initialValue: authorizationStatus)
        _camera = StateObject(wrappedValue: camera)
        _outputImage = .constant(nil)
        _outputPhoto = outputPhoto
        _outputVideo = outputVideo
        self.options = options
        self.outputPictureMode = .avCapturePhoto
        self.cameraOverlay = overlay
    }


    public var body: some View {
        ZStack {
            if case .authorized = authorizationStatus {
                CaptureVideoPreview(isPaused: camera.isPreviewPaused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showsTakePictureFeedback {
                takePictureFeedback()
            }

            cameraOverlay(authorizationStatus)
        }
        .environmentObject(camera)
        .environment(\.takePicture, TakePictureAction { previewHandler in
//            if options.isTakePictureFeedbackEnabled {
//                showsTakePictureFeedback = true
//            }

            switch outputPictureMode {
                case .uiImage:
                    outputImage = await camera.takePicture(outputSize: outputSize, previewHandler)
                case .avCapturePhoto:
                    do {
                        outputPhoto = try await camera.takePicture(previewHandler)
                    } catch {
                        logger.error("Failed taking picture")
                    }
            }

//            showsTakePictureFeedback = false
        })
        .environment(\.recordVideo, RecordVideoAction(start: camera.startRecording) {
            outputVideo = await camera.stopRecording()
        })
        .onChange(of: recordingSettings) { recordingSettings in
            camera.updateRecordingSettings(recordingSettings)
        }
        .onChange(of: outputPhoto) { _ in
            guard options.isTakePictureFeedbackEnabled else { return }
            showsTakePictureFeedback = true
        }
        .onAppear {
            camera.updateRecordingSettings(recordingSettings)
            if options.automaticallyRequestAuthorization {
                Task {
                    await requestAuthorizationThenStart()
                }
            }
        }
    }

    // MARK: - Authorization Handling

    @MainActor func requestAuthorizationThenStart() async {
#if targetEnvironment(simulator)
        authorizationStatus = .denied
#else
        await camera.start()
        // Update auhtorization status
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
#endif
    }
    
    // MARK: - Subviews

    private func takePictureFeedback() -> some View {
        Color.black.ignoresSafeArea().task {
            try? await Task.sleep(for: .milliseconds(100))
            showsTakePictureFeedback = false
        }
    }
}
