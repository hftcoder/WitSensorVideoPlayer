//
//  VideoPlayerView.swift
//  支持动态调节播放速度的视频播放器 + Vision 姿态/表情分析
//  Video player with dynamic playback speed control + Vision pose/expression analysis
//
//  分析功能：仰面/趴着检测 + 嘴里含物检测（精确版）
//

import SwiftUI
import AVKit
import AVFoundation
import Vision
import CoreBluetooth
import WitSDK
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
typealias UIImage = NSImage
#elseif os(iOS)
import UIKit
#endif

// MARK: - 姿态分析结果
struct PoseFrameResult: Identifiable {
    let id = UUID()
    let timestamp: Double
    let isFaceUp: Bool
    let isFaceDown: Bool
    let hasMouthOccupied: Bool
    let hasItemInHand: Bool
    let confidence: Double
}

// MARK: - 传感器控制时间段
struct SensorSegment: Identifiable {
    let id = UUID()
    let start: Double   // 秒
    let end: Double     // 秒
}

// MARK: - 播放速率动画器
class RateAnimator: ObservableObject {
    @Published var targetRate: Float = 1.0
    @Published private(set) var currentRate: Float = 1.0

    private var displayLink: CADisplayLink?
    private var lastUpdateTime: CFTimeInterval = 0
    private let smoothingFactor: Float = 0.08

    init() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
        displayLink?.add(to: .main, forMode: .common)
    }

    deinit {
        displayLink?.invalidate()
    }

    func setTarget(_ rate: Float) {
        targetRate = rate
    }

    func reset() {
        targetRate = 1.0
        currentRate = 1.0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        guard now - lastUpdateTime >= 1.0 / 60.0 else { return }
        lastUpdateTime = now

        let diff = targetRate - currentRate
        if abs(diff) > 0.001 {
            currentRate += diff * smoothingFactor
        } else {
            currentRate = targetRate
        }
    }
}

// MARK: - 视频分析器（后台线程）
class VideoAnalyzer: ObservableObject {

    func analyze(url: URL, frameInterval: Double, progress: @escaping (Double) -> Void, completion: @escaping ([PoseFrameResult]) -> Void) {

        Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else {
                completion([])
                return
            }

            let duration: Double
            do {
                let t = try await asset.load(.duration)
                duration = t.seconds
            } catch {
                completion([])
                return
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let frameIntervalSec = frameInterval
            let totalFrames = max(1, Int(duration / frameIntervalSec))

            var frameResults: [PoseFrameResult] = []
            let sequenceHandler = VNSequenceRequestHandler()

            for i in 0..<totalFrames {
                let time = CMTime(seconds: Double(i) * frameIntervalSec, preferredTimescale: 600)

                autoreleasepool {
                    do {
                        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                        if let pixelBuffer = self.maybePixelBuffer(from: cgImage) {
                            let result = self.detectFrame(pixelBuffer: pixelBuffer, timestamp: time.seconds, handler: sequenceHandler)
                            if let r = result {
                                frameResults.append(r)
                            }
                        }
                    } catch {
                        // skip
                    }
                }

                let prog = min(time.seconds / max(duration, 1), 1.0)
                await MainActor.run {
                    progress(prog)
                }
            }

            completion(frameResults)
        }
    }

    private func maybePixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func detectFrame(pixelBuffer: CVPixelBuffer, timestamp: Double, handler: VNSequenceRequestHandler) -> PoseFrameResult? {
        let poseRequest = VNDetectHumanBodyPoseRequest()
        do {
            try handler.perform([poseRequest], on: pixelBuffer, orientation: .up)
        } catch {
            return nil
        }
        guard let observation = poseRequest.results?.first else { return nil }

        let (isFaceUp, isFaceDown, confidence) = analyzePose(observation)

        // 面部/口腔检测
        let faceRequest = VNDetectFaceLandmarksRequest()
        try? handler.perform([faceRequest], on: pixelBuffer, orientation: .up)
        let hasMouthOccupied = analyzeMouth(faceRequest.results)

        // 手部检测
        let handRequest = VNDetectHumanHandPoseRequest()
        try? handler.perform([handRequest], on: pixelBuffer, orientation: .up)
        let hasItemInHand = analyzeHand(handRequest.results)

        return PoseFrameResult(
            timestamp: timestamp,
            isFaceUp: isFaceUp,
            isFaceDown: isFaceDown,
            hasMouthOccupied: hasMouthOccupied,
            hasItemInHand: hasItemInHand,
            confidence: confidence
        )
    }

