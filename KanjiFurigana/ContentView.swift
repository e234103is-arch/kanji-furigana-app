import SwiftUI
import AVFoundation
import Vision
import Combine

// --- 1. メイン画面 (UI) ---
struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var isHolding = false
    @State private var isShowingHistory = false

    var body: some View {
        ZStack {
            // 背景：カメラプレビュー
            CameraPreview(session: cameraManager.session)
                .ignoresSafeArea()
                // 画面を長押ししている間、映像と解析をストップ（ホールド機能）
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isHolding {
                                isHolding = true
                                cameraManager.isPaused = true
                            }
                        }
                        .onEnded { _ in
                            isHolding = false
                            cameraManager.isPaused = false
                        }
                )

            // 中央の照準（ターゲット）
            Circle()
                .stroke(isHolding ? Color.red : Color.blue, lineWidth: 3)
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: isHolding ? "pause.fill" : "plus")
                        .foregroundColor(isHolding ? .red : .blue)
                )
            
            // 解析結果のパネル表示
            VStack {
                if let item = cameraManager.focusedItem {
                    VStack(spacing: 12) {
                        VStack(spacing: 4) {
                            Text(item.furigana)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundColor(.cyan)
                            Text(item.text)
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        
                        // 検索ボタンの切り替え
                        HStack(spacing: 20) {
                            Button(action: { cameraManager.saveAndSearch(item, mode: .meaning) }) {
                                Label("意味", systemImage: "character.book.closed.fill")
                                    .font(.caption).padding(8).background(Color.blue).cornerRadius(8)
                            }
                            Button(action: { cameraManager.saveAndSearch(item, mode: .image) }) {
                                Label("画像", systemImage: "photo.fill")
                                    .font(.caption).padding(8).background(Color.purple).cornerRadius(8)
                            }
                        }
                        .foregroundColor(.white)
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 15)
                    .background(BlurView(style: .systemThinMaterialDark))
                    .cornerRadius(20)
                    .shadow(radius: 10)
                    .padding(.top, 40)
                }
                Spacer()
                
                // 単語帳（履歴）を開くボタン
                Button(action: { isShowingHistory = true }) {
                    HStack {
                        Image(systemName: "list.bullet.rectangle.portrait.fill")
                        Text("保存済み単語 (\(cameraManager.history.count))")
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(15)
                }
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $isShowingHistory) {
            HistoryView(cameraManager: cameraManager)
        }
        .onAppear { cameraManager.checkPermission() }
    }
}

// --- 2. 単語帳画面 (List表示) ---
struct HistoryView: View {
    @ObservedObject var cameraManager: CameraManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(cameraManager.history) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.furigana).font(.caption).foregroundColor(.secondary)
                            Text(item.text).font(.headline)
                        }
                        Spacer()
                        // リストから再度検索
                        Button(action: { cameraManager.searchOnGoogle(item.text, mode: .meaning) }) {
                            Image(systemName: "magnifyingglass").foregroundColor(.blue)
                        }
                    }
                }
                .onDelete(perform: cameraManager.deleteHistory)
            }
            .navigationTitle("単語帳")
            .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}

