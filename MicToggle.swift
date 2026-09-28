import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import ServiceManagement

// A menu bar utility. It never records audio: it only reads and changes the
// controls of the input device selected in macOS Sound settings.

private struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let initial = Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey), label: "⌘F5")

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var prefix = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); prefix += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); prefix += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); prefix += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); prefix += "⌘" }
        // A bare key or Shift+key would interfere with normal typing.
        guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { return nil }

        let key: String
        switch Int(event.keyCode) {
        case kVK_F1: key = "F1"
        case kVK_F2: key = "F2"
        case kVK_F3: key = "F3"
        case kVK_F4: key = "F4"
        case kVK_F5: key = "F5"
        case kVK_F6: key = "F6"
        case kVK_F7: key = "F7"
        case kVK_F8: key = "F8"
        case kVK_F9: key = "F9"
        case kVK_F10: key = "F10"
        case kVK_F11: key = "F11"
        case kVK_F12: key = "F12"
        case kVK_Space: key = "Espace"
        default:
            guard let text = event.charactersIgnoringModifiers?.uppercased(),
                  text.count == 1, text.unicodeScalars.first?.value ?? 0 >= 32 else { return nil }
            key = text
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, label: prefix + key)
    }
}

private final class HotkeyManager {
    var onPress: (() -> Void)?
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            manager.onPress?()
            return noErr
        }, 1, &eventType, context, &handler)
    }

    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ shortcut: Shortcut) -> OSStatus {
        if let hotkey {
            UnregisterEventHotKey(hotkey)
            self.hotkey = nil
        }
        let identifier = EventHotKeyID(signature: 0x4D54474C, id: 1) // MTGL
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                   GetApplicationEventTarget(), 0, &hotkey)
    }
}

private enum InputError: LocalizedError {
    case noDevice
    case queryFailed(OSStatus)
    case unsupported
    case cannotUnmute
    case changeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "Aucun microphone d’entrée n’est sélectionné dans macOS."
        case .queryFailed(let code): return "Impossible de lire la source d’entrée (Core Audio : \(code))."
        case .unsupported: return "Ce microphone ne propose ni réglage de volume d’entrée ni commande mute modifiable."
        case .cannotUnmute: return "Le microphone est coupé par une commande mute que cette app ne peut pas modifier."
        case .changeFailed(let code): return "Le microphone a refusé la modification (Core Audio : \(code))."
        }
    }
}

private struct InputState: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let volumes: [UInt32: Float32]
    let hasMuteControl: Bool
    let hardwareMuted: Bool
    let canChange: Bool

    var isMuted: Bool {
        hardwareMuted || (!volumes.isEmpty && volumes.values.allSatisfy { $0 <= 0.001 })
    }

    var inputLevelText: String? {
        let percentages = volumes.values.filter { $0.isFinite }
            .map { Int((max(0, min($0, 1)) * 100).rounded()) }.sorted()
        guard let minimum = percentages.first, let maximum = percentages.last else { return nil }
        return minimum == maximum ? "\(minimum) %" : "\(minimum)–\(maximum) %"
    }
}

