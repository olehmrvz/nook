import Accelerate
import CoreML
import Foundation

// Streaming speech recognition on this Mac: NVIDIA Nemotron 3.5 ASR Streaming 0.6B
// (nvidia/nemotron-3.5-asr-streaming-0.6b, OpenMDW-1.1) in the Core ML build of FluidInference
// (FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML, folder multilingual/1120ms).
//
// A cache-aware FastConformer encoder takes 1.12 s of audio at a time and carries its attention and convolution
// caches to the next chunk; a greedy RNN-T decoder turns its frames into text with punctuation and capitals. The
// language comes from a prompt id ("auto" lets the model find it). The model contract (inputs, caches, mel front
// end, greedy decoding) follows FluidAudio v0.18.3 (Apache-2.0, Copyright FluidInference):
// StreamingNemotronMultilingualAsrManager and NemotronMelExtractor. The code is written for Nook; no FluidAudio
// source file is included (see NOTICE.md).

/// The pinned Core ML build: multilingual, 1.12 s chunks (the `latin` build has no Russian or Ukrainian).
enum NemotronModel {
    static let repo = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    /// Pinned: a changed repository never reaches Nook without a new manifest here. A new revision needs a new
    /// folder name too (`directory`), or an installed older copy would count as the new one.
    static let revision = "1a41b75758b0337ff67db7d5408280aaaf23074e"
    static let remoteFolder = "multilingual/1120ms"
    static let metadata = "metadata.json"
    static let tokenizer = "tokenizer.json"

    /// Only what Nook runs: the Core ML preprocessor (the mel features are computed in Swift, `NemotronMel`) and the
    /// fused decoder_joint (the separate decoder and joint are used) stay on the server.
    static let files: [ModelFile] = [
        ModelFile(path: "decoder.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "fdb14a08e42b4806a2d1505501586be71e4f04ca9256c719544fd7ed6937e509"),
        ModelFile(path: "decoder.mlmodelc/coremldata.bin", size: 433,
                  sha256: "6d13f9f434a2485bf9bac16e353f0c2ea850ec5a98e44effc33bfe17da8559d5"),
        ModelFile(path: "decoder.mlmodelc/model.mil", size: 11743,
                  sha256: "f3ed3e9cac9b70e1b00df48b53868dbd3c4dd8cf158af79ded0d05a96e0bf5dc"),
        ModelFile(path: "decoder.mlmodelc/weights/weight.bin", size: 29870592,
                  sha256: "dcdeccd4ccf46e2675224f9f030d46c1a89e2bda4abb316e901e1a21f1597f8f"),
        ModelFile(path: "encoder.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "5488ed81fa1e370dd5411218d9b0e0562d01ca33c45b9ea1935bab6c8e8dc943"),
        ModelFile(path: "encoder.mlmodelc/coremldata.bin", size: 572,
                  sha256: "93d7f1b6412b965b379f3359e38f9c4330099b5b41f9d30b85bf7286b098a78d"),
        ModelFile(path: "encoder.mlmodelc/model.mil", size: 998158,
                  sha256: "a6341253a353e57d546060d5a2add769229be06781200216be866d6cdecb382a"),
        ModelFile(path: "encoder.mlmodelc/weights/weight.bin", size: 564646848,
                  sha256: "e3dbd37659c7ef51d2dc691afac42fbdd1f04998fa62816ff0f2eebec5cc3d01"),
        ModelFile(path: "joint.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "a1a90a7d5f8b86f564a42ab45b42a43eb0bbce6682176916bd94591b28cca447"),
        ModelFile(path: "joint.mlmodelc/coremldata.bin", size: 341,
                  sha256: "15415f76583ac18c78be1a4192aad2023432acd9095baf4862b86e5122cf0958"),
        ModelFile(path: "joint.mlmodelc/model.mil", size: 5072,
                  sha256: "521da827005ddcf3fbd439d12f85c34b1273642635b39a87bfbc931131cd3bf6"),
        ModelFile(path: "joint.mlmodelc/weights/weight.bin", size: 18911744,
                  sha256: "c0ef0a3a6598f962d2aad598dc6850e4428874033419817121e11f1fff4a9cfe"),
        ModelFile(path: metadata, size: 3005,
                  sha256: "c76ea7b1d9f0d32f872424bf6ba0cde46a9d05347e1b8595c09cef74180c5f8c"),
        ModelFile(path: tokenizer, size: 284969,
                  sha256: "fb70c8fcb6472cda2bdb799b156a8941e72762344a7c636d3b1275f1d53c4a6b"),
    ]

    static var directory: URL { ParakeetModel.folder.appendingPathComponent("nemotron-3.5-1120ms", isDirectory: true) }

    /// Download with `ModelDownload(manifest: NemotronModel.manifest)`.
    static var manifest: ModelManifest {
        ModelManifest(repo: repo, revision: revision, folder: remoteFolder, files: files, directory: directory,
                      staging: ParakeetModel.folder.appendingPathComponent("nemotron-3.5-1120ms.partial", isDirectory: true))
    }

    static var downloadSize: Int64 { manifest.downloadSize }

    /// Installed means: the download finished and every file passed its check (the folder is renamed only then).
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(tokenizer).path) }
}

// MARK: Stream

/// Speech to text while the person speaks. Feed 16 kHz mono samples from any thread; every 1.12 s of audio the
/// model decodes a chunk on its own serial queue and the text so far comes back through `onPartial`. The text only
/// grows. `finish` decodes the rest and returns the whole text.
///
/// Callbacks run on `callbackQueue` (the main queue unless given) and only for the current session: after `reset()`
/// or a new `begin`, late callbacks of the old session are dropped (a `finish` completion always comes).
final class NemotronStream {
    static let sampleRate = 16_000
    /// Audio that waits for the model (it is still loading, or slower than speech) is kept up to this long;
    /// later audio is dropped until the model catches up.
    static let maxBacklogSeconds = 300

