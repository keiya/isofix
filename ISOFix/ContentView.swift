import SwiftUI
import AVFoundation
import Photos

struct ContentView: View {
    @StateObject private var cameraModel = CameraModel()
    
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
            // 最高品質の設定を選択
            if let highestQualityFormat = backCamera.formats
                .filter({ $0.isVideoStabilizationModeSupported(.auto) })
                .max(by: { first, second in
                    let firstDimensions = CMVideoFormatDescriptionGetDimensions(first.formatDescription)
                    let secondDimensions = CMVideoFormatDescriptionGetDimensions(second.formatDescription)
                    return firstDimensions.width * firstDimensions.height < secondDimensions.width * secondDimensions.height
                }) {
                try backCamera.lockForConfiguration()
                backCamera.activeFormat = highestQualityFormat
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
            }
            
            // Debug: Print all available RAW photo pixel format types
            print("Available RAW Photo Pixel Format Types: \(photoOutput.availableRawPhotoPixelFormatTypes)")

            // Check for supported RAW formats
            if let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
                // Optionally, set max dimensions based on RAW format capabilities
                photoOutput.maxPhotoDimensions = CMVideoDimensions(width: 4032, height: 3024)
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
        
        if isProRAWEnabled {
            // ProRAWフォーマットを使用
            guard let proRAWFormat = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) else {
                print("ProRAW format not available")
                return
            }
            settings = AVCapturePhotoSettings(rawPixelFormatType: proRAWFormat)
        } else if let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            // 通常のRAWフォーマットを使用
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        } else {
            // RAWがサポートされていない場合はHEIFで撮影
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        
        if let device = currentDevice {
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            settings.maxPhotoDimensions = CMVideoDimensions(width: dimensions.width, height: dimensions.height)
            print("Setting max photo dimensions to: \(dimensions.width)x\(dimensions.height)")
        }
        
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
