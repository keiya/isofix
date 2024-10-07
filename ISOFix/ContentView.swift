import SwiftUI
import AVFoundation
import Photos

struct ContentView: View {
    @StateObject private var cameraModel = CameraModel()
    @State private var exposureDurationIndex: Double = 6 // デフォルトのシャッター速度インデックス (1/60に相当)
    
    let exposureDurations: [Double] = [
        1/1000, 1/500, 1/250, 1/125, 1/60, 1/30, 1/15, 1/8, 1/4, 1/2, 1
    ]
    
    var body: some View {
        ZStack {
            CameraPreviewView(session: cameraModel.session)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        cameraModel.switchZoom()
                    }) {
                        Text(String(format: "%.1fx", cameraModel.currentZoomFactor))
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.top)
                    .padding(.trailing)
                }
                Spacer()
                HStack {
                    Button(action: {
                        cameraModel.capturePhoto()
                    }) {
                        Image(systemName: "camera")
                            .font(.largeTitle)
                            .padding()
                            .background(Color.white.opacity(0.7))
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom)

                // シャッター速度スライダー
                Slider(value: $exposureDurationIndex, in: 0...Double(exposureDurations.count - 1), step: 1) { _ in
                    let duration = exposureDurations[Int(exposureDurationIndex)]
                    cameraModel.setExposureDuration(duration)
                }
                .padding()
                .background(Color.black.opacity(0.7))
                .foregroundColor(.white)
                
                Text("1/\(Int(1/exposureDurations[Int(exposureDurationIndex)]))")
                    .foregroundColor(.white)
                    .padding(.bottom)
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    cameraModel.zoom(factor: value)
                }
                .onEnded { _ in
                    cameraModel.finalizeZoom()
                }
        )
    }
}