private final class InputController {
    private let savedKey = "savedInputVolumes"

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeInput,
                         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func propertyIsWritable(_ device: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        guard AudioObjectHasProperty(device, &property) else { return false }
        var writable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &property, &writable) == noErr && writable.boolValue
    }

    private func readFloat(_ device: AudioObjectID, _ property: AudioObjectPropertyAddress) -> Float32? {
        var property = property
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func readUInt(_ device: AudioObjectID, _ property: AudioObjectPropertyAddress) -> UInt32? {
        var property = property
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func readString(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func writeFloat(_ device: AudioObjectID, _ value: Float32,
                            _ property: AudioObjectPropertyAddress) -> OSStatus {
        var property = property
        var value = value
        return AudioObjectSetPropertyData(device, &property, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value)
    }

    private func writeUInt(_ device: AudioObjectID, _ value: UInt32,
                           _ property: AudioObjectPropertyAddress) -> OSStatus {
        var property = property
        var value = value
        return AudioObjectSetPropertyData(device, &property, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func state() throws -> InputState {
        var defaultAddress = address(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
        var device: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                 &defaultAddress, 0, nil, &size, &device)
        guard result == noErr else { throw InputError.queryFailed(result) }
        guard device != kAudioObjectUnknown else { throw InputError.noDevice }
        let name = readString(device, kAudioObjectPropertyName) ?? "Microphone inconnu"
        let uid = readString(device, kAudioDevicePropertyDeviceUID) ?? "device-\(device)"
        let master = address(kAudioDevicePropertyVolumeScalar)
        var volumes: [UInt32: Float32] = [:]
        if propertyIsWritable(device, master), let value = readFloat(device, master) {
            volumes[kAudioObjectPropertyElementMain] = value
        } else {
            // Some devices expose each input channel separately rather than a main control.
            for channel: UInt32 in 1...32 {
                let property = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, channel)
                if propertyIsWritable(device, property), let value = readFloat(device, property) {
                    volumes[channel] = value
                }
            }
        }
        let mute = address(kAudioDevicePropertyMute)
        let hasMute = propertyIsWritable(device, mute)
        let muted = readUInt(device, mute) == 1
        return InputState(id: device, uid: uid, name: name, volumes: volumes,
                          hasMuteControl: hasMute, hardwareMuted: muted,
                          canChange: !volumes.isEmpty || hasMute)
    }

    func toggle() throws {
        let current = try state()
        guard current.canChange else { throw InputError.unsupported }
        let mute = address(kAudioDevicePropertyMute)

        if current.isMuted {
            if current.hardwareMuted && !current.hasMuteControl { throw InputError.cannotUnmute }
            if current.hardwareMuted && current.hasMuteControl {
                let status = writeUInt(current.id, 0, mute)
                guard status == noErr else { throw InputError.changeFailed(status) }
            }
            if !current.volumes.isEmpty && current.volumes.values.allSatisfy({ $0 <= 0.001 }) {
                let saved = (UserDefaults.standard.dictionary(forKey: savedKey)?[current.uid] as? [String: Double]) ?? [:]
                for element in current.volumes.keys.sorted() {
                    let restored = Float32(saved[String(element)] ?? 0.75)
                    let value = max(0, min(restored, 1))
                    let status = writeFloat(current.id, value,
                                            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element))
                    guard status == noErr else { throw InputError.changeFailed(status) }
                }
            }
        } else {
            if !current.volumes.isEmpty {
                var allSaved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
                allSaved[current.uid] = Dictionary(uniqueKeysWithValues:
                    current.volumes.map { (String($0.key), Double($0.value)) })
                UserDefaults.standard.set(allSaved, forKey: savedKey)
                var failure: OSStatus = noErr
                for element in current.volumes.keys.sorted() {
                    let status = writeFloat(current.id, 0,
                                            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element))
                    if status != noErr { failure = status }
                }
                if failure != noErr {
                    if current.hasMuteControl && writeUInt(current.id, 1, mute) == noErr { return }
                    throw InputError.changeFailed(failure)
                }
            } else if current.hasMuteControl {
                let status = writeUInt(current.id, 1, mute)
                guard status == noErr else { throw InputError.changeFailed(status) }
            }
        }
    }
}

private final class ShortcutRecorderView: NSView {
    var onShortcut: ((Shortcut) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?(); return }
        guard let shortcut = Shortcut(event: event) else { NSSound.beep(); return }
        onShortcut?(shortcut)
    }
}

private final class MicrophoneHUD {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var generation = 0