    /// The text so far, after each chunk that added to it.
    var onPartial: ((String) -> Void)?
    /// The language the model names in its output, e.g. "ru-RU"; once per session, mostly useful with "auto".
    var onLanguage: ((String) -> Void)?
    /// Loading or recognition failed; the session stops taking audio, and `finish` returns the same error.
    var onError: ((Error) -> Void)?
    /// Milliseconds the model needed for one 1120 ms chunk (mel, encoder, decoder).
    var onChunk: ((Double) -> Void)?

    let directory: URL
    private let callbackQueue: DispatchQueue
    /// The engine lives here; loading and recognition never run on the main thread.
    private let queue = DispatchQueue(label: "nook.nemotron", qos: .userInitiated, autoreleaseFrequency: .workItem)

    // On `queue`.
    private var engine: NemotronEngine?
    private var engineSession = 0
    private var sessionError: Error?
    private var published = ""
    private var languageSent = false

    // Guarded by `lock`: audio handed over by `feed` and not yet taken by the queue.
    private let lock = NSLock()
    private var session = 0
    private var accepting = false
    private var pending: [Float] = []
    private var drainScheduled = false
    private var dropped = 0

    init(directory: URL = NemotronModel.directory, callbackQueue: DispatchQueue = .main) {
        self.directory = directory
        self.callbackQueue = callbackQueue
    }

    /// Loads the models now (the first time on a Mac: Core ML prepares them for the Neural Engine, which takes
    /// a while); `done` gets the seconds it took, 0 when they were loaded already. `begin` loads them too.
    func load(_ done: ((Result<TimeInterval, Error>) -> Void)? = nil) {
        queue.async { [self] in
            let started = Date()
            let wasLoaded = engine != nil
            let result = Result { () -> TimeInterval in
                _ = try loadedEngine()
                return wasLoaded ? 0 : Date().timeIntervalSince(started)
            }
            if let done { callbackQueue.async { done(result) } }
        }
    }

    /// Frees the models (about 0.6 GB on disk); the next `begin` or `load` loads them again.
    func unload() {
        queue.async { [self] in
            engine = nil
            engineSession = 0
        }
    }