    // MARK: - 精确姿态判断
    private func analyzePose(_ observation: VNHumanBodyPoseObservation) -> (isFaceUp: Bool, isFaceDown: Bool, confidence: Double) {
        guard let shoulderL = try? observation.recognizedPoint(.rightShoulder),
              let shoulderR = try? observation.recognizedPoint(.leftShoulder),
              let hipL = try? observation.recognizedPoint(.rightHip),
              let hipR = try? observation.recognizedPoint(.leftHip) else {
            return (false, false, 0)
        }

        let minConf: Float = 0.4
        guard shoulderL.confidence >= minConf, shoulderR.confidence >= minConf,
              hipL.confidence >= minConf, hipR.confidence >= minConf else {
            return (false, false, 0)
        }

        let shoulderMidX = (shoulderL.location.x + shoulderR.location.x) / 2
        let shoulderMidY = (shoulderL.location.y + shoulderR.location.y) / 2
        let hipMidX = (hipL.location.x + hipR.location.x) / 2
        let hipMidY = (hipL.location.y + hipR.location.y) / 2

        let dx = shoulderMidX - hipMidX
        let dy = shoulderMidY - hipMidY
        let angleRad = atan2(Double(dx), Double(dy))
        let angleDeg = abs(angleRad * 180.0 / .pi)

        let isFaceUp = shoulderMidY > hipMidY + 0.05 && angleDeg < 70
        let isFaceDown = shoulderMidY < hipMidY - 0.05 && angleDeg < 70
        let avgConf = Double(shoulderL.confidence + shoulderR.confidence + hipL.confidence + hipR.confidence) / 4.0

        return (isFaceUp, isFaceDown, avgConf)
    }

    // MARK: - 口腔含圆柱物体判断
    private func analyzeMouth(_ faceResults: [VNFaceObservation]?) -> Bool {
        guard let faces = faceResults, !faces.isEmpty else { return false }
        for face in faces {
            guard let landmarks = face.landmarks, let outerLips = landmarks.outerLips else { continue }
            let pts = outerLips.normalizedPoints
            guard pts.count >= 8 else { continue }

            let cx = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
            let cy = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
            let centroid = CGPoint(x: cx, y: cy)

            var mxx: CGFloat = 0, mxy: CGFloat = 0, myy: CGFloat = 0
            for pt in pts {
                let dx = pt.x - centroid.x
                let dy = pt.y - centroid.y
                mxx += dx * dx; mxy += dx * dy; myy += dy * dy
            }
            mxx /= CGFloat(pts.count); mxy /= CGFloat(pts.count); myy /= CGFloat(pts.count)

            let trace = mxx + myy
            let disc = sqrt(max(0, pow((mxx - myy) / 2, 2) + mxy * mxy))
            let lambda1 = (trace / 2) + disc
            let lambda2 = (trace / 2) - disc
            let axisRatio = sqrt(lambda2 / max(lambda1, 0.0001))

            let upperLipY = pts.prefix(pts.count / 2).max(by: { $0.y < $1.y })?.y ?? cy
            let lowerLipY = pts.suffix(pts.count / 2).min(by: { $0.y < $1.y })?.y ?? cy
            let mouthWidth = abs((pts.last ?? pts[0]).x - pts[0].x)
            let mouthHeight = abs(upperLipY - lowerLipY)
            let whRatio = mouthHeight / max(mouthWidth, 0.001)

            if axisRatio > 0.65 && whRatio > 0.35 { return true }
        }
        return false
    }

