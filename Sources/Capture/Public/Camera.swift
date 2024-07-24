//
//  Camera.swift
//  Capture
//
//  Created by Quentin Fasquel on 17/12/2023.
//

@_exported import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit.UIDevice
#endif

public enum CameraError: Error {
    case missingPhotoOutput
    case missingVideoOutput
}

public final class Camera: NSObject, ObservableObject {

    public static let `default` = Camera(.back)

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "\(bundleIdentifier).Camera.Session")
    private let sessionPreset: AVCaptureSession.Preset

    private let previewQueue = DispatchQueue(
      label: "\(bundleIdentifier).Camera.VideoOutput",
      qos: .userInitiated,
      attributes: [],
      autoreleaseFrequency: .workItem
    )

    private var isCaptureSessionConfigured = false

    public private(set) var captureDevice: AVCaptureDevice? {
        didSet {
            if captureDevice != oldValue, let captureDevice {
                Task { @MainActor in
                    deviceId = captureDevice.uniqueID
                    captureDeviceDidChange(captureDevice)
                }
            }
        }
    }

    private var captureMovieFileOutput: AVCaptureMovieFileOutput?
    private var capturePhotoOutput: AVCapturePhotoOutput?
    private var captureVideoDataOutput: AVCaptureVideoDataOutput?
    private var captureVideoInput: AVCaptureDeviceInput?
    private var captureVideoFileOutput: AVCaptureVideoFileOutput?

    private var didStopRecording: ((Result<URL, Error>) -> Void)?
    private var didTakePicture: [(Result<AVCapturePhoto, Error>) -> Void] = []

    // MARK: - Internal Properties
    
    var devicePosition: CameraPosition
    var recordingSettings: RecordingSettings?
    var isAudioEnabled: Bool
    var isWideAngleEnabled: Bool

    // MARK: - Public API

    public private(set) var previewLayer: AVCaptureVideoPreviewLayer

    private var previewPixelBuffer: CVPixelBuffer?

    @Published public var flashMode: FlashMode
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var isPreviewPaused: Bool = false
    @Published public private(set) var devices: [AVCaptureDevice] = []
    @Published public var deviceId: String = "" {
        didSet {
            if deviceId != captureDevice?.uniqueID {
                captureDevice = devices.first(where: { $0.uniqueID == deviceId })
            }
        }
    }

    ///
    /// Instantiate a Camera instance with a high capture session preset
    /// - parameter position: the initial AVCaptureDevice.Position to use
    /// - parameter audioEnabled: whether audio should be enabled when recording videos. The default value is `true`.
    /// Typically set this value to `false` when using the Camera to only take pictures, avoiding to requesting audio permissions.
    /// - parameter wideAngleEnabled: whether camera devices with a wide angle (or ultra wide angle) should be supported.
    /// This parameter only affects iOS. The default value is `true`.
    ///
    public convenience init(
        _ position: CameraPosition,
        audioEnabled: Bool = true,
        wideAngleEnabled: Bool = true
    ) {
        self.init(
            position: position,
            preset: .high,
            audioEnabled: audioEnabled,
            wideAngleEnabled: wideAngleEnabled
        )
    }

    ///
    /// Instantiate a Camera instance
    /// - parameter position: the initial AVCaptureDevice.Position to use
    /// - parameter preset: the capture session's preset to use
    /// - parameter audioEnabled: whether audio should be enabled when recording videos. The default value is `true`.
    /// Typically set this value to `false` when using the Camera to only take pictures, avoiding to requesting audio permissions.
    /// - parameter wideAngleEnabled: whether camera devices with a wide angle (or ultra wide angle) should be supported.
    /// This parameter only affects iOS. The default value is `true`.
    ///
    public required init(
        position: CameraPosition,
        preset: AVCaptureSession.Preset,
        audioEnabled: Bool = true,
        wideAngleEnabled: Bool = true,
        initialFlashMode: FlashMode = .off
    ) {
        devicePosition = position
        sessionPreset = preset
        isAudioEnabled = audioEnabled
        isWideAngleEnabled = wideAngleEnabled
        flashMode = initialFlashMode
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        super.init()
        #if os(iOS)
        Task { @MainActor in
            registerDeviceOrientationObserver()
        }
        #endif
        devices = availableCaptureDevices
    }
    
    deinit {
        #if os(iOS)
        Task { @MainActor in
            // Stop observing device orientation
            Self.stopObservingDeviceOrientation()
        }
        #endif
        print(#function, self)
    }

    public func start() async {
        guard await checkAuthorization() else {
            logger.error("Camera access was not authorized.")
            return
        }

        guard !captureSession.isRunning else {
            logger.info("Camera is already running")
            return
        }

        if isCaptureSessionConfigured {
            return startCaptureSession()
        }

        sessionQueue.async { [self] in
            guard configureCaptureSession() else {
                return
            }

            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    public func stop() {
        guard isCaptureSessionConfigured else {
            return
        }

        stopCaptureSession()
    }

    @MainActor
    public func pause() {
        isPreviewPaused = true
    }

    @MainActor
    public func resume() {
        isPreviewPaused = false
        Task { await start() }
    }

    public func setCaptureDevice(_ device: AVCaptureDevice) {
        captureDevice = device
    }
    
    public func switchCaptureDevice() {
        switch captureDevice?.position {
        case .back:
            updateCaptureDevice(forDevicePosition: .front)
        case .front:
            updateCaptureDevice(forDevicePosition: .back)
        default:
            break
        }
    }
    
    // MARK: Capture Action

    internal func updateRecordingSettings(_ newRecordingSettings: RecordingSettings?) {
        guard recordingSettings != newRecordingSettings else {
            return
        }

        recordingSettings = newRecordingSettings

        guard isCaptureSessionConfigured else {
            // else it will be applied during session configuration
            return
        }

        sessionQueue.async { [self] in
            updateCaptureVideoOutput(newRecordingSettings)
        }
    }

    public func startRecording() {
        guard !isRecording else {
            return
        }

        sessionQueue.async { [self] in
            let temporaryDirectory = FileManager.default.temporaryDirectory

            if let videoOutput = captureVideoFileOutput {
                let outputURL = temporaryDirectory.appending(component: "\(Date.now).mp4")
                videoOutput.startRecording(to: outputURL, recordingDelegate: self)
            } else if let videoOutput = captureMovieFileOutput {
                let outputURL = temporaryDirectory.appending(component: "\(Date.now).mov")
                videoOutput.startRecording(to: outputURL, recordingDelegate: self)
            }
        }
    }

    public func stopRecording() async throws -> URL {
        guard let videoOutput: CaptureRecording = captureVideoFileOutput ?? captureMovieFileOutput else {
            throw CameraError.missingVideoOutput
        }

        defer { didStopRecording = nil }

        return try await withCheckedThrowingContinuation { continuation in
            didStopRecording = { continuation.resume(with: $0) }
            sessionQueue.async {
                videoOutput.stopRecording()
            }
        }
    }

    public func takePicture(_ previewHandler: ((Int64, CGImage?) -> Void)? = nil) async throws -> AVCapturePhoto {
        guard let photoOutput = capturePhotoOutput else {
            throw CameraError.missingPhotoOutput
        }

        let photoSettings = photoOutput.photoSettings()
        if captureDevice?.hasFlash == true {
            photoSettings.flashMode = flashMode
        }
        if let photoOutputConnection = photoOutput.connection(with: .video) {
            let deviceOrientation = await UIDevice.current.orientation
            let videoOrientation = AVCaptureVideoOrientation(deviceOrientation)
            photoOutputConnection.videoOrientation = videoOrientation
        }
        previewHandler?(photoSettings.uniqueID, CGImage.create(from: previewPixelBuffer))

        return try await withCheckedThrowingContinuation { continuation in
            didTakePicture.insert({ continuation.resume(with: $0) }, at: 0)
            sessionQueue.async {
                photoOutput.capturePhoto(with: photoSettings, delegate: self)
            }
        }
    }

    // MARK: - Capture Device Management

    private lazy var discoverySession: AVCaptureDevice.DiscoverySession = {
#if os(iOS)
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInDualCamera,
            .builtInLiDARDepthCamera,
            .builtInTelephotoCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera,
        ]

        if isWideAngleEnabled {
            deviceTypes.append(contentsOf: [
                .builtInDualWideCamera,
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
            ])
        }

        if #available(iOS 17, *) {
            deviceTypes.append(.continuityCamera)
        }
#elseif os(macOS)
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .deskViewCamera,
        ]

        if #available(macOS 14.0, *) {
            deviceTypes.append(.continuityCamera)
            deviceTypes.append(.external)
        }