    /// Starts a new recognition and drops the previous one. `language` is a key of the model's prompt table:
    /// "auto", "ru", "uk", "en", "de", … or a region form like "ru-RU"; an unknown one means "auto".
    func begin(language: String = "auto") {
        // Queued inside the lock: a `feed` from the microphone's thread cannot queue its chunk before the reset.
        lock.withLock {
            session += 1
            accepting = true
            pending.removeAll(keepingCapacity: true)
            drainScheduled = false
            dropped = 0
            let current = session
            queue.async { [self] in
                published = ""
                languageSent = false
                sessionError = nil
                engineSession = current
                do {
                    try loadedEngine().reset(language: language)
                } catch {
                    fail(error, session: current)
                }
            }
        }
    }

    /// 16 kHz mono samples, from any thread (the microphone's callback too): copies them and returns at once.
    func feed(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let schedule = lock.withLock { () -> Int? in
            guard accepting else { return nil }
            let room = Self.maxBacklogSeconds * Self.sampleRate - pending.count
            let count = max(0, min(room, samples.count))
            if count > 0 { pending.append(contentsOf: UnsafeBufferPointer(rebasing: samples.prefix(count))) }
            dropped += samples.count - count
            guard !drainScheduled else { return nil }
            drainScheduled = true
            return session
        }
        if let schedule { queue.async { [self] in drain(schedule) } }
    }

    func feed(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { feed($0) }
    }

    /// Stops taking audio, decodes what is left (the last chunk padded with silence) and returns the whole text.
    func finish(_ done: @escaping (Result<String, Error>) -> Void) {
        let (current, audio) = lock.withLock { () -> (Int, [Float]) in
            accepting = false
            drainScheduled = false
            defer { pending = [] }
            return (session, pending)
        }
        queue.async { [self] in
            var result = Result<String, Error>.success("")
            if engineSession == current, let sessionError {
                result = .failure(sessionError)
            } else if engineSession == current, let engine {
                result = Result {
                    _ = try audio.withUnsafeBufferPointer { try engine.accept($0, chunkDone: chunkDone) }
                    try engine.flush(chunkDone: chunkDone)
                    return engine.text
                }
                if case .failure(let error) = result { sessionError = error }
            }
            callbackQueue.async { done(result) }
        }
    }

    /// Drops the current recognition without a result.
    func reset() {
        lock.withLock {
            session += 1
            accepting = false
            drainScheduled = false
            pending = []
            queue.async { [self] in
                engineSession = 0
                sessionError = nil
            }
        }
    }

    /// Samples dropped this session because the model fell more than `maxBacklogSeconds` behind.
    var droppedSamples: Int { lock.withLock { dropped } }

    // MARK: On the queue

    private func loadedEngine() throws -> NemotronEngine {
        if let engine { return engine }
        let loaded = try NemotronEngine(directory: directory)
        engine = loaded
        return loaded
    }

    private func drain(_ tag: Int) {
        var audio: [Float] = []
        let current = lock.withLock { () -> Bool in
            guard session == tag else { return false }
            drainScheduled = false
            swap(&audio, &pending)
            return true
        }
        guard current, engineSession == tag, sessionError == nil, let engine, !audio.isEmpty else { return }
        do {
            let grew = try audio.withUnsafeBufferPointer { try engine.accept($0, chunkDone: chunkDone) }
            if grew { publish(engine, tag) }
        } catch {
            fail(error, session: tag)
        }
    }

    private func chunkDone(_ milliseconds: Double) {
        callbackQueue.async { [self] in onChunk?(milliseconds) }
    }

    private func publish(_ engine: NemotronEngine, _ tag: Int) {
        if !languageSent, let language = engine.language {
            languageSent = true
            callbackQueue.async { [self] in if isCurrent(tag) { onLanguage?(language) } }
        }
        let text = engine.text
        guard text != published else { return }
        published = text
        callbackQueue.async { [self] in if isCurrent(tag) { onPartial?(text) } }
    }

    private func fail(_ error: Error, session tag: Int) {
        sessionError = error
        lock.withLock {
            guard session == tag else { return }
            accepting = false
            pending = []
        }
        callbackQueue.async { [self] in if isCurrent(tag) { onError?(error) } }
    }

    private func isCurrent(_ tag: Int) -> Bool { lock.withLock { session == tag } }
}

// MARK: Engine

/// The three Core ML models and the state of one recognition. Not thread-safe: use it from one serial queue.
final class NemotronEngine {
    /// Tokens in a row on one encoder frame before the decoder moves on (a stuck decoder would repeat forever).
    private static let maxSymbolsPerFrame = 10

    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel

    private let vocabulary: [String]
    /// `<ru-RU>`-style tokens the model writes before the text: kept out of it.
    private let languageTags: Set<Int>
    private let prompts: [String: Int]
    private let autoPrompt: Int
    private let blank: Int
    private let bands: Int
    private let chunkFrames: Int
    private let cacheFrames: Int
    private let encoderWidth: Int
    private let decoderWidth: Int
    private let channelShape: [NSNumber]
    private let timeShape: [NSNumber]
    private let stateShape: [NSNumber]

    // Inputs refilled in place.
    private let mel: MLMultiArray
    private let melLength: MLMultiArray
    private let prompt: MLMultiArray
    private let token: MLMultiArray
    private let tokenLength: MLMultiArray
    private let encoderStep: MLMultiArray
    private let decoderStep: MLMultiArray

    // Streaming state: encoder caches and the decoder LSTM, carried from chunk to chunk.
    private var cacheChannel: MLMultiArray
    private var cacheTime: MLMultiArray
    private var cacheLength: MLMultiArray
    private var h: MLMultiArray
    private var c: MLMultiArray
    private var lastToken: Int
    /// `decoderStep`, `nextH` and `nextC` hold the decoder's answer to (`lastToken`, `h`, `c`).
    private var decoderReady = false
    private var nextH: MLMultiArray?
    private var nextC: MLMultiArray?

    private let features = NemotronMel()
    /// The encoder's mel input, frame after frame: the previous chunk's last `cacheFrames`, then this chunk.
    private var frames: [Float]
    private var pieces = ""
    private(set) var tokenCount = 0
    private(set) var language: String?

    init(directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(NemotronModel.tokenizer).path) else {
            throw ParakeetError.model(L("Модель не скачана"))
        }
        let damaged = ParakeetError.model(L("Описание модели повреждено."))
        let data = try Data(contentsOf: directory.appendingPathComponent(NemotronModel.metadata))
        guard let meta = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blank = meta["blank_idx"] as? Int,
              let bands = meta["mel_features"] as? Int,
              let chunkFrames = meta["chunk_mel_frames"] as? Int,
              let cacheFrames = meta["pre_encode_cache"] as? Int,
              let totalFrames = meta["total_mel_frames"] as? Int, totalFrames == chunkFrames + cacheFrames,
              let encoderWidth = meta["encoder_dim"] as? Int,
              let decoderWidth = meta["decoder_hidden"] as? Int,
              let layers = meta["decoder_layers"] as? Int,
              let channelShape = meta["cache_channel_shape"] as? [Int],
              let timeShape = meta["cache_time_shape"] as? [Int],
              let prompts = meta["prompt_dictionary"] as? [String: Int],
              let autoPrompt = meta["default_prompt_id"] as? Int,
              let tags = meta["lang_tag_token_ids"] as? [Int],
              bands == NemotronMel.bands, meta["sample_rate"] as? Int == NemotronStream.sampleRate else {
            throw damaged
        }
        self.blank = blank
        self.bands = bands
        self.chunkFrames = chunkFrames
        self.cacheFrames = cacheFrames
        self.encoderWidth = encoderWidth
        self.decoderWidth = decoderWidth
        self.channelShape = channelShape.map { NSNumber(value: $0) }
        self.timeShape = timeShape.map { NSNumber(value: $0) }
        stateShape = [NSNumber(value: layers), 1, NSNumber(value: decoderWidth)]
        self.prompts = prompts
        self.autoPrompt = autoPrompt
        languageTags = Set(tags)

        let tokenizer = try Data(contentsOf: directory.appendingPathComponent(NemotronModel.tokenizer))
        guard let table = try JSONSerialization.jsonObject(with: tokenizer) as? [String: String] else {
            throw ParakeetError.model(L("Словарь модели повреждён."))
        }
        var words = [String](repeating: "", count: blank)
        for (key, value) in table { if let id = Int(key), words.indices.contains(id) { words[id] = value } }
        vocabulary = words