class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var session = AVCaptureSession()
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var isProRAWEnabled: Bool = false
    private let photoOutput = AVCapturePhotoOutput()
    private var availableZoomFactors: [CGFloat] = [1.0]
    private var currentDevice: AVCaptureDevice?
    private var zoomIndex: Int = 0
    
    override init() {
        super.init()
        checkCameraPermissions()
    }
    
    private func checkCameraPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    DispatchQueue.main.async {
                        self.setupSession()
                    }
                }
            }
        case .denied:
            print("Camera access denied")
        case .restricted:
            print("Camera access restricted")
        @unknown default:
            print("Unknown camera access status")
        }
    }
    
    private func setupSession() {
        // Attempt to use the multi-camera system if available
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )
        
        for camera in discoverySession.devices {
            do {
                try camera.lockForConfiguration()
                
                if camera.isExposureModeSupported(.custom) {
                    camera.setExposureModeCustom(duration: camera.exposureDuration, iso: camera.activeFormat.minISO, completionHandler: nil)
                } else {
                    print("Custom exposure mode is not supported on \(camera.localizedName)")
                }
                
                camera.unlockForConfiguration()
            } catch {
                print("Error configuring \(camera.localizedName): \(error.localizedDescription)")
            }
        }
        
        guard let backCamera = discoverySession.devices.first else {
            print("No back camera available")
            return
        }
        
        currentDevice = backCamera
        
        do {
            // Select the highest resolution format
            if let highestResolutionFormat = backCamera.formats
                .max(by: { first, second in
                    let firstDimensions = CMVideoFormatDescriptionGetDimensions(first.formatDescription)
                    let secondDimensions = CMVideoFormatDescriptionGetDimensions(second.formatDescription)
                    return firstDimensions.width * firstDimensions.height < secondDimensions.width * secondDimensions.height
                }) {
                try backCamera.lockForConfiguration()
                backCamera.activeFormat = highestResolutionFormat
                backCamera.unlockForConfiguration()
            }

            let input = try AVCaptureDeviceInput(device: backCamera)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)

                // ProRAWのサポートを確認
                if photoOutput.isAppleProRAWSupported {
                    photoOutput.isAppleProRAWEnabled = true
                    isProRAWEnabled = true
                    print("Apple ProRAW is supported and enabled")
                } else {
                    print("Apple ProRAW is not supported on this device")
                }

                // 最大解像度の設定
                if let maxDimensions = backCamera.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    photoOutput.maxPhotoDimensions = maxDimensions
                    print("Setting max photo dimensions to: \(maxDimensions.width)x\(maxDimensions.height)")
                } else {
                    print("Unable to determine max photo dimensions")
                }
            }

            // Debug: Print all available RAW photo pixel format types
            print("Available RAW Photo Pixel Format Types: \(photoOutput.availableRawPhotoPixelFormatTypes)")

            // Check for supported RAW formats
            if let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
                // Set max dimensions based on RAW format capabilities
                let dimensions = CMVideoFormatDescriptionGetDimensions(backCamera.activeFormat.formatDescription)
                photoOutput.maxPhotoDimensions = CMVideoDimensions(width: Int32(dimensions.width), height: Int32(dimensions.height))
                print("Setting max photo dimensions to: \(dimensions.width)x\(dimensions.height)")
            }

            try backCamera.lockForConfiguration()

            // ISOを最小に設定
            if backCamera.isExposureModeSupported(.custom) {
                backCamera.setExposureModeCustom(duration: backCamera.exposureDuration, iso: backCamera.activeFormat.minISO, completionHandler: nil)
            } else {
                print("Custom exposure mode is not supported on this device")
            }

            // ズームレベルの設定
            availableZoomFactors = [1.0] + backCamera.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
            availableZoomFactors = Array(Set(availableZoomFactors)).sorted()

            backCamera.unlockForConfiguration()

            session.startRunning()
        } catch {
            print("Error setting up camera: \(error.localizedDescription)")
        }
    }
    
    func zoom(factor: CGFloat) {
        guard let device = currentDevice else { return }
        let targetZoomFactor = factor * currentZoomFactor
        let closestZoomFactor = availableZoomFactors.min(by: { abs($0 - targetZoomFactor) < abs($1 - targetZoomFactor) }) ?? 1.0
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = closestZoomFactor
            device.unlockForConfiguration()
            DispatchQueue.main.async {
                self.currentZoomFactor = closestZoomFactor
            }
        } catch {
            print("Error setting zoom: \(error.localizedDescription)")
        }
    }
    
    func finalizeZoom() {
        guard let device = currentDevice else { return }
        DispatchQueue.main.async {
            self.currentZoomFactor = device.videoZoomFactor
        }
    }
    
    func capturePhoto() {
        let settings: AVCapturePhotoSettings

        if isProRAWEnabled, let proRAWFormat = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: proRAWFormat)
        } else if let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }

        // 最大解像度の設定
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        print("Capturing photo with dimensions: \(settings.maxPhotoDimensions.width)x\(settings.maxPhotoDimensions.height)")

        settings.flashMode = .off

        // Ensure photo quality prioritization does not exceed the maximum supported
        let maxQuality = photoOutput.maxPhotoQualityPrioritization
        settings.photoQualityPrioritization = (maxQuality.rawValue < AVCapturePhotoOutput.QualityPrioritization.quality.rawValue) ? maxQuality : .quality

        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        print("Photo output method called")
        
        guard error == nil else {
            print("Error capturing photo: \(error!.localizedDescription)")
            return
        }
        
        guard let photoData = photo.fileDataRepresentation() else {
            print("Unable to get photo file data")
            return
        }
        
        print("Photo data obtained, size: \(photoData.count) bytes")
        print("Is RAW photo: \(photo.isRawPhoto)")
        
        // Save to Photos
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            
            print("Photo library authorization status: \(status.rawValue)")
            
            switch status {
            case .authorized, .limited:
                self.savePhotoToLibrary(photoData, isRaw: photo.isRawPhoto)
            case .denied, .restricted:
                print("Photos access denied or restricted")
            case .notDetermined:
                print("Photos access not determined")
            @unknown default:
                print("Unknown authorization status")
            }
        }
    }
    
    private func savePhotoToLibrary(_ photoData: Data, isRaw: Bool) {
        PHPhotoLibrary.shared().performChanges({
            print("Attempting to save photo to library")
            let creationRequest = PHAssetCreationRequest.forAsset()
            
            if isRaw {
                // RAWまたはProRAW写真として保存
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                creationRequest.addResource(with: .photo, data: photoData, options: options)
            } else {
                // 処理済み写真として保存
                creationRequest.addResource(with: .photo, data: photoData, options: nil)
            }
        }) { success, error in
            if success {
                print("Photo saved to Photos library successfully")
            } else if let error = error {
                print("Error saving photo to Photos library: \(error.localizedDescription)")
            }
        }
    }
    
    func switchZoom() {
        guard let device = currentDevice else { return }

        // Get all available devices
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
        let availableDevices = discoverySession.devices

        // Find the index of the current device
        guard let currentIndex = availableDevices.firstIndex(of: device) else { return }

        // Move to the next device, wrapping around if necessary
        let nextIndex = (currentIndex + 1) % availableDevices.count
        let nextDevice = availableDevices[nextIndex]

        do {
            // Change the session's input to the new device
            session.beginConfiguration()
            
            // Remove the current input
            if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
                session.removeInput(currentInput)
            }
            
            // Add the new input
            let newInput = try AVCaptureDeviceInput(device: nextDevice)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
            }
            
            session.commitConfiguration()

            // Update the current device
            currentDevice = nextDevice

            // Calculate and update the zoom factor
            let newZoomFactor: CGFloat
            switch nextDevice.deviceType {
            case .builtInUltraWideCamera:
                newZoomFactor = 0.5
            case .builtInWideAngleCamera:
                newZoomFactor = 1.0
            case .builtInTelephotoCamera:
                newZoomFactor = 2.0
            default:
                newZoomFactor = 1.0
            }

            // Update the current zoom factor
            DispatchQueue.main.async {
                self.currentZoomFactor = newZoomFactor
            }

            // Keep ISO at minimum for the new device
            try nextDevice.lockForConfiguration()
            if nextDevice.isExposureModeSupported(.custom) {
                nextDevice.setExposureModeCustom(duration: nextDevice.exposureDuration, iso: nextDevice.activeFormat.minISO, completionHandler: nil)
            }
            nextDevice.unlockForConfiguration()

        } catch {
            print("Error switching camera: \(error.localizedDescription)")
        }
    }

    func setExposureDuration(_ duration: Double) {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            let newDuration = CMTime(seconds: duration, preferredTimescale: 1000000)
            device.setExposureModeCustom(duration: newDuration, iso: device.iso, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            print("Error setting exposure duration: \(error.localizedDescription)")
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}