#endif
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
    }()

    private var backCaptureDevices: [AVCaptureDevice] {
        discoverySession.devices.filter { $0.position == .back }
    }

    private var frontCaptureDevices: [AVCaptureDevice] {
        discoverySession.devices.filter { $0.position == .front }
    }
    
    private var captureDevices: [AVCaptureDevice] {
        var devices = [AVCaptureDevice]()
#if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
        devices += discoverySession.devices
#else

        let defaultDevice = AVCaptureDevice.default(for: .video)
        if let defaultDevice {
            devices.append(defaultDevice)
        }

        if let backDevice = backCaptureDevices.first, backDevice != defaultDevice {
            devices += [backDevice]
        }
        if let frontDevice = frontCaptureDevices.first, frontDevice != defaultDevice {
            devices += [frontDevice]
        }
#endif
        return devices
    }
    
    private var availableCaptureDevices: [AVCaptureDevice] {
        captureDevices.filter { $0.isConnected && !$0.isSuspended }.unique()
    }

    private var isUsingFrontCaptureDevice: Bool {
        guard let captureDevice else { return false }
        return frontCaptureDevices.contains(captureDevice)
    }
    
    private var isUsingBackCaptureDevice: Bool {
        guard let captureDevice else { return false }
        return backCaptureDevices.contains(captureDevice)
    }
    
    private func updateCaptureDevice(forDevicePosition devicePosition: AVCaptureDevice.Position) {
        if case .unspecified = devicePosition {
            captureDevice = AVCaptureDevice.default(for: .video)
        } else if let device = captureDevices.first(where: { $0.position == devicePosition }) {
            captureDevice = device
        } else {
            logger.warning("Couldn't update capture device for \(String(describing: devicePosition))")
        }
    }

    // MARK: - Authorization Handling

    public var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    @discardableResult
    func checkAuthorization() async -> Bool {
        switch authorizationStatus {
            case .authorized:
                return true
            case .notDetermined:
                logger.debug("Camera access not determined.")
                sessionQueue.suspend()
                let status = await AVCaptureDevice.requestAccess(for: .video)
                sessionQueue.resume()
                if status {
                    logger.debug("Camera access authorized.")
                }
                return status
            case .denied:
                logger.debug("Camera access denied.")
                return false
            case .restricted:
                logger.debug("Camera library access restricted.")
                return false
            @unknown default:
                return false
        }
    }

    // MARK: - Capture Session Configuration

    private var videoConnections: [AVCaptureConnection] {
        captureSession.outputs.compactMap { $0.connection(with: .video) }
    }

    private func configureCaptureSession() -> Bool {
        guard case .authorized = authorizationStatus else {
            return false
        }

        updateCaptureDevice(forDevicePosition: devicePosition)

        guard let captureDevice else {
            log(.cameraDeviceNotSet)
            return false
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if captureSession.canSetSessionPreset(sessionPreset) {
            captureSession.sessionPreset = sessionPreset
        } else {
            captureSession.sessionPreset = .high
            log(.cannotSetSessionPreset)
        }

        // Adding video input (used for both photo and video capture)
        let videoInput = AVCaptureDeviceInput(device: captureDevice, logger: logger)
        if let videoInput, captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
            captureVideoInput = videoInput
        } else {
            log(.cannotAddVideoInput)
        }

        // Configure photo capture
        let photoOutput = AVCapturePhotoOutput()
        photoOutput.maxPhotoQualityPrioritization = .quality
//        if #available(iOS 17.0, *), photoOutput.isAutoDeferredPhotoDeliverySupported {
//            photoOutput.isAutoDeferredPhotoDeliveryEnabled = true
//        }
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            capturePhotoOutput = photoOutput
        } else {
            log(.cannotAddPhotoOutput)
        }

        // Configure video capture
        if isAudioEnabled {
            let audioDevice = AVCaptureDevice.default(for: .audio)
            let audioInput = AVCaptureDeviceInput(device: audioDevice, logger: logger)
            if let audioInput, captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            } else {
                log(.cannotAddAudioInput)
            }
        }

        updateCaptureVideoOutput(recordingSettings)

        isCaptureSessionConfigured = true
        return true
    }
    
    private func updateCaptureVideoInput(_ cameraDevice: AVCaptureDevice) {
        guard case .authorized = authorizationStatus else {
            return
        }

        guard isCaptureSessionConfigured else {
            if configureCaptureSession(), !isPreviewPaused {
                startCaptureSession()
            }
            return
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Remove current camera input
        if let videoInput = captureVideoInput {
            captureSession.removeInput(videoInput)
            captureVideoInput = nil
        }

        // Add new camera input
        let videoInput = AVCaptureDeviceInput(device: cameraDevice, logger: logger)
        if let videoInput, captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
            captureVideoInput = videoInput
        }

        updateCaptureOutputMirroring()
        updateCaptureOutputOrientation()
    }

    private func updateCaptureVideoOutput(_ recordingSettings: RecordingSettings?) {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if let recordingSettings, let captureVideoFileOutput {
            captureVideoFileOutput.configureOutput(
                audioSettings: recordingSettings.audio,
                videoSettings: recordingSettings.video
            )
        } else if let recordingSettings {
            if let movieFileOutput = captureMovieFileOutput {
                captureSession.removeOutput(movieFileOutput)
                captureMovieFileOutput = nil
            }

            let videoFileOutput = AVCaptureVideoFileOutput()
            videoFileOutput.configureOutput(
                audioSettings: recordingSettings.audio,
                videoSettings: recordingSettings.video
            )
            if captureSession.canAddOutput(videoFileOutput) {
                captureSession.addOutput(videoFileOutput)
                captureVideoFileOutput = videoFileOutput
            } else {
                log(.cannotAddVideoFileOutput)
            }

        } else if captureMovieFileOutput == nil {
            if let videoFileOutput = captureVideoFileOutput {
                captureSession.removeOutput(videoFileOutput)
                captureVideoFileOutput = nil
            }

            let moveFileOutput = AVCaptureMovieFileOutput()
            if captureSession.canAddOutput(moveFileOutput) {
                captureSession.addOutput(moveFileOutput)
                captureMovieFileOutput = moveFileOutput
            } else {
                log(.cannotAddVideoFileOutput)
            }
        }

        if captureVideoDataOutput == nil {
            let videoDataOutput = AVCaptureVideoDataOutput()
            videoDataOutput.setSampleBufferDelegate(self, queue: previewQueue)
            if captureSession.canAddOutput(videoDataOutput) {
                captureSession.addOutput(videoDataOutput)
                captureVideoDataOutput = videoDataOutput
            }
        }

        updateCaptureOutputMirroring()
        updateCaptureOutputOrientation()
    }

    private func updateCaptureOutputMirroring() {
        let isVideoMirrored = isUsingFrontCaptureDevice
        videoConnections.forEach { videoConnection in
            if videoConnection.isVideoMirroringSupported {
                videoConnection.isVideoMirrored = isVideoMirrored
            }
        }
    }


    private func updateCaptureOutputOrientation() {
#if os(iOS)
        var deviceOrientation = UIDevice.current.orientation
        logger.debug("Updating capture outputs video orientation: \(String(describing: deviceOrientation))")
        if case .unknown = deviceOrientation {
            // Fix device orientation using's screen coordinate space
            deviceOrientation = UIScreen.main.deviceOrientation
        }

        videoConnections.forEach { videoConnection in
            if videoConnection.isVideoOrientationSupported {
                videoConnection.videoOrientation = AVCaptureVideoOrientation(deviceOrientation)
            }
        }
#elseif os(macOS)
#endif
    }


    private func startCaptureSession() {
#if os(iOS)
        Task { @MainActor in
            Self.startObservingDeviceOrientation()
        }
#endif
        if !captureSession.isRunning {
            sessionQueue.async {
                self.captureSession.startRunning()
            }
        }
    }
    
    private func stopCaptureSession() {
#if os(iOS)
        Task { @MainActor in
            Self.stopObservingDeviceOrientation()
        }
#endif
        if captureSession.isRunning {
            sessionQueue.async {
                self.captureSession.stopRunning()
            }
        }
    }

    // MARK: -

    public var isVideoMirrored: Bool {
        videoConnections.first?.isVideoMirrored ?? false
    }

    // MARK: - Device Orientation Handling