    // MARK: - 手握圆柱物体判断
    private func analyzeHand(_ handResults: [VNHumanHandPoseObservation]?) -> Bool {
        guard let hands = handResults, !hands.isEmpty else { return false }
        for hand in hands {
            let fingerJoints: [(pip: VNHumanHandPoseObservation.JointName, tip: VNHumanHandPoseObservation.JointName)] = [
                (.indexPIP, .indexTip), (.middlePIP, .middleTip),
                (.ringPIP, .ringTip), (.littlePIP, .littleTip)
            ]
            guard let wrist = try? hand.recognizedPoint(.wrist), wrist.confidence > 0.4 else { continue }

            var pipDists: [CGFloat] = []
            var tipDists: [CGFloat] = []

            for joint in fingerJoints {
                guard let pip = try? hand.recognizedPoint(joint.pip),
                      let tip = try? hand.recognizedPoint(joint.tip),
                      pip.confidence > 0.3, tip.confidence > 0.3 else { continue }
                pipDists.append(hypot(pip.location.x - wrist.location.x, pip.location.y - wrist.location.y))
                tipDists.append(hypot(tip.location.x - wrist.location.x, tip.location.y - wrist.location.y))
            }

            guard pipDists.count >= 3 else { continue }

            let avgPIP = pipDists.reduce(0, +) / CGFloat(pipDists.count)
            let avgTip = tipDists.reduce(0, +) / CGFloat(tipDists.count)
            let tipToPIPRatio = avgTip / max(avgPIP, 0.001)

            var thumbHelps = false
            if let thumbTip = try? hand.recognizedPoint(.thumbTip),
               let indexTip = try? hand.recognizedPoint(.indexTip),
               thumbTip.confidence > 0.3, indexTip.confidence > 0.3 {
                let thumbToIndex = hypot(thumbTip.location.x - indexTip.location.x, thumbTip.location.y - indexTip.location.y)
                thumbHelps = thumbToIndex < avgPIP * 2.5
            }

            let allCurled = tipToPIPRatio < 1.3
            let curledCount = zip(tipDists, pipDists).filter { $0.0 < $0.1 * 1.4 }.count
            let mostCurled = tipToPIPRatio < 1.8 && curledCount >= 3

            if (allCurled && thumbHelps) || mostCurled { return true }
        }
        return false
    }
}

// MARK: - 主视图
struct VideoPlayerView: View {
    @ObservedObject var viewModel: AppContext

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var playbackRate: Float = 1.0
    @State private var showFilePicker = false
    @State private var fileName: String = "No video loaded"

    @StateObject private var playerObserver = PlayerObserver()
    @StateObject private var rateAnimator = RateAnimator()
    @StateObject private var videoAnalyzer = VideoAnalyzer()

    @State private var useSensorControl: Bool = false
    @State private var showSensorPicker: Bool = false

    @State private var isAnalyzing: Bool = false
    @State private var analysisProgress: Double = 0
    @State private var analysisResults: [PoseFrameResult] = []
    @State private var sensorSegments: [SensorSegment] = []

