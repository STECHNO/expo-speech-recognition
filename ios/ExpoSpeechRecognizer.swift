import AVFoundation
import Foundation
import Speech

/// A helper for transcribing speech to text using SFSpeechRecognizer and AVAudioEngine.
actor ExpoSpeechRecognizer: ObservableObject {
  enum RecognizerError: Error {
    case nilRecognizer
    case notAuthorizedToRecognize
    case notPermittedToRecord
    case recognizerIsUnavailable
    case invalidAudioSource

    var message: String {
      switch self {
      case .nilRecognizer: return "Can't initialize speech recognizer"
      case .notAuthorizedToRecognize: return "Not authorized to recognize speech"
      case .notPermittedToRecord: return "Not permitted to record audio"
      case .recognizerIsUnavailable: return "Recognizer is unavailable"
      case .invalidAudioSource: return "Invalid audio source"
      }
    }
  }

  private var options: SpeechRecognitionOptions?
  private var audioEngine: AVAudioEngine?
  private var request: SFSpeechRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?
  private var speechStartHandler: (() -> Void)?
  private var file: AVAudioFile?
  private var outputFileUrl: URL?

  /// Detection timer, for non-continuous speech recognition
  @MainActor var detectionTimer: Timer?

  @MainActor var endHandler: (() -> Void)?
  @MainActor var recordingHandler: ((String) -> Void)?

  /// Initializes a new speech recognizer. If this is the first time you've used the class, it
  /// requests access to the speech recognizer and the microphone.
  init(
    locale: Locale
  ) async throws {
    recognizer = SFSpeechRecognizer(
      locale: locale
    )

    guard recognizer != nil else {
      throw RecognizerError.nilRecognizer
    }

    guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
      throw RecognizerError.notAuthorizedToRecognize
    }

    guard await AVAudioSession.sharedInstance().hasPermissionToRecord() else {
      throw RecognizerError.notPermittedToRecord
    }
  }

  func getLocale() -> String? {
    return recognizer?.locale.identifier
  }

  @MainActor func start(
    options: SpeechRecognitionOptions,
    resultHandler: @escaping (SFSpeechRecognitionResult) -> Void,
    errorHandler: @escaping (Error) -> Void,
    endHandler: (() -> Void)?,
    speechStartHandler: @escaping (() -> Void),
    recordingHandler: @escaping (String) -> Void
  ) {
    self.endHandler = endHandler
    self.recordingHandler = recordingHandler
    Task {
      await startRecognizer(
        options: options,
        resultHandler: resultHandler,
        errorHandler: errorHandler,
        speechStartHandler: speechStartHandler
      )
    }
  }

  @MainActor func stop() {
    Task {
      await reset()
    }
  }

  ///
  /// Returns the state of the speech recognizer task
  /// type SpeechRecognitionState =
  ///  | "inactive"
  ///  | "starting"
  ///  | "recognizing"
  ///  | "stopping";
  func getState() -> String {
    switch task?.state {
    case .none:
      return "inactive"
    case .some(.starting), .some(.running):
      return "recognizing"
    case .some(.canceling):
      return "stopping"
    default:
      return "inactive"
    }
  }

  /// Begin transcribing audio.
  ///
  /// Creates a `SFSpeechRecognitionTask` that transcribes speech to text until you call `stop()`.
  private func startRecognizer(
    options: SpeechRecognitionOptions,
    resultHandler: @escaping (SFSpeechRecognitionResult) -> Void,
    errorHandler: @escaping (Error) -> Void,
    speechStartHandler: @escaping () -> Void
  ) {
    self.file = nil
    self.outputFileUrl = nil
    self.speechStartHandler = speechStartHandler

    guard let recognizer, recognizer.isAvailable else {
      errorHandler(RecognizerError.recognizerIsUnavailable)
      return
    }

    do {
      let request = Self.prepareRequest(
        options: options,
        recognizer: recognizer
      )
      self.request = request

      // Check if options.audioSource is set, if it is, then it is sourced from a file
      let isSourcedFromFile = options.audioSource?.uri != nil

      var audioEngine: AVAudioEngine?
      if isSourcedFromFile {
        // If we're doing file-based recognition we don't need to create an audio engine
        self.audioEngine = nil
      } else {
        audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        if options.recordingOptions?.persist == true {
          let (audio, outputUrl) = prepareFileWriter(
            outputFilePath: options.recordingOptions?.outputFilePath,
            audioEngine: audioEngine!
          )
          self.file = audio
          self.outputFileUrl = outputUrl
        }
        try Self.prepareEngine(
          audioEngine: audioEngine!,
          options: options,
          request: request,
          file: self.file
        )
      }

      // Don't run any timers if the audio source is from a file
      let continuous = options.continuous || isSourcedFromFile

      self.task = recognizer.recognitionTask(
        with: request,
        resultHandler: { [weak self] result, error in
          // Speech start event
          if result != nil && error == nil {
            Task { [weak self] in
              await self?.handleSpeechStart()
            }
          }

          // Result handler
          self?.recognitionHandler(
            audioEngine: audioEngine,
            result: result,
            error: error,
            resultHandler: resultHandler,
            errorHandler: errorHandler,
            continuous: continuous
          )
        })

      if !continuous {
        invalidateAndScheduleTimer()
      }
    } catch {
      self.reset()
      errorHandler(error)
    }
  }

  private func prepareFileWriter(outputFilePath: String?, audioEngine: AVAudioEngine) -> (
    AVAudioFile?, URL?
  ) {
    let baseDir: URL

    if let outputFilePath = outputFilePath {
      baseDir = URL(fileURLWithPath: outputFilePath)
    } else {
      guard let dirPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      else {
        print("Failed to get cache directory path.")
        return (nil, nil)
      }
      baseDir = dirPath
    }

    let filePath = baseDir.appendingPathComponent("recording_\(UUID().uuidString)")
      .appendingPathExtension("caf")

    do {
      // Ensure settings are compatible with the input format
      let file = try AVAudioFile(
        forWriting: filePath,
        settings: audioEngine.inputNode.inputFormat(forBus: 0).settings
      )
      return (file, filePath)
    } catch {
      print("Failed to create AVAudioFile: \(error)")
      return (nil, nil)
    }
  }

  private func handleSpeechStart() {
    speechStartHandler?()
    speechStartHandler = nil
  }

  /// Reset the speech recognizer.
  private func reset() {
    let taskWasRunning = task != nil

    task?.cancel()
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    if let filePath = self.outputFileUrl?.path {
      Task {
        await MainActor.run {
          self.recordingHandler?(filePath)
          self.recordingHandler = nil
        }
      }
    }
    file = nil
    outputFileUrl = nil
    audioEngine = nil
    request = nil
    task = nil
    speechStartHandler = nil
    invalidateDetectionTimer()

    // If the task was running, emit the end handler
    // This avoids emitting the end handler multiple times

    // log the end event to the console
    print("SpeechRecognizer: end")
    if taskWasRunning {
      Task {
        await MainActor.run {
          self.endHandler?()
        }
      }
    }
  }

  private static func prepareRequest(
    options: SpeechRecognitionOptions, recognizer: SFSpeechRecognizer
  ) -> SFSpeechRecognitionRequest {

    let request: SFSpeechRecognitionRequest
    if let audioSource = options.audioSource {
      request = SFSpeechURLRecognitionRequest(url: URL(string: audioSource.uri)!)
    } else {
      request = SFSpeechAudioBufferRecognitionRequest()
    }

    request.shouldReportPartialResults = options.interimResults

    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = options.requiresOnDeviceRecognition
    }

    if let contextualStrings = options.contextualStrings {
      request.contextualStrings = contextualStrings
    }

    if #available(iOS 16, *) {
      request.addsPunctuation = options.addsPunctuation
    }

    return request
  }
  private static func prepareEngine(
    audioEngine: AVAudioEngine,
    options: SpeechRecognitionOptions,
    request: SFSpeechRecognitionRequest,
    file: AVAudioFile?
  ) throws {
    let audioSession = AVAudioSession.sharedInstance()

    try audioSession.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.defaultToSpeaker, .allowBluetooth]
    )
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.inputFormat(forBus: 0)

    guard let audioBufferRequest = request as? SFSpeechAudioBufferRecognitionRequest else {
      throw RecognizerError.invalidAudioSource
    }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
      (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
      audioBufferRequest.append(buffer)
      if let file = file {
        do {
          try file.write(from: buffer)
        } catch {
          print("Failed to write buffer to file: \(error)")
        }
      }
    }

    audioEngine.prepare()
    try audioEngine.start()
  }

  nonisolated private func recognitionHandler(
    audioEngine: AVAudioEngine?,
    result: SFSpeechRecognitionResult?,
    error: Error?,
    resultHandler: @escaping (SFSpeechRecognitionResult) -> Void,
    errorHandler: @escaping (Error) -> Void,
    continuous: Bool
  ) {
    let receivedFinalResult = result?.isFinal ?? false
    let receivedError = error != nil

    if let result: SFSpeechRecognitionResult {
      Task { @MainActor in
        let taskState = await task?.state
        // Make sure the task is running before emitting the result
        if taskState != .none {
          resultHandler(result)
        }
      }
    }

    if let error: Error {
      // TODO: don't emit no-speech if there were already interim results
      Task { @MainActor in
        errorHandler(error)
      }
    }

    if receivedFinalResult || receivedError {
      //      audioEngine?.stop()
      //      audioEngine?.inputNode.removeTap(onBus: 0)
      Task { @MainActor in
        await reset()
      }
    }

    // Non-continuous speech recognition
    // Stop the speech recognizer if the timer fires after not receiving a result for 3 seconds
    if !continuous && !receivedError {
      invalidateAndScheduleTimer()
    }
  }

  nonisolated private func invalidateDetectionTimer() {
    Task { @MainActor in
      self.detectionTimer?.invalidate()
    }
  }

  nonisolated private func invalidateAndScheduleTimer() {
    Task { @MainActor in
      let taskState = await task?.state

      self.detectionTimer?.invalidate()

      // Don't schedule a timer if recognition isn't running
      if taskState == .none {
        return
      }

      self.detectionTimer = Timer.scheduledTimer(
        withTimeInterval: 3,
        repeats: false
      ) { [weak self] _ in
        Task { [weak self] in
          await self?.reset()
        }
      }
    }
  }
}

extension SFSpeechRecognizer {
  static func hasAuthorizationToRecognize() async -> Bool {
    await withCheckedContinuation { continuation in
      requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  static func requestPermissions() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

extension AVAudioSession {
  func hasPermissionToRecord() async -> Bool {
    await withCheckedContinuation { continuation in
      requestRecordPermission { authorized in
        continuation.resume(returning: authorized)
      }
    }
  }
}