        // The Neural Engine, as FluidAudio found: `.all` sends the int8 encoder to the GPU, about 10× slower.
        func load(_ name: String) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            return try MLModel(contentsOf: directory.appendingPathComponent("\(name).mlmodelc"), configuration: configuration)
        }
        encoder = try load("encoder")
        decoder = try load("decoder")
        joint = try load("joint")

        mel = try MLMultiArray(shape: [1, NSNumber(value: bands), NSNumber(value: totalFrames)], dataType: .float32)
        melLength = try MLMultiArray(shape: [1], dataType: .int32)
        melLength[0] = NSNumber(value: totalFrames)
        prompt = try MLMultiArray(shape: [1], dataType: .int32)
        token = try MLMultiArray(shape: [1, 1], dataType: .int32)
        tokenLength = try MLMultiArray(shape: [1], dataType: .int32)
        tokenLength[0] = 1
        encoderStep = try MLMultiArray(shape: [1, NSNumber(value: encoderWidth), 1], dataType: .float32)
        decoderStep = try MLMultiArray(shape: [1, NSNumber(value: decoderWidth), 1], dataType: .float32)
        cacheChannel = try Self.zeros(self.channelShape)
        cacheTime = try Self.zeros(self.timeShape)
        cacheLength = try MLMultiArray(shape: [1], dataType: .int32)
        h = try Self.zeros(stateShape)
        c = try Self.zeros(stateShape)
        lastToken = blank
        frames = [Float](repeating: 0, count: totalFrames * bands)

