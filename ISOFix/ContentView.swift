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
    private let photoOutput = AVCapturePhotoOutput()
    private var currentZoomFactor: CGFloat = 1.0
    private var availableZoomFactors: [CGFloat] = [1.0]
    private var currentDevice: AVCaptureDevice?
    
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
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        currentDevice = backCamera
        
        do {
            let input = try AVCaptureDeviceInput(device: backCamera)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                
                // RAWフォーマットのサポートを確認
                if let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
                    print("RAW capture supported. Available formats: \(photoOutput.availableRawPhotoPixelFormatTypes)")
                } else {
                    print("RAW capture not supported on this device")
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
            
            // ISO設定を最低に固定
            backCamera.setExposureModeCustom(duration: backCamera.exposureDuration, iso: backCamera.activeFormat.minISO, completionHandler: nil)
            
            // ズームレベルの設定
            availableZoomFactors = backCamera.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
            availableZoomFactors.insert(1.0, at: 0)
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
        } catch {
            print("Error setting zoom: \(error.localizedDescription)")
        }
    }
    
    func finalizeZoom() {
        guard let device = currentDevice else { return }
        currentZoomFactor = device.videoZoomFactor
    }
    
    func capturePhoto() {
        let settings: AVCapturePhotoSettings
        
        if let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        } else {
            // RAWがサポートされていない場合はHEIFで撮影
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        
        settings.flashMode = .off
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        print("Photo output method called")
        
        guard error == nil else {
            print("Error capturing photo: \(error!.localizedDescription)")
            return
        }
        
        guard let rawFileData = photo.fileDataRepresentation() else {
            print("Unable to get RAW file data")
            return
        }
        
        print("Raw file data obtained, size: \(rawFileData.count) bytes")
        
        // Save to Photos
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            
            print("Photo library authorization status: \(status.rawValue)")
            
            switch status {
            case .authorized, .limited:
                self.savePhotoToLibrary(rawFileData)
            case .denied, .restricted:
                print("Photos access denied or restricted")
            case .notDetermined:
                print("Photos access not determined")
            @unknown default:
                print("Unknown authorization status")
            }
        }
    }
    
    private func savePhotoToLibrary(_ photoData: Data) {
        PHPhotoLibrary.shared().performChanges({
            print("Attempting to save photo to library")
            let options = PHAssetResourceCreationOptions()
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: photoData, options: options)
        }) { success, error in
            if success {
                print("Photo saved to Photos library successfully")
            } else if let error = error {
                print("Error saving photo to Photos library: \(error.localizedDescription)")
            }
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
