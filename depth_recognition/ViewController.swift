//
//  ViewController.swift
//  depth_recognition
//
//  Created by M'haimdat omar on 22-04-2020.
//  Copyright © 2020 M'haimdat omar. All rights reserved.
//

import UIKit
import AVKit
import Vision
import VideoToolbox
import CoreML

// MARK: - Drawing View

class DrawingView: UIView {
    
    var heatmap: Array<Array<Double>>? = nil {
        didSet {
            self.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
    
        if let ctx = UIGraphicsGetCurrentContext() {
            
            ctx.clear(rect);
            
            guard let heatmap = self.heatmap else { return }
            
            let size = self.bounds.size
            let heatmap_w = heatmap.count
            let heatmap_h = heatmap.first?.count ?? 0
            let w = size.width / CGFloat(heatmap_w)
            let h = size.height / CGFloat(heatmap_h)
            
            for j in 0..<heatmap_h {
                for i in 0..<heatmap_w {
                    let value = heatmap[i][j]
                    var alpha: CGFloat = CGFloat(value)
                    if alpha > 1 {
                        alpha = 1
                    } else if alpha < 0 {
                        alpha = 0
                    }
                    
                    let rect: CGRect = CGRect(x: CGFloat(i) * w, y: CGFloat(j) * h, width: w, height: h)
                    
                    // gray
                    let color: UIColor = UIColor(white: 1-alpha, alpha: 1)
                    
                    let bpath: UIBezierPath = UIBezierPath(rect: rect)
                    
                    color.set()
                    bpath.fill()
                }
            }
        }
    }
}

// MARK: - View Controller

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    // MARK: - Drawing View
    var drawingView: DrawingView = {
       let map = DrawingView()
        map.contentMode = .scaleToFill
        map.backgroundColor = .lightGray
        map.autoresizesSubviews = true
        map.clearsContextBeforeDrawing = true
        map.isOpaque = true
        map.translatesAutoresizingMaskIntoConstraints = false
        return map
    }()
    
    
    // MARK: - Entry point
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
        setupDrawingView()
    }
    
    // MARK: - Setup the Capture Session
    fileprivate func setupCamera() {
        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .vga640x480
        
        guard let captureDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) else { return }
                
        guard let input = try? AVCaptureDeviceInput(device: captureDevice) else { return }
        captureSession.addInput(input)
        
        captureSession.startRunning()
        
        captureDevice.configureDesiredFrameRate(50)
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspect
        previewLayer.connection?.videoOrientation = .portrait
        view.layer.addSublayer(previewLayer)
        previewLayer.frame = view.frame
        
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        captureSession.addOutput(dataOutput)
    }
    
    // MARK: - Setup the Drawing View and add it to the subview
    fileprivate func setupDrawingView() {
        view.addSubview(drawingView)
        drawingView.heightAnchor.constraint(equalToConstant: 304).isActive = true
        drawingView.widthAnchor.constraint(equalToConstant: 228).isActive = true
        drawingView.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        drawingView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        drawingView.rotate(degrees: 90)
    }
    
    // MARK: - Set and activate the haptic feedback
    fileprivate func haptic() {
        let impactFeedbackgenerator = UIImpactFeedbackGenerator(style: .heavy)
        impactFeedbackgenerator.prepare()
        impactFeedbackgenerator.impactOccurred()
    }
    
    // MARK: - Setup Capture Session Delegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard let pixelBuffer: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        guard let myModel = try? MLModel(contentsOf: FCRN.urlOfModelInThisBundle, configuration: config) else {
            fatalError("Unable to load model")
        }
        
        guard let model = try? VNCoreMLModel(for: myModel) else {
                    fatalError("Unable to load model")
                }
        
        let request = VNCoreMLRequest(model: model) { (request, error) in
            if let results = request.results as? [VNCoreMLFeatureValueObservation],
                let heatmap = results.first?.featureValue.multiArrayValue {
                
                let start = CFAbsoluteTimeGetCurrent()
                let (convertedHeatmap, convertedHeatmapInt) = self.convertTo2DArray(from: heatmap)
                let diff = CFAbsoluteTimeGetCurrent() - start
                
                 print("Convertion to 2D Took \(diff) seconds")
                DispatchQueue.main.async { [weak self] in
                    self?.drawingView.heatmap = convertedHeatmap
                    let start = CFAbsoluteTimeGetCurrent()
                    let average = Float32(convertedHeatmapInt.joined().reduce(0, +))/Float32(20480)
                    let diff = CFAbsoluteTimeGetCurrent() - start
                    print("Average Took \(diff) seconds")
                    
                    print(average)
                    if average > 0.35 {
                        self?.haptic()
                    }
                }
            } else {
                fatalError("Model failed to process image")
            }
        }
        
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        DispatchQueue.global().async {
            do {
                try handler.perform([request])
            } catch {
                print(error)
            }
        }
        
    }
    
}

extension ViewController {
    func convertTo2DArray(from heatmaps: MLMultiArray) -> (Array<Array<Double>>, Array<Array<Int>>) {
        guard heatmaps.shape.count >= 3 else {
            print("heatmap's shape is invalid. \(heatmaps.shape)")
            return ([], [])
        }
        let _/*keypoint_number*/ = heatmaps.shape[0].intValue
        let heatmap_w = heatmaps.shape[1].intValue
        let heatmap_h = heatmaps.shape[2].intValue
        
        var convertedHeatmap: Array<Array<Double>> = Array(repeating: Array(repeating: 0.0, count: heatmap_w), count: heatmap_h)
        
        var minimumValue: Double = Double.greatestFiniteMagnitude
        var maximumValue: Double = -Double.greatestFiniteMagnitude
        
        for i in 0..<heatmap_w {
            for j in 0..<heatmap_h {
                let index = i*(heatmap_h) + j
                let confidence = heatmaps[index].doubleValue
                guard confidence > 0 else { continue }
                convertedHeatmap[j][i] = confidence
                
                if minimumValue > confidence {
                    minimumValue = confidence
                }
                if maximumValue < confidence {
                    maximumValue = confidence
                }
            }
        }
        
        let minmaxGap = maximumValue - minimumValue
        
        for i in 0..<heatmap_w {
            for j in 0..<heatmap_h {
                convertedHeatmap[j][i] = (convertedHeatmap[j][i] - minimumValue) / minmaxGap
            }
        }
        
        var convertedHeatmapInt: Array<Array<Int>> = Array(repeating: Array(repeating: 0, count: heatmap_w), count: heatmap_h)
        for i in 0..<heatmap_w {
            for j in 0..<heatmap_h {
                if convertedHeatmap[j][i] >= 0.5 {
                    convertedHeatmapInt[j][i] = Int(1)
                } else {
                    convertedHeatmapInt[j][i] = Int(0)
                }
            }
        }
        
        return (convertedHeatmap,  convertedHeatmapInt)
    }
}


extension AVCaptureDevice {
    func configureDesiredFrameRate(_ desiredFrameRate: Int) {

        var isFPSSupported = false

        do {

            if let videoSupportedFrameRateRanges = activeFormat.videoSupportedFrameRateRanges as? [AVFrameRateRange] {
                for range in videoSupportedFrameRateRanges {
                    if (range.maxFrameRate >= Double(desiredFrameRate) && range.minFrameRate <= Double(desiredFrameRate)) {
                        isFPSSupported = true
                        break
                    }
                }
            }

            if isFPSSupported {
                try lockForConfiguration()
                activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(desiredFrameRate))
                activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(desiredFrameRate))
                unlockForConfiguration()
            }

        } catch {
            print("lockForConfiguration error: \(error.localizedDescription)")
        }
    }

}



