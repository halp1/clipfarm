import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings window. It is the only window ClipFarm has.
struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Clip") {
                    durationControls
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        HotkeyRecorderView(hotkey: $model.hotkey)
                            .frame(width: 130, height: 24)
                    }
                    if let warning = model.hotkeyWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Quality") {
                    Picker("Frame rate", selection: $model.frameRate) {
                        ForEach(Preferences.frameRateChoices, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    Picker("Resolution", selection: $model.resolutionScale) {
                        ForEach(Preferences.resolutionScaleChoices, id: \.self) { scale in
                            Text(Preferences.resolutionLabel(scale)).tag(scale)
                        }
                    }
                    Text(model.qualityHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Audio") {
                    Picker("Record", selection: $model.audioSource) {
                        ForEach(AudioSource.allCases, id: \.self) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    if model.audioSource.needsOutputDevice {
                        Picker("Output", selection: $model.outputDeviceUID) {
                            Text(model.defaultOutputLabel).tag("")
                            ForEach(model.outputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        Text("Records the sound going to this device, whatever is playing through it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if model.audioSource.needsInputDevice {
                        Picker("Input", selection: $model.inputDeviceUID) {
                            Text("Current default").tag("")
                            ForEach(model.inputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        if model.inputDevices.isEmpty {
                            Text("No input devices are plugged in.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.audioSource != .none {
                        Button("Rescan devices") { model.reloadDevices() }
                    }
                }

                Section("Save to") {
                    Toggle("Clipboard", isOn: $model.clipboardEnabled)
                    Toggle("Folder", isOn: $model.folderEnabled)
                    if model.folderEnabled {
                        HStack {
                            Text(model.folderLabel)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { model.chooseFolder() }
                        }
                    }
                    Toggle("HALP/CDN", isOn: $model.cdnEnabled)
                        .disabled(!model.hasAPIKey)
                    cdnDetail
                }

                Section("ClipFarm") {
                    Toggle("Open at login", isOn: $model.launchAtLogin)
                    Toggle("Show in the menu bar", isOn: $model.showMenuBarItem)
                    HStack {
                        Circle()
                            .fill(model.isRecording ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(model.recordingStatus)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Spacer()
                        if !model.isRecording {
                            Button("Start recording") { model.startRecording() }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Clips hold the last \(model.durationLabel) of the screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit ClipFarm") { NSApp.terminate(nil) }
            }
            .padding(12)
        }
        .frame(width: 500, height: 720)
        .onAppear { model.refresh() }
    }

    private var durationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Length")
                Spacer()
                TextField(
                    "",
                    value: $model.duration,
                    formatter: SettingsModel.durationFormatter
                )
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                Text("sec")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $model.duration,
                in: Preferences.minimumDuration...Preferences.maximumDuration
            )
            HStack {
                Text("1s")
                Spacer()
                Text("5m")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cdnDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.hasAPIKey {
                HStack {
                    Text(model.maskedKey ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { model.removeKey() }
                }
                HStack {
                    Text("Folder")
                    Spacer()
                    // labelsHidden keeps Form from drawing the placeholder as a
                    // second label beside the row title.
                    TextField("", text: $model.cdnFolder, prompt: Text("clips"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { model.commitCDNFolder() }
                }
                Text(model.cdnFolderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("The CDN needs an API key before it can take uploads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                SecureField("", text: $model.keyInput, prompt: Text("Paste a key"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button(model.isCheckingKey ? "Checking…" : "Save key") { model.saveKey() }
                    .disabled(model.keyInput.isEmpty || model.isCheckingKey)
            }
            if let result = model.keyMessage {
                Text(result.text)
                    .font(.callout)
                    .foregroundStyle(result.isError ? .red : .green)
            }
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    static let durationFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = NSNumber(value: Preferences.minimumDuration)
        formatter.maximum = NSNumber(value: Preferences.maximumDuration)
        return formatter
    }()

    struct Message { let text: String; let isError: Bool }

    private let preferences = Preferences.shared
    private var applying = false

    @Published var duration: Double = 30 { didSet { apply { preferences.clipDuration = duration } } }
    @Published var hotkey: Hotkey = .default {
        didSet {
            apply {
                preferences.hotkey = hotkey
                HotkeyManager.shared.register(hotkey)
                hotkeyWarning = nil
            }
        }
    }
    @Published var clipboardEnabled = true {
        didSet { apply { preferences.setDestination(.clipboard, enabled: clipboardEnabled) } }
    }
    @Published var folderEnabled = false {
        didSet {
            apply {
                preferences.setDestination(.folder, enabled: folderEnabled)
                if folderEnabled && preferences.saveFolder == nil { chooseFolder() }
            }
        }
    }
    @Published var cdnEnabled = false {
        didSet { apply { preferences.setDestination(.cdn, enabled: cdnEnabled) } }
    }
    @Published var showMenuBarItem = true {
        didSet { apply { preferences.showMenuBarItem = showMenuBarItem } }
    }
    @Published var launchAtLogin = false {
        didSet {
            apply {
                if !LoginItem.setEnabled(launchAtLogin) {
                    launchAtLogin = LoginItem.isEnabled
                }
            }
        }
    }

    @Published var frameRate: Int = 30 {
        didSet { apply { preferences.frameRate = frameRate } }
    }
    @Published var resolutionScale: Double = 1.0 {
        didSet { apply { preferences.resolutionScale = resolutionScale } }
    }

    @Published var audioSource: AudioSource = .output {
        didSet {
            apply {
                preferences.audioSource = audioSource
                if audioSource != .none { reloadDevices() }
            }
        }
    }
    /// The chosen output device UID. An empty string follows the system default.
    @Published var outputDeviceUID: String = "" {
        didSet {
            apply { preferences.outputDeviceUID = outputDeviceUID.isEmpty ? nil : outputDeviceUID }
        }
    }
    @Published var outputDevices: [AudioOutputDevices.Device] = []
    /// The chosen input device UID. An empty string means the system default.
    @Published var inputDeviceUID: String = "" {
        didSet {
            apply { preferences.inputDeviceUID = inputDeviceUID.isEmpty ? nil : inputDeviceUID }
        }
    }
    @Published var inputDevices: [AudioDevices.Device] = []

    /// Held as text while it is being typed, then tidied when the field is left.
    @Published var cdnFolder: String = "" {
        didSet { apply { preferences.cdnFolder = cdnFolder } }
    }

    @Published var keyInput = ""
    @Published var keyMessage: Message?
    @Published var isCheckingKey = false
    @Published var hasAPIKey = false
    @Published var maskedKey: String?
    @Published var isRecording = false
    @Published var hotkeyWarning: String?

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: CaptureEngine.stateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isRecording = CaptureEngine.shared.isRunning }
        }
        NotificationCenter.default.addObserver(
            forName: HotkeyManager.registrationFailed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotkeyWarning = "Another app already uses that combination. Pick a different one."
            }
        }
    }

    /// Writes a preference without the published setter looping back on itself.
    private func apply(_ work: () -> Void) {
        guard !applying else { return }
        applying = true
        work()
        applying = false
    }

    func refresh() {
        applying = true
        duration = preferences.clipDuration
        hotkey = preferences.hotkey
        clipboardEnabled = preferences.isSelected(.clipboard)
        folderEnabled = preferences.isSelected(.folder)
        cdnEnabled = preferences.isSelected(.cdn)
        showMenuBarItem = preferences.showMenuBarItem
        launchAtLogin = LoginItem.isEnabled
        frameRate = preferences.frameRate
        resolutionScale = preferences.resolutionScale
        audioSource = preferences.audioSource
        inputDeviceUID = preferences.inputDeviceUID ?? ""
        outputDeviceUID = preferences.outputDeviceUID ?? ""
        inputDevices = AudioDevices.available()
        outputDevices = AudioOutputDevices.available()
        // A device that is currently unplugged leaves the picker holding a tag that
        // matches no row, which draws as a blank control. Fall back to the default so
        // it always shows what will actually be recorded.
        if !inputDeviceUID.isEmpty && !inputDevices.contains(where: { $0.id == inputDeviceUID }) {
            inputDeviceUID = ""
        }
        if !outputDeviceUID.isEmpty && !outputDevices.contains(where: { $0.id == outputDeviceUID }) {
            outputDeviceUID = ""
        }
        cdnFolder = preferences.cdnFolder
        hasAPIKey = KeychainStore.hasAPIKey
        maskedKey = KeychainStore.maskedKey
        isRecording = CaptureEngine.shared.isRunning
        applying = false
    }

    var folderLabel: String {
        preferences.saveFolder?.path ?? "No folder picked"
    }

    var durationLabel: String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 { return minutes == 1 ? "minute" : "\(minutes) minutes" }
        return "\(minutes)m \(remainder)s"
    }

    var recordingStatus: String {
        isRecording ? "Recording the screen" : "Not recording"
    }

    func startRecording() {
        Task { await CaptureEngine.shared.start() }
    }

    /// Picks up a device that was plugged in after the window opened.
    func reloadDevices() {
        inputDevices = AudioDevices.available()
        outputDevices = AudioOutputDevices.available()
        // A device that went away falls back to the current default.
        if !inputDeviceUID.isEmpty && !inputDevices.contains(where: { $0.id == inputDeviceUID }) {
            inputDeviceUID = ""
        }
        if !outputDeviceUID.isEmpty && !outputDevices.contains(where: { $0.id == outputDeviceUID }) {
            outputDeviceUID = ""
        }
    }

    /// Says what the current quality settings will actually record, since the numbers
    /// on their own do not say much.
    var qualityHint: String {
        let size = CaptureEngine.shared.plannedCaptureSize(scale: resolutionScale)
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0 else { return "Lower settings use less battery." }
        return "Records \(width) by \(height) at \(frameRate) fps. Lower uses less battery."
    }

    /// Shows where a clip will actually end up, so the folder is not a guess.
    var cdnFolderHint: String {
        "Clips go to cdn.haelp.dev/obj/\(CDNUploader.sanitizeFolder(cdnFolder))/"
    }

    /// Tidies what was typed, so the field shows what is stored.
    func commitCDNFolder() {
        let cleaned = CDNUploader.sanitizeFolder(cdnFolder)
        if cleaned != cdnFolder { cdnFolder = cleaned }
    }

    /// Names the device the empty selection will follow, so the choice is not a guess.
    var defaultOutputLabel: String {
        if let name = AudioOutputDevices.defaultOutputDeviceName() {
            return "Current default (\(name))"
        }
        return "Current default"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Where should ClipFarm put your clips?"
        panel.directoryURL = preferences.saveFolder
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            preferences.saveFolder = url
            objectWillChange.send()
        } else if preferences.saveFolder == nil {
            folderEnabled = false
        }
    }

    func saveKey() {
        let candidate = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        guard candidate.hasPrefix(KeychainStore.keyPrefix) else {
            keyMessage = Message(text: "A CDN key starts with \(KeychainStore.keyPrefix)", isError: true)
            return
        }
        isCheckingKey = true
        keyMessage = nil
        Task {
            let result = await CDNUploader.verify(key: candidate)
            isCheckingKey = false
            switch result {
            case .success:
                KeychainStore.setAPIKey(candidate)
                keyInput = ""
                hasAPIKey = true
                maskedKey = KeychainStore.maskedKey
                keyMessage = Message(text: "Key saved to your keychain.", isError: false)
            case .failure(let error):
                keyMessage = Message(text: error.localizedDescription, isError: true)
            }
        }
    }

    func removeKey() {
        KeychainStore.setAPIKey(nil)
        hasAPIKey = false
        maskedKey = nil
        cdnEnabled = false
        keyMessage = Message(text: "Key removed.", isError: false)
    }
}