    func show(isMuted: Bool, inputLevel: String?) {
        dismissTimer?.invalidate()
        generation += 1
        let currentGeneration = generation
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 138),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
            self.panel = panel
        }

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 180, height: 138))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 70, y: 79, width: 40, height: 40))
        icon.image = NSImage(systemSymbolName: isMuted ? "mic.slash.fill" : "mic.fill",
                             accessibilityDescription: isMuted ? "Micro coupé" : "Micro actif")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = isMuted ? .systemRed : .systemGreen
        background.addSubview(icon)

        let label = NSTextField(labelWithString: isMuted ? "OFF" : "ON")
        label.font = .systemFont(ofSize: 25, weight: .bold)
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 42, width: 160, height: 31)
        background.addSubview(label)
        let level = NSTextField(labelWithString: inputLevel.map { "Niveau : \($0)" } ?? "Niveau non disponible")
        level.font = .systemFont(ofSize: 13, weight: .medium)
        level.textColor = .secondaryLabelColor
        level.alignment = .center
        level.frame = NSRect(x: 10, y: 17, width: 160, height: 20)
        background.addSubview(level)
        panel.contentView = background

        // Put the feedback on the screen under the pointer, including multi-monitor setups.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - 90, y: visible.minY + 75))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            guard let self, self.generation == currentGeneration else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard self?.generation == currentGeneration else { return }
                panel.orderOut(nil)
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = InputController()
    private let hotkey = HotkeyManager()
    private let hud = MicrophoneHUD()
    private var toggleGeneration = 0
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var recorderWindow: NSPanel?
    private var shortcut: Shortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: "shortcut"),
                  let decoded = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .initial }
            return decoded
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }
    private var hotkeyError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        hotkey.onPress = { [weak self] in self?.toggle() }
        let code = hotkey.register(shortcut)
        if code != noErr { hotkeyError = "\(shortcut.label) est déjà utilisé par macOS ou une autre app (code \(code))." }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else { toggle() }
    }

    private func statusDot(color: NSColor, description: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { bounds in
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            color.setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
        image.isTemplate = false // Keep red/green in the macOS menu bar.
        image.accessibilityDescription = description
        return image
    }

    private func refresh() {
        let state = try? controller.state()
        let name = state?.name ?? "Aucune source"
        let status = state == nil ? "Indisponible" :
            (state!.canChange ? (state!.isMuted ? "Muet" : "Actif") : "Non réglable")
        let color: NSColor = state?.canChange == true
            ? (state!.isMuted ? .systemRed : .systemGreen)
            : .systemGray
        statusItem.button?.image = statusDot(color: color, description: "Micro \(status)")
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "\(name) — \(status). Clic gauche : basculer. Clic droit : options."
    }

    private func toggle() {
        do {
            let initial = try controller.state()
            let expectedMuted = !initial.isMuted
            try controller.toggle()
            toggleGeneration += 1
            confirmToggle(expectedMuted: expectedMuted, deviceID: initial.id, generation: toggleGeneration)
        }
        catch { showError(error.localizedDescription) }
    }

    private func confirmToggle(expectedMuted: Bool, deviceID: AudioObjectID,
                               generation: Int, attempt: Int = 0) {
        // Core Audio may apply a property asynchronously. Show ON/OFF only after
        // reading the requested state back from the device.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.toggleGeneration == generation else { return }
            do {
                let state = try self.controller.state()
                self.refresh()
                guard state.id == deviceID else { return }
                if state.isMuted == expectedMuted {
                    self.hud.show(isMuted: state.isMuted, inputLevel: state.inputLevelText)
                } else if attempt < 11 {
                    self.confirmToggle(expectedMuted: expectedMuted, deviceID: deviceID,
                                       generation: generation, attempt: attempt + 1)
                } else {
                    self.showError("Le microphone n’a pas confirmé le changement d’état.")
                }
            } catch { self.showError(error.localizedDescription) }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let state = try? controller.state()
        let source = NSMenuItem(title: "Source : \(state?.name ?? "aucune")", action: nil, keyEquivalent: "")
        source.isEnabled = false
        menu.addItem(source)
        let stateLabel = state == nil ? "Indisponible" :
            (state!.canChange ? (state!.isMuted ? "Muet" : "Actif") : "Non réglable")
        let stateItem = NSMenuItem(title: "État : \(stateLabel)", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        let levelItem = NSMenuItem(title: "Niveau d’entrée : \(state?.inputLevelText ?? "non disponible")",
                                   action: nil, keyEquivalent: "")
        levelItem.isEnabled = false
        menu.addItem(levelItem)
        let action = NSMenuItem(title: state?.isMuted == true ? "Réactiver le micro" : "Couper le micro",
                                action: #selector(toggleFromMenu), keyEquivalent: "")
        action.target = self
        action.isEnabled = state?.canChange == true
        menu.addItem(action)
        menu.addItem(.separator())
        let shortcutItem = NSMenuItem(title: "Raccourci : \(shortcut.label)…", action: #selector(changeShortcut), keyEquivalent: "")
        shortcutItem.target = self
        menu.addItem(shortcutItem)
        if let hotkeyError {
            let warning = NSMenuItem(title: "⚠ \(hotkeyError)", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        let login = NSMenuItem(title: "Ouvrir à la connexion", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter MicToggle", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError("Démarrage à la connexion : \(error.localizedDescription)") }
    }

    @objc private func changeShortcut() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 155),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Raccourci du micro"
        panel.level = .floating
        let label = NSTextField(labelWithString: "Appuie sur le nouveau raccourci (avec ⌘, ⌃ ou ⌥).")
        label.frame = NSRect(x: 20, y: 95, width: 350, height: 32)
        let hint = NSTextField(labelWithString: "Échap pour annuler. Les touches F peuvent nécessiter Fn.")
        hint.frame = NSRect(x: 20, y: 55, width: 350, height: 25)
        hint.textColor = .secondaryLabelColor
        let recorder = ShortcutRecorderView(frame: panel.contentView!.bounds)
        recorder.addSubview(label)
        recorder.addSubview(hint)
        recorder.onCancel = { [weak panel] in panel?.close() }
        recorder.onShortcut = { [weak self, weak panel] candidate in
            guard let self else { return }
            let old = self.shortcut
            let result = self.hotkey.register(candidate)
            if result == noErr {
                self.shortcut = candidate
                self.hotkeyError = nil
                panel?.close()
            } else {
                _ = self.hotkey.register(old)
                NSSound.beep()
                hint.stringValue = "\(candidate.label) indisponible (code \(result)). Essaie une autre combinaison."
            }
        }
        panel.contentView = recorder
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(recorder)
        NSApp.activate(ignoringOtherApps: true)
        recorderWindow = panel
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MicToggle"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

if CommandLine.arguments.contains("--status") {
    do {
        let input = try InputController().state()
        print("Source : \(input.name)")
        print("Identifiant : \(input.uid)")
        print("Volume : \(input.volumes.isEmpty ? "non réglable" : input.volumes.keys.sorted().map { "canal \($0) = \(Int((input.volumes[$0] ?? 0) * 100)) %" }.joined(separator: ", "))")
        print("Commande mute : \(input.hasMuteControl ? "disponible" : "indisponible")")
        print("État : \(input.canChange ? (input.isMuted ? "muet" : "actif") : "non réglable")")
        exit(0)
    } catch {
        fputs("MicToggle : \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