        // One silent chunk now: the first real chunk does not wait for Core ML to set the models up.
        try reset(language: "auto")
        features.pad(toReady: chunkFrames)
        _ = try runChunk()
        try reset(language: "auto")
    }

    /// A new recognition: empty caches, decoder and text.
    func reset(language: String) throws {
        let key = language.replacingOccurrences(of: "_", with: "-")
        let id = prompts[key] ?? prompts[key.lowercased()]
            ?? key.split(separator: "-").first.flatMap { prompts[String($0).lowercased()] } ?? autoPrompt
        prompt[0] = NSNumber(value: id)
        cacheChannel = try Self.zeros(channelShape)
        cacheTime = try Self.zeros(timeShape)
        // 1, not 0, as in FluidAudio: the encoder's cache slice must not be empty. The caches are zeros.
        // A new array: after a chunk `cacheLength` is the encoder's own output.
        cacheLength = try MLMultiArray(shape: [1], dataType: .int32)
        cacheLength[0] = 1
        h = try Self.zeros(stateShape)
        c = try Self.zeros(stateShape)
        lastToken = blank
        decoderReady = false
        nextH = nil
        nextC = nil
        features.reset()
        frames.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        pieces = ""
        tokenCount = 0
        self.language = nil
    }

    /// The text so far: "▁" starts a word; spaces collapsed.
    var text: String {
        pieces.replacingOccurrences(of: "\u{2581}", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Adds audio and decodes every chunk that is complete. True when tokens were added.
    @discardableResult
    func accept(_ samples: UnsafeBufferPointer<Float>, chunkDone: (Double) -> Void) throws -> Bool {
        features.append(samples)
        var grew = false
        while features.readyFrames >= chunkFrames {
            let started = DispatchTime.now().uptimeNanoseconds
            if try autoreleasepool(invoking: runChunk) { grew = true }
            chunkDone(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        }
        return grew
    }

    /// Decodes the audio after the last full chunk, padded with silence to a whole chunk, and then one more chunk of
    /// silence: the model often writes the closing full stop only once it has heard the pause (tested with `say`
    /// speech: without it Russian and Ukrainian ended without one).
    @discardableResult
    func flush(chunkDone: (Double) -> Void) throws -> Bool {
        guard features.received > 0 else { return false }
        // NeMo's frame count for this much audio (centred frames: one more than whole hops), plus the pause.
        let frameCount = features.received / NemotronMel.hop + 1 + chunkFrames
        var grew = false
        while features.nextFrame < frameCount {
            let started = DispatchTime.now().uptimeNanoseconds
            features.pad(toReady: chunkFrames)
            if try autoreleasepool(invoking: runChunk) { grew = true }
            chunkDone(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        }
        return grew
    }

    /// Mel → encoder (caches in and out) → greedy RNN-T over the chunk's encoder frames. Callers wrap it in an
    /// autorelease pool: Core ML's outputs (about 5 MB of encoder caches per chunk) otherwise pile up while one
    /// work item decodes many chunks (a backlog, or `finish`).
    private func runChunk() throws -> Bool {
        let totalFrames = cacheFrames + chunkFrames
        frames.withUnsafeMutableBufferPointer { buffer in
            features.compute(chunkFrames, into: buffer.baseAddress! + cacheFrames * bands)
            let to = mel.dataPointer.bindMemory(to: Float.self, capacity: mel.count)
            let bandStride = mel.strides[1].intValue
            let timeStride = mel.strides[2].intValue
            for t in 0..<totalFrames {
                for b in 0..<bands { to[b * bandStride + t * timeStride] = buffer[t * bands + b] }
            }
            // The next chunk starts with this one's last frames.
            let base = buffer.baseAddress!
            base.update(from: base + chunkFrames * bands, count: cacheFrames * bands)
        }

        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": mel, "mel_length": melLength, "cache_channel": cacheChannel, "cache_time": cacheTime,
            "cache_len": cacheLength, "prompt_id": prompt,
        ]))
        guard let encoded = output.featureValue(for: "encoded")?.multiArrayValue,
              let channel = output.featureValue(for: "cache_channel_out")?.multiArrayValue,
              let time = output.featureValue(for: "cache_time_out")?.multiArrayValue,
              let length = output.featureValue(for: "cache_len_out")?.multiArrayValue else {
            throw ParakeetError.model(L("Модель не вернула кадры кодировщика."))
        }
        cacheChannel = channel
        cacheTime = time
        cacheLength = length

        let view = try EncoderFrames(encoded, width: encoderWidth)
        var grew = false
        for t in 0..<view.count {
            view.copy(frame: t, into: encoderStep)
            for _ in 0..<Self.maxSymbolsPerFrame {
                try prepareDecoder()
                let best = try bestToken()
                if best == blank { break }
                emit(best)
                grew = true
            }
        }
        return grew
    }

    /// Runs the decoder LSTM on the last token unless its answer is ready (blank frames reuse it).
    private func prepareDecoder() throws {
        guard !decoderReady else { return }
        token[0] = NSNumber(value: lastToken)
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "token": token, "token_length": tokenLength, "h_in": h, "c_in": c,
        ]))
        guard let step = output.featureValue(for: "decoder_out")?.multiArrayValue,
              let newH = output.featureValue(for: "h_out")?.multiArrayValue,
              let newC = output.featureValue(for: "c_out")?.multiArrayValue else {
            throw ParakeetError.model(L("Модель не вернула состояние декодера."))
        }
        try Self.copy(step, into: decoderStep, width: decoderWidth)
        nextH = newH
        nextC = newC
        decoderReady = true
    }

    private func bestToken() throws -> Int {
        let output = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "encoder": encoderStep, "decoder": decoderStep,
        ]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw ParakeetError.model(L("Модель не вернула решение."))
        }
        let shape = logits.shape.map(\.intValue)
        let count = shape.last ?? 0
        guard logits.dataType == .float32, count > blank, logits.count == count else {
            throw ParakeetError.model(L("Неожиданная форма выхода модели: \(String(describing: shape))."))
        }
        let stride = logits.strides.last?.intValue ?? 1
        var best: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(logits.dataPointer.bindMemory(to: Float.self, capacity: (count - 1) * stride + 1), vDSP_Stride(stride),
                   &best, &index, vDSP_Length(count))
        return Int(index) / stride
    }

    private func emit(_ id: Int) {
        tokenCount += 1
        if languageTags.contains(id) {
            if language == nil, vocabulary.indices.contains(id) {
                language = vocabulary[id].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            }
        } else if vocabulary.indices.contains(id) {
            let piece = vocabulary[id]
            // `<unk>` and other special pieces; a lone "<" or ">" is text.
            if !(piece.count > 2 && piece.hasPrefix("<") && piece.hasSuffix(">")) { pieces += piece }
        }
        if let nextH, let nextC {
            h = nextH
            c = nextC
        }
        lastToken = id
        decoderReady = false
    }

    private static func zeros(_ shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        array.dataPointer.bindMemory(to: Float.self, capacity: array.count).update(repeating: 0, count: array.count)
        return array
    }

    /// Copies a [1, width, 1] or [1, 1, width] output into a [1, width, 1] input, whatever its strides.
    private static func copy(_ source: MLMultiArray, into destination: MLMultiArray, width: Int) throws {
        let shape = source.shape.map(\.intValue)
        guard shape.count == 3, source.dataType == .float32, let axis = [1, 2].first(where: { shape[$0] == width }) else {
            throw ParakeetError.model(L("Неожиданная форма выхода модели: \(String(describing: shape))."))
        }
        let stride = source.strides[axis].intValue
        let from = source.dataPointer.bindMemory(to: Float.self, capacity: source.count)
        let to = destination.dataPointer.bindMemory(to: Float.self, capacity: width)
        let step = destination.strides[1].intValue
        for i in 0..<width { to[i * step] = from[i * stride] }
    }

    /// Encoder frames as [1, width, T] or [1, T, width].
    private struct EncoderFrames {
        let array: MLMultiArray
        let width: Int
        let widthStride: Int
        let timeStride: Int
        let count: Int

        init(_ array: MLMultiArray, width: Int) throws {
            let shape = array.shape.map(\.intValue)
            guard shape.count == 3, array.dataType == .float32, let axis = [1, 2].first(where: { shape[$0] == width }) else {
                throw ParakeetError.model(L("Неожиданная форма кадров: \(String(describing: shape))."))
            }
            let time = axis == 1 ? 2 : 1
            self.array = array
            self.width = width
            widthStride = array.strides[axis].intValue
            timeStride = array.strides[time].intValue
            count = shape[time]
        }

        func copy(frame t: Int, into destination: MLMultiArray) {
            let from = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            let to = destination.dataPointer.bindMemory(to: Float.self, capacity: width)
            let step = destination.strides[1].intValue
            let base = t * timeStride
            for i in 0..<width { to[i * step] = from[base + i * widthStride] }
        }
    }
}