// --- 3. カメラ・解析管理 (Logic) ---
class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var focusedItem: RecognizedItem? = nil
    @Published var isPaused = false
    @Published var history: [HistoryItem] = []
    
    enum SearchMode { case meaning, image }
    
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var isProcessing = false
    private let historyKey = "KanjiHistoryKey"
    private let feedback = UIImpactFeedbackGenerator(style: .medium)
    
    override init() {
        super.init()
        loadHistory()
    }
    
    // 補正辞書：誤読される言葉をここで修正
    private let customDictionary = [
        "有明干拓": "ありあけかんたく",
        "干拓": "かんたく"
    ]
    
    func saveAndSearch(_ item: RecognizedItem, mode: SearchMode) {
        feedback.impactOccurred() // タップ時に振動させる
        
        if !history.contains(where: { $0.text == item.text }) {
            let newItem = HistoryItem(text: item.text, furigana: item.furigana)
            history.insert(newItem, at: 0)
            saveHistory()
        }
        searchOnGoogle(item.text, mode: mode)
    }

    func searchOnGoogle(_ text: String, mode: SearchMode) {
        let suffix = (mode == .meaning) ? " 意味" : ""
        let baseUrl = (mode == .meaning) ? "https://www.google.com/search?q=" : "https://www.google.com/search?tbm=isch&q="
        
        if let encodedText = (text + suffix).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: baseUrl + encodedText) {
            UIApplication.shared.open(url)
        }
    }

    // --- カメラセットアップ ---
    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { if $0 { self.setupCamera() } }
        default: break
        }
    }
    
    private func setupCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        if session.canAddInput(input) { session.addInput(input) }
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cameraQueue"))
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if let connection = videoOutput.connection(with: .video) { connection.videoRotationAngle = 90 }
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }
    
    // --- 解析処理 ---
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isPaused, !isProcessing, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        isProcessing = true
        
        let request = VNRecognizeTextRequest { [weak self] (request, error) in
            defer { self?.isProcessing = false }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            let center = CGPoint(x: 0.5, y: 0.5)
            // 漢字が含まれるテキストのみを抽出
            let filtered = observations.filter { obs in
                guard let top = obs.topCandidates(1).first else { return false }
                return top.string.range(of: "\\p{Han}", options: .regularExpression) != nil
            }
            
            let closest = filtered.min(by: { a, b in
                let distA = pow(a.boundingBox.midX - center.x, 2) + pow(a.boundingBox.midY - center.y, 2)
                let distB = pow(b.boundingBox.midX - center.x, 2) + pow(b.boundingBox.midY - center.y, 2)
                return distA < distB
            })
            
            if let obs = closest, let candidate = obs.topCandidates(1).first {
                if sqrt(pow(obs.boundingBox.midX - center.x, 2) + pow(obs.boundingBox.midY - center.y, 2)) < 0.15 {
                    let text = candidate.string
                    let furigana = self?.convertToFurigana(text: text) ?? ""
                    DispatchQueue.main.async {
                        self?.focusedItem = RecognizedItem(id: UUID(), text: text, furigana: furigana, box: obs.boundingBox)
                    }
                }
            }
        }
        request.recognitionLanguages = ["ja-JP"]
        request.regionOfInterest = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
    }
    
    private func convertToFurigana(text: String) -> String {
        // 辞書による直接補正
        for (wrong, correct) in customDictionary {
            if text.contains(wrong) { return correct }
        }
        
        // 通常のトークナイズ処理
        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, text as CFString, CFRangeMake(0, text.count), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja_JP") as CFLocale)
        var result = ""
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let mutableString = NSMutableString(string: latin)
                CFStringTransform(mutableString, nil, "Latin-Hiragana" as CFString, false)
                result += mutableString as String
            } else {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                result += (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return result
    }
    
    // データ永続化
    private func saveHistory() { if let encoded = try? JSONEncoder().encode(history) { UserDefaults.standard.set(encoded, forKey: historyKey) } }
    private func loadHistory() { if let data = UserDefaults.standard.data(forKey: historyKey), let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) { history = decoded } }
    func deleteHistory(at offsets: IndexSet) { history.remove(atOffsets: offsets); saveHistory() }
}

// --- 4. 補助部品・モデル ---
struct RecognizedItem: Identifiable { let id: UUID; let text: String; let furigana: String; let box: CGRect }
struct HistoryItem: Identifiable, Codable { var id = UUID(); let text: String; let furigana: String }

struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: UIBlurEffect(style: style)) }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        DispatchQueue.main.async { previewLayer.frame = view.bounds }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer { layer.frame = uiView.bounds }
    }
}