#if os(iOS)
    private var deviceOrientationObserver: NSObjectProtocol?

    @MainActor private func registerDeviceOrientationObserver() {
        deviceOrientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: UIDevice.current,
            queue: .main
        ) { [weak self] notification in
            self?.updateCaptureOutputOrientation()
        }
    }

    @MainActor private static func startObservingDeviceOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    @MainActor private static func stopObservingDeviceOrientation() {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
#endif

    // MARK: - Private Methods

    private func captureDeviceDidChange(_ newCaptureDevice: AVCaptureDevice) {
        logger.debug("Using capture device: \(newCaptureDevice.localizedName)")
        sessionQueue.async { [self] in
            updateCaptureVideoInput(newCaptureDevice)
        }
    }
    
}

// MARK: - File Output Recording Delegate

extension Camera: AVCaptureFileOutputRecordingDelegate {

    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        isRecording = true
    }
    
    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        isRecording = false
        if let error {
            didStopRecording?(.failure(error))
        } else {
            didStopRecording?(.success(outputFileURL))
        }
    }
}

// MARK: - Video File Output Recording Delegate

extension Camera: AVCaptureVideoFileOutputRecordingDelegate {

    func videoFileOutput(
        _ output: AVCaptureVideoFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        isRecording = true
    }
    