// MARK: Mel features

/// Log-mel features as NeMo computes them for this model: pre-emphasis 0.97, a 25 ms symmetric Hann window in a
/// 512-point FFT, 10 ms hop, centred frames, power spectrum, 128 Slaney mel bands (0–8 kHz), log(x + 2⁻²⁴), no
/// normalization (FluidAudio's NemotronMelExtractor, same settings). Computed as a stream: frame k is centred on
/// sample 160·k of the whole recording, so a frame does not depend on where the audio was cut into chunks (the
/// reference pads every chunk on its own). A frame is ready once the 200 samples after its centre have arrived.
final class NemotronMel {
    static let bands = 128
    static let hop = 160
    private static let fftSize = 512
    private static let windowSize = 400
    private static let bins = fftSize / 2 + 1
    /// A frame's window covers this many samples on each side of its centre.
    private static let reach = windowSize / 2
    private static let preemphasis: Float = 0.97

    private let window: [Float]
    /// [bins × bands]: a power spectrum row times this gives the mel bands.
    private let filters: [Float]
    private let dft: vDSP_DFT_Setup

    /// Pre-emphasized samples from the absolute index `start` on.
    private var samples: [Float] = []
    private var start = 0
    private var previous: Float = 0
    /// Samples received this recording (padding included).
    private(set) var received = 0
    private(set) var nextFrame = 0

    private var real = [Float](repeating: 0, count: fftSize)
    private var imaginary = [Float](repeating: 0, count: fftSize)
    private var realOut = [Float](repeating: 0, count: fftSize)
    private var imaginaryOut = [Float](repeating: 0, count: fftSize)
    private var power: [Float] = []

