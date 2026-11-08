import CoreML
import CryptoKit
import Foundation

/// Speech recognition on this Mac: Parakeet TDT 0.6B v3 (NVIDIA) in the Core ML builds of FluidInference,
/// CC-BY-4.0. 25 languages, found by the model itself. The greedy TDT decoding follows FluidAudio (Apache-2.0),
/// rewritten for Nook (see NOTICE).
/// The dictation models; `nemotron` is the streaming one (`Sources/Nemotron.swift`), the others are Parakeet.
enum ParakeetModel: String, CaseIterable, Identifiable {
    /// moondream's ternary re-training: a 2-bit encoder, small and fast (macOS 15: iOS 18 Core ML ops).
    case redux
    /// moondream's full post-training: an int8 encoder, the best accuracy.
    case ultra
    /// NVIDIA Nemotron 3.5 ASR Streaming: the text appears while you speak; less accurate than Ultra.
    case nemotron

    var id: String { rawValue }

    var title: String {
        switch self {
        case .redux: L("Быстрая")
        case .ultra: L("Точная")
        case .nemotron: L("Живая")
        }
    }

    var detail: String {
        switch self {
        case .redux: L("Меньше места и памяти. Текст появится, когда отпустите клавишу")
        case .ultra: L("Лучше всех понимает русский и украинский. Текст появится, когда отпустите клавишу")
        case .nemotron: L("Текст виден прямо во время речи, но ошибок больше, чем у Точной")
        }
    }

    /// The model itself, named in the picker beside the plain title.
    var engine: String {
        switch self {
        case .redux: "Parakeet Redux"
        case .ultra: "Parakeet Ultra"
        case .nemotron: "Nemotron 3.5"
        }
    }

    var isSupported: Bool {
        if self == .redux, #unavailable(macOS 15) { return false }
        return true
    }

    fileprivate var repo: String { self == .nemotron ? NemotronModel.repo : "FluidInference/parakeet-\(rawValue)-coreml" }

    /// Pinned: a changed repository never reaches Nook without a new manifest here.
    fileprivate var revision: String {
        switch self {
        case .redux: "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9"
        case .ultra: "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
        case .nemotron: NemotronModel.revision
        }
    }

    /// Every file with its size and SHA-256, taken from the pinned revision.
    fileprivate var files: [ParakeetFile] {
        switch self {
        case .redux: ParakeetFile.redux
        case .ultra: ParakeetFile.ultra
        case .nemotron: NemotronModel.files
        }
    }

    var downloadSize: Int64 { manifest.downloadSize }

    static let folder = supportDir.appendingPathComponent("Models", isDirectory: true)
    var directory: URL {
        self == .nemotron ? NemotronModel.directory : Self.folder.appendingPathComponent("parakeet-\(rawValue)", isDirectory: true)
    }

    var manifest: ModelManifest {
        if self == .nemotron { return NemotronModel.manifest }
        return ModelManifest(repo: repo, revision: revision, folder: "", files: files, directory: directory,
                      staging: Self.folder.appendingPathComponent("parakeet-\(rawValue).partial", isDirectory: true))
    }

    /// Installed means: the download finished and every file passed its check (the folder is renamed only then).
    var isInstalled: Bool {
        self == .nemotron ? NemotronModel.isInstalled
            : FileManager.default.fileExists(atPath: directory.appendingPathComponent(ParakeetFile.vocab).path)
    }
}

/// One file of a pinned model: its path in the repository folder, size and SHA-256 at the pinned revision.
struct ModelFile {
    let path: String
    let size: Int64
    let sha256: String
}

/// Where a pinned model comes from and where it is installed. Every file is checked against its size and SHA-256;
/// the staging folder is renamed to `directory` only when all of them passed.
struct ModelManifest {
    let repo: String
    let revision: String
    /// Folder inside the repository, "" for its root.
    let folder: String
    let files: [ModelFile]
    let directory: URL
    let staging: URL