    func videoFileOutput(
        _ output: AVCaptureVideoFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        isRecording = false
        if let error {
            didStopRecording?(.failure(error))
        } else {
            didStopRecording?(.success(outputFileURL))
        }
    }
}

// MARK: - Photo Capture Delegate

extension Camera: AVCapturePhotoCaptureDelegate {

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
//        if #available(iOS 17.0, *), output.isAutoDeferredPhotoDeliverySupported {
//            return // Do nothing
//        }
        if let didTakePicture = didTakePicture.popLast() {
            if let error {
                didTakePicture(.failure(error))
            } else {
                didTakePicture(.success(photo))
            }
        }
    }

//    @available(iOS 17.0, *)
//    public func photoOutput(
//        _ output: AVCapturePhotoOutput,
//        didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
//        error: (any Error)?
//    ) {
//        if let deferredPhotoProxy, let didTakePicture = didTakePicture.popLast() {
//            if let error {
//                didTakePicture(.failure(error))
//            } else {
//                didTakePicture(.success(deferredPhotoProxy))
//            }
//        }
//    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let buffer = sampleBuffer.imageBuffer {
            DispatchQueue.main.async {
                self.previewPixelBuffer = buffer
            }
        }
    }
}

import VideoToolbox

extension CGImage {
    static func create(from pixelBuffer: CVPixelBuffer?) -> CGImage? {
        guard let pixelBuffer else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil,imageOut: &image)
        return image
    }
}