    init() {
        window = (0..<Self.windowSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.windowSize - 1))) }
        filters = Self.melFilters()
        dft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)!
    }

    deinit { vDSP_DFT_DestroySetup(dft) }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        start = 0
        previous = 0
        received = 0
        nextFrame = 0
    }

    func append(_ input: UnsafeBufferPointer<Float>) {
        samples.reserveCapacity(samples.count + input.count)
        for x in input {
            samples.append(x - Self.preemphasis * previous)
            previous = x
        }
        received += input.count
    }

    /// Appends silence until `count` frames are ready (the end of a recording).
    func pad(toReady count: Int) {
        let needed = (nextFrame + count - 1) * Self.hop + Self.reach - received
        guard needed > 0 else { return }
        [Float](repeating: 0, count: needed).withUnsafeBufferPointer { append($0) }
    }

    /// Frames whose whole window has arrived and that were not computed yet.
    var readyFrames: Int {
        guard received >= Self.reach else { return 0 }
        return max(0, (received - Self.reach) / Self.hop + 1 - nextFrame)
    }

    /// Computes the next `count` frames (at most `readyFrames`) into `out`, frame after frame, `bands` values each.
    func compute(_ count: Int, into out: UnsafeMutablePointer<Float>) {
        if power.count < count * Self.bins { power = [Float](repeating: 0, count: count * Self.bins) }
        let offset = (Self.fftSize - Self.windowSize) / 2
        for f in 0..<count {
            let first = (nextFrame + f) * Self.hop - Self.reach
            // Before the recording (the first two frames) and after `received`: zeros.
            let from = max(first, start)
            let to = min(first + Self.windowSize, start + samples.count)
            vDSP_vclr(&real, 1, vDSP_Length(Self.fftSize))
            vDSP_vclr(&imaginary, 1, vDSP_Length(Self.fftSize))
            if to > from {
                samples.withUnsafeBufferPointer { source in
                    window.withUnsafeBufferPointer { window in
                        real.withUnsafeMutableBufferPointer { frame in
                            vDSP_vmul(source.baseAddress! + (from - start), 1, window.baseAddress! + (from - first), 1,
                                      frame.baseAddress! + offset + (from - first), 1, vDSP_Length(to - from))
                        }
                    }
                }
            }
            vDSP_DFT_Execute(dft, real, imaginary, &realOut, &imaginaryOut)
            power.withUnsafeMutableBufferPointer { power in
                let row = power.baseAddress! + f * Self.bins
                vDSP_vsq(realOut, 1, row, 1, vDSP_Length(Self.bins))
                vDSP_vma(imaginaryOut, 1, imaginaryOut, 1, row, 1, row, 1, vDSP_Length(Self.bins))
            }
        }
        // [count × bins] · [bins × bands] → [count × bands], then log(x + 2⁻²⁴).
        vDSP_mmul(power, 1, filters, 1, out, 1, vDSP_Length(count), vDSP_Length(Self.bands), vDSP_Length(Self.bins))
        var guardValue: Float = 1.0 / 16_777_216
        let total = count * Self.bands
        vDSP_vsadd(out, 1, &guardValue, out, 1, vDSP_Length(total))
        var length = Int32(total)
        vvlogf(out, out, &length)

        nextFrame += count
        // Keep only what the next frames still need.
        let keep = nextFrame * Self.hop - Self.reach - start
        if keep > 10 * NemotronStream.sampleRate {
            samples.removeFirst(keep)
            start += keep
        }
    }

    /// librosa's `mel(sr: 16000, n_fft: 512, n_mels: 128, fmin: 0, fmax: 8000, norm: "slaney")`, transposed.
    private static func melFilters() -> [Float] {
        let step = log(6.4) / 27
        func mel(_ hz: Double) -> Double { hz < 1000 ? hz * 3 / 200 : 15 + log(hz / 1000) / step }
        func hz(_ mel: Double) -> Double { mel < 15 ? mel * 200 / 3 : 1000 * exp(step * (mel - 15)) }
        let top = mel(Double(NemotronStream.sampleRate) / 2)
        let points = (0..<(bands + 2)).map { hz(top * Double($0) / Double(bands + 1)) }
        var filters = [Float](repeating: 0, count: bins * bands)
        for band in 0..<bands {
            let left = points[band], centre = points[band + 1], right = points[band + 2]
            let norm = 2 / (right - left)
            for bin in 0..<bins {
                let frequency = Double(bin) * Double(NemotronStream.sampleRate) / Double(fftSize)
                let weight = max(0, min((frequency - left) / (centre - left), (right - frequency) / (right - centre)))
                filters[bin * bands + band] = Float(weight * norm)
            }
        }
        return filters
    }
}
