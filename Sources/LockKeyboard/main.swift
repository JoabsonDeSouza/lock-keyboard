import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI

@main
struct LockKeyboardApp: App {
    @StateObject private var controller = LockController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(nsImage: controller.menuBarIcon)
                .accessibilityLabel(controller.isLocked ? "Teclado bloqueado" : "Teclado desbloqueado")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class LockController: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var isHolding = false
    @Published private(set) var holdProgress = 0.0
    @Published private(set) var secondsRemaining = 0
    @Published var message: String?
    @Published var autoUnlockEnabled = UserDefaults.standard.object(forKey: "autoUnlockEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoUnlockEnabled, forKey: "autoUnlockEnabled")
            configureSafetyTimer()
        }
    }
    @Published var autoUnlockSeconds = UserDefaults.standard.object(forKey: "autoUnlockSeconds") as? Int ?? 60 {
        didSet {
            if ![30, 60, 120, 300, 600].contains(autoUnlockSeconds) { autoUnlockSeconds = 60 }
            UserDefaults.standard.set(autoUnlockSeconds, forKey: "autoUnlockSeconds")
            configureSafetyTimer()
        }
    }

    var autoUnlockDurationLabel: String {
        switch autoUnlockSeconds {
        case 30: "30 segundos"
        case 60: "1 minuto"
        case 120: "2 minutos"
        case 300: "5 minutos"
        case 600: "10 minutos"
        default: "1 minuto"
        }
    }

    var menuBarIcon: NSImage {
        let state = isLocked ? "locked" : "unlocked"
        if let url = Bundle.main.url(forResource: "LockKeyboard-menubar-\(state)@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 16, height: 16)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Teclado") ?? NSImage()
    }

    private let blocker = KeyboardEventBlocker()
    private var holdTimer: Timer?
    private var safetyTimer: Timer?
    private var lockedAt: Date?
    private let holdDuration: TimeInterval = 3
    private var hud: LockHUDPanel?
    private var hudSubscription: AnyCancellable?

    init() {
        DispatchQueue.main.async { [weak self] in self?.configureHUD() }
    }

    func lockKeyboard() {
        guard !isLocked else { return }
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            message = "Ative Acessibilidade nos Ajustes do Sistema e tente novamente."
            return
        }

        guard blocker.start(onMouseDown: { [weak self] in
            Task { @MainActor in self?.beginHold() }
        }, onMouseUp: { [weak self] in
            Task { @MainActor in self?.endHold() }
        }) else {
            message = "Não foi possível iniciar o bloqueio. Verifique a permissão de Acessibilidade."
            return
        }

        isLocked = true
        isHolding = false
        holdProgress = 0
        configureSafetyTimer()
        message = nil
    }

    func unlockKeyboard() {
        guard isLocked else { return }
        blocker.stop()
        safetyTimer?.invalidate()
        safetyTimer = nil
        holdTimer?.invalidate()
        holdTimer = nil
        isLocked = false
        isHolding = false
        holdProgress = 0
        lockedAt = nil
        secondsRemaining = 0
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func beginHold() {
        guard isLocked, !isHolding else { return }
        isHolding = true
        holdProgress = 0
        let started = Date()
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.isLocked, self.isHolding else { timer.invalidate(); return }
                let progress = min(1, Date().timeIntervalSince(started) / self.holdDuration)
                self.holdProgress = progress
                if progress >= 1 {
                    timer.invalidate()
                    self.unlockKeyboard()
                }
            }
        }
    }

    private func endHold() {
        guard isHolding else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        isHolding = false
        holdProgress = 0
    }

    private func updateSafetyTimer() {
        guard autoUnlockEnabled, let lockedAt else { return }
        secondsRemaining = max(0, Int(TimeInterval(autoUnlockSeconds) - Date().timeIntervalSince(lockedAt)))
        if secondsRemaining == 0 { unlockKeyboard() }
    }

    private func configureSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        guard isLocked, autoUnlockEnabled else {
            lockedAt = nil
            secondsRemaining = 0
            return
        }

        lockedAt = Date()
        secondsRemaining = autoUnlockSeconds
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSafetyTimer() }
        }
    }

    private func configureHUD() {
        let panel = LockHUDPanel()
        hud = panel
        hudSubscription = Publishers.CombineLatest4($isLocked, $isHolding, $holdProgress, $secondsRemaining)
            .combineLatest($autoUnlockEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak panel] state, autoUnlockEnabled in
                panel?.update(locked: state.0, holding: state.1, progress: state.2, remaining: state.3, autoUnlockEnabled: autoUnlockEnabled)
            }
    }
}