    var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }

    func url(_ file: ModelFile) -> URL {
        let path = folder.isEmpty ? file.path : "\(folder)/\(file.path)"
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!
    }
}

fileprivate typealias ParakeetFile = ModelFile

fileprivate extension ModelFile {
    static let vocab = "parakeet_v3_vocab.json"
    static let redux: [ParakeetFile] = [
        ParakeetFile(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243,
                     sha256: "7f24e7248d57024c6f1c5a2ea306f4a6a89db45a363218523bb6410c4b1aecf0"),
        ParakeetFile(path: "Decoder.mlmodelc/coremldata.bin", size: 560,
                     sha256: "422da51d983e93a3e48cd6d46a17d6c32844452414c8e242fb0caaca2b8af5ed"),
        ParakeetFile(path: "Decoder.mlmodelc/model.mil", size: 13110,
                     sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
        ParakeetFile(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992,
                     sha256: "6c6c88c23ee5492a6b229e8cc636ddadb2b01ae0dd559d9cb63123bebf507d77"),
        ParakeetFile(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243,
                     sha256: "7862e972e09315df099d4bfd320743bf106acbf7fe4343317f9de45b0635d7b7"),
        ParakeetFile(path: "Encoder.mlmodelc/coremldata.bin", size: 506,
                     sha256: "ca0b212fe3c06c3ccd35e508fa61e4dfaad19dd0c55b82e4f5bf8711e7758fd9"),
        ParakeetFile(path: "Encoder.mlmodelc/model.mil", size: 965906,
                     sha256: "165487e314ed93c4a44dfec99d57be4e436e7c3dba6eef49fd3f0daf9de6d0d4"),
        ParakeetFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 182389312,
                     sha256: "adbb5550dc6488717d3a1407b53122fbdb1af5e99c330ee20f8d8cfd9ec49252"),
        ParakeetFile(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243,
                     sha256: "fc857a756b8c9c9f31aa9e1062766cc0a82ac035ef369d6e1cbe97184921479c"),
        ParakeetFile(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 592,
                     sha256: "611ea653e2adede7cc1cfe70da36296844f97e95e2c7dd961d45230e5599389d"),
        ParakeetFile(path: "JointDecisionv3.mlmodelc/model.mil", size: 11777,
                     sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
        ParakeetFile(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764,
                     sha256: "73b0288acd115fc4c36038f66b6cbf49233182488febf5d8c787bea4009535f7"),
        ParakeetFile(path: "parakeet_v3_vocab.json", size: 151122,
                     sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ParakeetFile(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243,
                     sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        ParakeetFile(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486,
                     sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        ParakeetFile(path: "Preprocessor.mlmodelc/metadata.json", size: 2841,
                     sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        ParakeetFile(path: "Preprocessor.mlmodelc/model.mil", size: 28181,
                     sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        ParakeetFile(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072,
                     sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
    ]
    static let ultra: [ParakeetFile] = [
        ParakeetFile(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243,
                     sha256: "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5"),
        ParakeetFile(path: "Decoder.mlmodelc/coremldata.bin", size: 560,
                     sha256: "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497"),
        ParakeetFile(path: "Decoder.mlmodelc/model.mil", size: 13110,
                     sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
        ParakeetFile(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992,
                     sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"),
        ParakeetFile(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243,
                     sha256: "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d"),
        ParakeetFile(path: "Encoder.mlmodelc/coremldata.bin", size: 514,
                     sha256: "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe"),
        ParakeetFile(path: "Encoder.mlmodelc/model.mil", size: 1002653,
                     sha256: "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848"),
        ParakeetFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 594211328,
                     sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
        ParakeetFile(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243,
                     sha256: "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4"),
        ParakeetFile(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 592,
                     sha256: "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4"),
        ParakeetFile(path: "JointDecisionv3.mlmodelc/model.mil", size: 11777,
                     sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
        ParakeetFile(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764,
                     sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
        ParakeetFile(path: "parakeet_v3_vocab.json", size: 151122,
                     sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ParakeetFile(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243,
                     sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        ParakeetFile(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486,
                     sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        ParakeetFile(path: "Preprocessor.mlmodelc/metadata.json", size: 2841,
                     sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        ParakeetFile(path: "Preprocessor.mlmodelc/model.mil", size: 28181,
                     sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        ParakeetFile(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072,
                     sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
    ]
}

enum ParakeetError: LocalizedError {
    case download(String)
    case model(String)

    var errorDescription: String? {
        switch self {
        case .download(let text), .model(let text): text
        }
    }
}

// MARK: Download

/// The Parakeet name of the shared download, used by `Dictation`.
typealias ParakeetDownload = ModelDownload

/// Downloads one model file by file into a staging folder, checks size and SHA-256 of each, then renames the
/// folder. Files already checked in an interrupted download are kept.
final class ModelDownload: NSObject, URLSessionDownloadDelegate {
    let manifest: ModelManifest
    /// On the main thread: bytes done of the whole model.
    var onProgress: ((Int64, Int64) -> Void)?
    /// On the main thread: nil when the model is installed.
    var onFinish: ((Error?) -> Void)?

    private var session: URLSession!
    private var queue: [ModelFile] = []
    private var current: ModelFile?
    private var done: Int64 = 0
    private var cancelled = false
    private let work = DispatchQueue(label: "nook.model.download")

    convenience init(model: ParakeetModel) {
        self.init(manifest: model.manifest)
    }

    init(manifest: ModelManifest) {
        self.manifest = manifest
        super.init()
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = work
        session = URLSession(configuration: .default, delegate: self, delegateQueue: operations)
    }

    func start() {
        work.async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: manifest.staging, withIntermediateDirectories: true)
            queue = manifest.files.filter { file in
                let url = manifest.staging.appendingPathComponent(file.path)
                guard Self.size(url) == file.size, Self.sha256(url) == file.sha256 else { return true }
                done += file.size
                return false
            }
            next()
        }
    }

    func cancel() {
        work.async { [self] in
            cancelled = true
            session.invalidateAndCancel()
        }
    }

    /// Runs on `work`.
    private func next() {
        guard !cancelled else { return }
        guard !queue.isEmpty else { return finish() }
        let file = queue.removeFirst()
        current = file
        session.downloadTask(with: manifest.url(file)).resume()
    }

    private func finish() {
        let fm = FileManager.default
        try? fm.removeItem(at: manifest.directory)
        do {
            try fm.moveItem(at: manifest.staging, to: manifest.directory)
            report(nil)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error?) {
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.onFinish?(error) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = manifest.downloadSize
        let now = done + totalBytesWritten
        DispatchQueue.main.async { self.onProgress?(now, total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let file = current else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, Self.size(location) == file.size, Self.sha256(location) == file.sha256 else {
            cancelled = true
            return report(ParakeetError.download(L("Файл модели не прошёл проверку: \(file.path). Попробуйте ещё раз.")))
        }
        let target = manifest.staging.appendingPathComponent(file.path)
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        do {
            try fm.moveItem(at: location, to: target)
        } catch {
            cancelled = true
            return report(error)
        }
        done += file.size
        current = nil
        next()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !cancelled else { return }
        cancelled = true
        report(ParakeetError.download(L("Не удалось скачать модель: \(error.localizedDescription)")))
    }

    private static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Streams the file: the encoder alone is 600 MB.
    private static func sha256(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Recognition

/// The four Core ML models of one Parakeet variant. Not thread-safe: use it from one serial queue.
final class ParakeetEngine {
    static let sampleRate = 16_000
    /// The models take exactly 15 s; shorter audio is padded with silence.
    static let windowSamples = 240_000

    private static let blank = 8192
    private static let durations = [0, 1, 2, 3, 4]
    /// Tokens in a row on one frame before the decoder is moved on (a stuck decoder would repeat forever).
    private static let maxSymbolsPerFrame = 10

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let vocabulary: [String]

    // Reused inputs.
    private let signal: MLMultiArray
    private let signalLength: MLMultiArray
    private let target: MLMultiArray
    private let targetLength: MLMultiArray
    private let encoderStep: MLMultiArray
    private let decoderStep: MLMultiArray

    init(directory: URL) throws {
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent("\(name).mlmodelc"), configuration: configuration)
        }
        preprocessor = try load("Preprocessor", .cpuOnly)
        encoder = try load("Encoder", .cpuAndNeuralEngine)
        decoder = try load("Decoder", .cpuAndNeuralEngine)
        joint = try load("JointDecisionv3", .cpuAndNeuralEngine)

        let data = try Data(contentsOf: directory.appendingPathComponent(ParakeetFile.vocab))
        guard let table = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ParakeetError.model(L("Словарь модели повреждён."))
        }
        var words = [String](repeating: "", count: Self.blank)
        for (key, value) in table { if let id = Int(key), words.indices.contains(id) { words[id] = value } }
        vocabulary = words

        signal = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        signalLength = try MLMultiArray(shape: [1], dataType: .int32)
        target = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targetLength = try MLMultiArray(shape: [1], dataType: .int32)
        targetLength[0] = 1
        encoderStep = try MLMultiArray(shape: [1, 1024, 1], dataType: .float32)
        decoderStep = try MLMultiArray(shape: [1, 640, 1], dataType: .float32)
    }

    /// The LSTM state of the decoder; carried from one window to the next so words keep their context.
    private struct State {
        var h: MLMultiArray
        var c: MLMultiArray
        var output: MLMultiArray?
        var last = ParakeetEngine.blank
    }

    /// 16 kHz mono samples → text.
    func transcribe(_ samples: [Float]) throws -> String {
        var state = State(h: try Self.zeros([2, 1, 640]), c: try Self.zeros([2, 1, 640]))
        var tokens: [Int] = []
        for range in Self.windows(samples) {
            tokens += try decode(samples[range], state: &state)
        }
        return text(tokens)
    }

    /// Windows of at most 15 s, cut at the quietest moment of the last 5 s so a word is rarely split.
    static func windows(_ samples: [Float]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        let frame = sampleRate / 10
        while samples.count - start > windowSamples {
            var cut = start + windowSamples
            var quietest = Float.infinity
            var at = start + windowSamples - 5 * sampleRate
            while at + frame <= start + windowSamples {
                var energy: Float = 0
                for i in at..<(at + frame) { energy += samples[i] * samples[i] }
                if energy < quietest { quietest = energy; cut = at + frame / 2 }
                at += frame / 2
            }
            result.append(start..<cut)
            start = cut
        }
        if start < samples.count { result.append(start..<samples.count) }
        return result
    }

    private func decode(_ window: ArraySlice<Float>, state: inout State) throws -> [Int] {
        let count = min(window.count, Self.windowSamples)
        let pointer = signal.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
        pointer.update(repeating: 0, count: Self.windowSamples)
        window.prefix(count).withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: count) }
        signalLength[0] = NSNumber(value: count)

        let features = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": signal, "audio_length": signalLength,
        ]))
        guard let mel = features.featureValue(for: "mel")?.multiArrayValue,
              let melLength = features.featureValue(for: "mel_length")?.multiArrayValue else {
            throw ParakeetError.model(L("Модель не вернула признаки звука."))
        }
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": mel, "mel_length": melLength,
        ]))
        guard let frames = encoded.featureValue(for: "encoder")?.multiArrayValue,
              let frameCount = encoded.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue else {
            throw ParakeetError.model(L("Модель не вернула кадры кодировщика."))
        }
        let view = try FrameView(frames, hidden: 1024)
        let length = min(frameCount, view.count)

        if state.output == nil { try step(token: state.last, state: &state) }
        var tokens: [Int] = []
        var t = 0
        var onThisFrame = 0
        while t < length {
            view.copy(frame: t, into: encoderStep)
            try Self.copy(state.output!, into: decoderStep, hidden: 640)
            let decision = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "encoder_step": encoderStep, "decoder_step": decoderStep,
            ]))
            guard let token = decision.featureValue(for: "token_id")?.multiArrayValue?[0].intValue,
                  let bin = decision.featureValue(for: "duration")?.multiArrayValue?[0].intValue else {
                throw ParakeetError.model(L("Модель не вернула решение."))
            }
            var advance = Self.durations[min(max(bin, 0), Self.durations.count - 1)]
            if token == Self.blank {
                t += max(advance, 1)
                onThisFrame = 0
                continue
            }
            tokens.append(token)
            try step(token: token, state: &state)
            onThisFrame += 1
            if advance == 0 && onThisFrame >= Self.maxSymbolsPerFrame { advance = 1 }
            if advance > 0 { onThisFrame = 0 }
            t += advance
        }
        return tokens
    }

    /// Feeds one token into the decoder LSTM.
    private func step(token: Int, state: inout State) throws {
        target[0] = NSNumber(value: token)
        let result = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": target, "target_length": targetLength, "h_in": state.h, "c_in": state.c,
        ]))
        guard let output = result.featureValue(for: "decoder")?.multiArrayValue,
              let h = result.featureValue(for: "h_out")?.multiArrayValue,
              let c = result.featureValue(for: "c_out")?.multiArrayValue else {
            throw ParakeetError.model(L("Модель не вернула состояние декодера."))
        }
        state.output = output
        state.h = h
        state.c = c
        state.last = token
    }

    /// SentencePiece pieces: "▁" starts a word; special tokens look like "<…>".
    private func text(_ tokens: [Int]) -> String {
        var result = ""
        for token in tokens where vocabulary.indices.contains(token) {
            let piece = vocabulary[token]
            if piece.hasPrefix("<") && piece.hasSuffix(">") { continue }
            result += piece.replacingOccurrences(of: "▁", with: " ")
        }
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static func zeros(_ shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        array.dataPointer.bindMemory(to: Float.self, capacity: array.count).update(repeating: 0, count: array.count)
        return array
    }

    /// Copies a [1, hidden, 1] or [1, 1, hidden] output into a [1, hidden, 1] input, whatever its strides.
    private static func copy(_ source: MLMultiArray, into destination: MLMultiArray, hidden: Int) throws {
        let shape = source.shape.map(\.intValue)
        guard shape.count == 3, let axis = [1, 2].first(where: { shape[$0] == hidden }) else {
            throw ParakeetError.model(L("Неожиданная форма выхода модели: \(String(describing: shape))."))
        }
        let stride = source.strides[axis].intValue
        let from = source.dataPointer.bindMemory(to: Float.self, capacity: source.count)
        let to = destination.dataPointer.bindMemory(to: Float.self, capacity: hidden)
        let step = destination.strides[1].intValue
        for i in 0..<hidden { to[i * step] = from[i * stride] }
    }

    /// Encoder frames as [1, 1024, T] or [1, T, 1024].
    private struct FrameView {
        let array: MLMultiArray
        let hiddenStride: Int
        let timeStride: Int
        let count: Int
        let hidden: Int

        init(_ array: MLMultiArray, hidden: Int) throws {
            let shape = array.shape.map(\.intValue)
            guard shape.count == 3, array.dataType == .float32,
                  let axis = [1, 2].first(where: { shape[$0] == hidden }) else {
                throw ParakeetError.model(L("Неожиданная форма кадров: \(String(describing: shape))."))
            }
            let time = axis == 1 ? 2 : 1
            self.array = array
            self.hidden = hidden
            hiddenStride = array.strides[axis].intValue
            timeStride = array.strides[time].intValue
            count = shape[time]
        }

        func copy(frame t: Int, into destination: MLMultiArray) {
            let from = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            let to = destination.dataPointer.bindMemory(to: Float.self, capacity: hidden)
            let step = destination.strides[1].intValue
            let base = t * timeStride
            for i in 0..<hidden { to[i * step] = from[base + i * hiddenStride] }
        }
    }
}