    var body: some View {
        VStack(spacing: 0) {
            // 视频播放区域
            ZStack {
                if let player = player {
                    CustomVideoPlayer(player: player)
                        .aspectRatio(16/9, contentMode: .fit)
                        .background(Color.black)
                        .onAppear { setupPlayerObservers() }
                        .onDisappear { cleanupPlayer() }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.8))
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: "film")
                                    .font(.system(size: 48))
                                    .foregroundColor(.gray)
                                Text("点击选择视频文件")
                                    .foregroundColor(.gray)
                            }
                        )
                }

                // 分析进度
                if isAnalyzing {
                    ZStack {
                        Color.black.opacity(0.6)
                        VStack(spacing: 16) {
                            ProgressView(value: analysisProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 300)
                            Text("正在分析视频...")
                                .foregroundColor(.white)
                            Text("\(Int(analysisProgress * 100))%")
                                .foregroundColor(.white).font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.1))
            .onTapGesture {
                if player == nil && !isAnalyzing { showFilePicker = true }
            }

            // 分析结果面板
            if !analysisResults.isEmpty && !isAnalyzing {
                AnalysisResultPanel(results: analysisResults)
            }

            // 控制面板
            VStack(spacing: 12) {
                // 进度条
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { currentTime },
                        set: { newValue in
                            if let player = player {
                                player.seek(to: CMTime(seconds: newValue, preferredTimescale: 600))
                            }
                            currentTime = newValue
                            if useSensorControl {
                                useSensorControl = false
                                forceResetToOne()
                            } else {
                                setPlaybackRate(1.0)
                            }
                        }
                    ), in: 0...max(duration, 1))
                    .disabled(player == nil || isAnalyzing)
                    .tint(.blue)

                    HStack {
                        Text(formatTime(currentTime)).font(.caption).monospacedDigit()
                        Spacer()
                        Text(fileName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        Spacer()
                        Text(formatTime(duration)).font(.caption).monospacedDigit()
                    }
                }

                // 播放控制栏
                HStack(spacing: 20) {
                    Button(action: togglePlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(player == nil || isAnalyzing)

                    Divider().frame(height: 20)

                    // 速度显示
                    HStack(spacing: 4) {
                        Text("速度:")
                            .font(.subheadline).foregroundColor(.secondary)
                        Text("\(playbackRate, specifier: "%.2f")x")
                            .font(.caption).monospacedDigit()
                            .foregroundColor(useSensorControl ? .orange : .primary)
                    }

                    Spacer()

                    // 姿势状态指示（基于时间轴）
                    if !sensorSegments.isEmpty {
                        let inSegment = isInSensorSegment(t: currentTime)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(inSegment ? .orange : .green)
                                .frame(width: 8, height: 8)
                            Text(inSegment ? "控制中" : "正常")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 传感器速率指示
                    if useSensorControl {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Text("\(rateAnimator.currentRate, specifier: "%.2f")x")
                                .font(.caption).monospacedDigit().foregroundColor(.orange)
                        }
                    }

                    Divider().frame(height: 20)

                    // 传感器开关
                    Toggle("", isOn: Binding(
                        get: { viewModel.enableScan },
                        set: { value in
                            if value {
                                viewModel.scanDevices()
                                showSensorPicker = true
                            } else {
                                viewModel.stopScan()
                                showSensorPicker = false
                                if let d = viewModel.connectedDevice {
                                    viewModel.closeDevice(bwt901ble: d)
                                }
                            }
                        }
                    ))
                    Image(systemName: viewModel.connectedDevice != nil ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.caption)
                        .foregroundColor(viewModel.connectedDevice != nil ? .green : .secondary)

                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "folder")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAnalyzing)
                }
            }
            .padding()
            .background(Color(white: 0.15))
        }
        .frame(minWidth: 900, minHeight: 650)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .sheet(isPresented: $showSensorPicker) {
            SensorPickerSheet(viewModel: viewModel, isPresented: $showSensorPicker)
        }
        .onChange(of: viewModel.connectedDevice?.mac) { mac in
            if mac != nil {
                useSensorControl = true
            } else {
                useSensorControl = false
                forceResetToOne()
            }
        }
        .onChange(of: viewModel.sensorPlaybackRate) { rate in
            if useSensorControl {
                rateAnimator.setTarget(rate)
            }
        }
        // 播放时实时根据时间轴更新传感器控制状态
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard !isAnalyzing else { return }
            updateSensorControlState()
        }
        // 高频刷新：将平滑后的速率应用到播放器
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { _ in
            guard isPlaying, !isAnalyzing else { return }
            guard useSensorControl else { return }
            // 兜底：当前时间不在传感器控制区间内时立即恢复 1.0x
            if !self.isInSensorSegment(t: self.currentTime) {
                self.useSensorControl = false
                self.forceResetToOne()
                return
            }
            self.setPlaybackRate(self.rateAnimator.currentRate)
        }
    }

    // MARK: - 根据时间轴更新传感器控制状态
    private func updateSensorControlState() {
        guard !sensorSegments.isEmpty else { return }
        let shouldControl = isInSensorSegment(t: currentTime)

        if shouldControl && !useSensorControl {
            useSensorControl = true
        } else if !shouldControl && useSensorControl {
            useSensorControl = false
            forceResetToOne()
        }
    }

    private func forceResetToOne() {
        rateAnimator.reset()
        playbackRate = 1.0
        player?.rate = 1.0
    }

    // MARK: - 二分查找：当前时间是否在传感器控制区间内
    private func isInSensorSegment(t: Double) -> Bool {
        var low = 0, high = sensorSegments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let seg = sensorSegments[mid]
            if t >= seg.start && t <= seg.end {
                return true
            } else if t < seg.start {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return false
    }

    // MARK: - 从分析帧构建传感器控制时间段
    private func buildSensorSegments(from results: [PoseFrameResult]) -> [SensorSegment] {
        var segments: [SensorSegment] = []
        var segmentStart: Double?
        var lastEnd: Double = 0

        for result in results {
            let isTriggered = result.isFaceUp || result.isFaceDown || result.hasMouthOccupied || result.hasItemInHand

            if isTriggered {
                if segmentStart == nil {
                    segmentStart = result.timestamp
                }
                lastEnd = result.timestamp
            } else {
                if let start = segmentStart {
                    segments.append(SensorSegment(start: start, end: lastEnd))
                    segmentStart = nil
                }
            }
        }

        if let start = segmentStart {
            segments.append(SensorSegment(start: start, end: lastEnd))
        }

        print("[buildSensorSegments] total: \(segments.count)")
        return segments
    }

    // MARK: - 文件选择 + 自动分析
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            player?.pause()
            player = nil
            isPlaying = false
            analysisResults = []
            sensorSegments = []
            rateAnimator.reset()

            url.startAccessingSecurityScopedResource()
            let tempDir = FileManager.default.temporaryDirectory
            let uniqueName = UUID().uuidString + "_" + url.lastPathComponent
            let tempURL = tempDir.appendingPathComponent(uniqueName)

            do {
                try? FileManager.default.removeItem(at: tempURL)
                try FileManager.default.copyItem(at: url, to: tempURL)

                let asset = AVAsset(url: tempURL)
                let newPlayer = AVPlayer(url: tempURL)
                player = newPlayer
                fileName = url.lastPathComponent
                currentTime = 0
                playbackRate = 1.0

                Task {
                    if let d = try? await asset.load(.duration) {
                        await MainActor.run { duration = d.seconds }
                    }
                }

                setupPlayerObservers()
                startAnalysis(url: tempURL)

            } catch {
                print("文件加载错误: \(error.localizedDescription)")
            }

        case .failure(let error):
            print("文件选择错误: \(error.localizedDescription)")
        }
    }

    private func startAnalysis(url: URL) {
        isAnalyzing = true
        analysisProgress = 0
        analysisResults = []

        videoAnalyzer.analyze(url: url, frameInterval: 0.2) { prog in
            self.analysisProgress = prog
        } completion: { results in
            self.analysisResults = results
            self.sensorSegments = self.buildSensorSegments(from: results)
            self.isAnalyzing = false
            print("[startAnalysis] completion: results=\(results.count) segments=\(self.sensorSegments.count)")
        }
    }

    private func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
    }

    private func setupPlayerObservers() {
        guard let player = player else { return }
        playerObserver.setup(player: player) { [self] time in
            self.currentTime = time
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
            self.isPlaying = false
            player.seek(to: .zero)
        }
    }

    private func cleanupPlayer() {
        playerObserver.cleanup()
        player?.pause()
        player = nil
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - 分析结果面板
struct AnalysisResultPanel: View {
    let results: [PoseFrameResult]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatCard(title: "仰面帧", value: "\(results.filter { $0.isFaceUp }.count)", color: .orange)
                StatCard(title: "趴着帧", value: "\(results.filter { $0.isFaceDown }.count)", color: .red)
                StatCard(title: "含物帧", value: "\(results.filter { $0.hasMouthOccupied }.count)", color: .purple)
                StatCard(title: "握柱帧", value: "\(results.filter { $0.hasItemInHand }.count)", color: .blue)
                StatCard(title: "总帧数", value: "\(results.count)", color: .secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.12))
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline).monospacedDigit()
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - 传感器选择弹窗
struct SensorPickerSheet: View {
    @ObservedObject var viewModel: AppContext
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("选择传感器设备").font(.headline)
                Spacer()
                Button(action: {
                    isPresented = false
                    viewModel.stopScan()
                    viewModel.enableScan = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            if viewModel.deviceList.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("正在扫描传感器...").font(.headline).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.deviceList) { device in
                            Bwt901bleView(device, viewModel) {
                                isPresented = false
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}

// MARK: - 蓝牙传感器行
struct Bwt901bleView: View {
    @ObservedObject var device: Bwt901ble
    @ObservedObject var viewModel: AppContext
    var onDeviceSelected: (() -> Void)?

    init(_ device: Bwt901ble, _ viewModel: AppContext, onDeviceSelected: (() -> Void)? = nil) {
        self.device = device
        self.viewModel = viewModel
        self.onDeviceSelected = onDeviceSelected
    }

    var body: some View {
        Button(action: {
            device.isOpen = true
            viewModel.openDevice(bwt901ble: device)
            onDeviceSelected?()
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name ?? "").font(.headline)
                    Text(device.mac ?? "").font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 自定义视频播放器
#if os(iOS)
struct CustomVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}
#elseif os(macOS)
struct CustomVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
#endif

// MARK: - 播放器观察者
class PlayerObserver: ObservableObject {
    private var timeObserver: Any?
    private var player: AVPlayer?

    func setup(player: AVPlayer, onTimeUpdate: @escaping (Double) -> Void) {
        self.player = player
        let observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            onTimeUpdate(time.seconds)
        }
        self.timeObserver = observer
    }

    func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player = nil
    }
}
