import Foundation
import SwiftUI
import UIKit

// Synthetic-only iOS renderer gate. This file deliberately imports no network,
// SSH, tmux, credential, or Casein session APIs. The normal app never presents
// it; `--casein-terminal-probe` is required at process launch.

private enum CaseinTerminalProbeFixture {
    // Fixed, non-sensitive ANSI supplied to the renderer façade. It is never
    // copied into accessibility, logs, telemetry, crash metadata, or storage.
    static let ansi = "\u{001B}[1;36mCASEIN SYNTHETIC TERMINAL\u{001B}[0m\r\n" +
        "\u{001B}[32mrenderer: canvas\u{001B}[0m\r\n" +
        "lifecycle: create resize destroy recreate\r\n" +
        "privacy: fixture only"
}

@MainActor
private final class CaseinTerminalProbeModel: ObservableObject {
    @Published private(set) var generation = 1
    @Published private(set) var completedCycles = 0
    @Published private(set) var firstSurfaceMountMilliseconds: Double?
    @Published private(set) var surfaceVisible = true

    let rendererName: String
    let frame: CaseinTerminalFrame
    let baselineResidentBytes: UInt64

    private let started = ContinuousClock.now
    private let automaticCyclesRequested = ProcessInfo.processInfo.arguments.contains(
        "--casein-terminal-probe-auto-cycles"
    )

    init(renderer: some CaseinTerminalRenderer) {
        rendererName = renderer.rendererName
        frame = renderer.frame(
            for: Data(CaseinTerminalProbeFixture.ansi.utf8),
            columns: 48
        )
        baselineResidentBytes = Self.residentBytes()
    }

    private var presentedGenerations: Set<Int> = []

    func surfaceDidAppear(generation: Int) {
        guard presentedGenerations.insert(generation).inserted else { return }
        if firstSurfaceMountMilliseconds == nil {
            let duration = started.duration(to: .now)
            firstSurfaceMountMilliseconds = Double(duration.components.seconds) * 1_000 +
                Double(duration.components.attoseconds) / 1_000_000_000_000_000
        }
        if generation > 1 {
            completedCycles += 1
        }
        if automaticCyclesRequested, completedCycles < 10 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                self?.recreate()
            }
        }
    }

    func recreate() {
        surfaceVisible = false
        generation += 1
        DispatchQueue.main.async { [weak self] in
            self?.surfaceVisible = true
        }
    }

    var residentDeltaBytes: Int64 {
        Int64(Self.residentBytes()) - Int64(baselineResidentBytes)
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

private struct CaseinTerminalRendererProbeView: View {
    @StateObject private var model = CaseinTerminalProbeModel(renderer: CaseinCanvasTerminalRenderer())
    // Mob owns the UIKit scene lifecycle, so SwiftUI's scenePhase environment
    // is not authoritative here. Track UIKit activation notifications instead.
    @State private var applicationIsActive = UIApplication.shared.applicationState == .active

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.035, blue: 0.045).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text("Terminal renderer probe")
                    .font(.headline)
                Text("Synthetic fixture · no session · read only")
                    .font(.caption)
                if model.surfaceVisible {
                    CaseinTerminalCanvasSurface(
                        frame: model.frame,
                        surfaceGeneration: model.generation
                    )
                    .onAppear {
                        DispatchQueue.main.async { model.surfaceDidAppear(generation: model.generation) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.4)))
                }
                Text(metricsLabel)
                    .font(.caption.monospacedDigit())
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("casein.terminal.probe.metrics")
                    .accessibilityLabel("Renderer lifecycle metrics")
                    .accessibilityValue(metricsAccessibilityValue)
                Button("Recreate synthetic surface", action: model.recreate)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("casein.terminal.probe.recreate")
            }
            .padding(18)
            .foregroundStyle(.white)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("casein.terminal.probe.root")

            if !applicationIsActive {
                Color.black.ignoresSafeArea()
                    .accessibilityLabel("Terminal hidden while inactive")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            applicationIsActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            applicationIsActive = false
        }
    }

    private var metricsLabel: String {
        let first = model.firstSurfaceMountMilliseconds.map { String(format: "%.2f", $0) } ?? "pending"
        return "renderer=\(model.rendererName) generation=\(model.generation) cycles=\(model.completedCycles) surface_mount_ms=\(first) rss_delta=\(model.residentDeltaBytes)"
    }

    private var metricsAccessibilityValue: String {
        let first = model.firstSurfaceMountMilliseconds.map { String(format: "%.2f", $0) } ?? "pending"
        return "renderer \(model.rendererName), generation \(model.generation), cycles \(model.completedCycles), surface mount milliseconds \(first), resident delta bytes \(model.residentDeltaBytes)"
    }
}

/// UIKit-owned foreground-transition cover. It is installed before the probe
/// is presented and becomes opaque synchronously on will-resign-active. This
/// narrows snapshot exposure, but the probe does not claim that XCUITest can
/// inspect or prove the OS-owned app-switcher snapshot.
@MainActor
private final class CaseinTerminalProbeHostingController: UIHostingController<CaseinTerminalRendererProbeView> {
    private let privacyCover = UIView()

    init() {
        super.init(rootView: CaseinTerminalRendererProbeView())
        privacyCover.backgroundColor = .black
        privacyCover.isAccessibilityElement = true
        privacyCover.accessibilityLabel = "Terminal hidden while inactive"
        privacyCover.isHidden = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        privacyCover.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(privacyCover)
        NSLayoutConstraint.activate([
            privacyCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            privacyCover.topAnchor.constraint(equalTo: view.topAnchor),
            privacyCover.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func applicationWillResignActive() { privacyCover.isHidden = false }
    @objc private func applicationDidBecomeActive() { privacyCover.isHidden = true }

    deinit { NotificationCenter.default.removeObserver(self) }
}

@objc(CaseinTerminalProbeFactory)
public final class CaseinTerminalProbeFactory: NSObject {
    @objc public static func isEnabled() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--casein-terminal-probe")
    }

    @MainActor @objc public static func makeRootViewController() -> UIViewController {
        CaseinTerminalProbeHostingController()
    }

    /// Registration proves the same Casein-owned surface can cross Mob's
    /// native_view seam. Product screens intentionally do not emit it yet.
    @MainActor @objc public static func registerMobNativeView() {
        MobNativeViewRegistry.shared.register("CaseinMob_IosTerminalProbeComponent") { _, _ in
            AnyView(CaseinTerminalRendererProbeView())
        }
    }
}

@_cdecl("casein_register_terminal_probe")
@MainActor
public func casein_register_terminal_probe() {
    if CaseinTerminalProbeFactory.isEnabled() {
        CaseinTerminalProbeFactory.registerMobNativeView()
    }
}