@MainActor
private final class LockHUDPanel {
    private let panel: NSPanel
    private let hostingView: NSHostingView<LockHUDView>

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        hostingView = NSHostingView(rootView: LockHUDView(holding: false, progress: 0, remaining: 60, autoUnlockEnabled: true))
        panel.contentView = hostingView
    }

    func update(locked: Bool, holding: Bool, progress: Double, remaining: Int, autoUnlockEnabled: Bool) {
        guard locked else { panel.orderOut(nil); return }
        hostingView.rootView = LockHUDView(holding: holding, progress: progress, remaining: remaining, autoUnlockEnabled: autoUnlockEnabled)
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.maxY - frame.height - 22))
        }
        panel.orderFrontRegardless()
    }
}

private struct LockHUDView: View {
    let holding: Bool
    let progress: Double
    let remaining: Int
    let autoUnlockEnabled: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 4)
                Circle().trim(from: 0, to: holding ? progress : 1)
                    .stroke(holding ? Color.accentColor : Color.primary.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: holding ? "hand.tap" : "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(holding ? "Continue segurando…" : "Teclado bloqueado")
                    .font(.system(.headline, design: .rounded))
                Text(holding ? "\(max(0, Int((1 - progress) * 3 + 0.99)))s para liberar" : autoUnlockEnabled ? "Segure o clique por 3s · auto liberação em \(remaining)s" : "Segure o clique do trackpad por 3s para liberar")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 340, height: 82)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

private final class KeyboardEventBlocker {
    private let stateLock = NSLock()
    private var blocking = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseDownHandler: (() -> Void)?
    private var mouseUpHandler: (() -> Void)?

    func start(onMouseDown: @escaping () -> Void, onMouseUp: @escaping () -> Void) -> Bool {
        guard eventTap == nil else { return true }
        mouseDownHandler = onMouseDown
        mouseUpHandler = onMouseUp

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.callback,
            userInfo: opaqueSelf
        ) else { return false }

        eventTap = tap
        stateLock.lock(); blocking = true; stateLock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        stateLock.lock(); blocking = false; stateLock.unlock()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        mouseDownHandler = nil
        mouseUpHandler = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let blocker = Unmanaged<KeyboardEventBlocker>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = blocker.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            DispatchQueue.main.async { blocker.mouseDownHandler?() }
        case .leftMouseUp:
            DispatchQueue.main.async { blocker.mouseUpHandler?() }
        case .keyDown, .keyUp, .flagsChanged:
            blocker.stateLock.lock()
            let shouldBlock = blocker.blocking
            blocker.stateLock.unlock()
            if shouldBlock { return nil }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: LockController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(controller.isLocked ? "Teclado bloqueado" : "Pronto para limpar", systemImage: controller.isLocked ? "lock.fill" : "keyboard")
                .font(.headline)

            if controller.isLocked {
                Text(controller.autoUnlockEnabled
                    ? "Segure o clique do trackpad por 3 segundos para liberar. Desbloqueia automaticamente em \(controller.secondsRemaining)s."
                    : "Segure o clique do trackpad por 3 segundos para liberar. Desbloqueio automático desativado.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Desbloquear agora", action: controller.unlockKeyboard)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Bloquear teclado", action: controller.lockKeyboard)
                    .keyboardShortcut(.defaultAction)
                Text("Segure o clique físico do trackpad por 3 segundos para desbloquear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Toggle("Desbloqueio automático", isOn: $controller.autoUnlockEnabled)
            Picker("Tempo", selection: $controller.autoUnlockSeconds) {
                Text("30 segundos").tag(30)
                Text("1 minuto").tag(60)
                Text("2 minutos").tag(120)
                Text("5 minutos").tag(300)
                Text("10 minutos").tag(600)
            }
            .disabled(!controller.autoUnlockEnabled)

            if let message = controller.message {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Abrir Ajustes de Acessibilidade", action: controller.openAccessibilitySettings)
            }

            Divider()
            Text("Nenhuma tecla é registrada ou armazenada.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }
}
