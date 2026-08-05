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

private struct CaseinTerminalProbeCell: Identifiable, Equatable {
    let id: Int
    let row: Int
    let column: Int
    let character: Character
    let color: Color
    let bold: Bool
}

private struct CaseinTerminalProbeFrame: Equatable {
    let cells: [CaseinTerminalProbeCell]
    let rows: Int
    let columns: Int
}

private protocol CaseinTerminalRendererFacade {
    var rendererName: String { get }
    func frame(forANSI bytes: String, columns: Int) -> CaseinTerminalProbeFrame
}

/// Minimal ANSI renderer used to prove the Mob/UIKit lifecycle seam before an
/// unversioned full GhosttyKit dependency is accepted. It understands only the
/// fixed fixture's reset, bold, and basic foreground SGR codes; unknown control
/// sequences are discarded rather than rendered.
private struct CaseinCanvasProbeRenderer: CaseinTerminalRendererFacade {
    let rendererName = "casein_canvas"

    func frame(forANSI bytes: String, columns: Int) -> CaseinTerminalProbeFrame {
        var cells: [CaseinTerminalProbeCell] = []
        var row = 0
        var column = 0
        var color = Color(red: 0.91, green: 0.94, blue: 0.96)
        var bold = false
        var index = bytes.startIndex

        while index < bytes.endIndex {
            if bytes[index] == "\u{001B}",
               let (parameters, next) = sgrSequence(in: bytes, at: index) {
                for parameter in parameters {
                    switch parameter {
                    case 0:
                        color = Color(red: 0.91, green: 0.94, blue: 0.96)
                        bold = false
                    case 1: bold = true
                    case 32: color = Color(red: 0.35, green: 0.86, blue: 0.55)
                    case 36: color = Color(red: 0.35, green: 0.80, blue: 0.95)
                    default: break
                    }
                }
                index = next
                continue
            }

            let character = bytes[index]
            if character == "\r" {
                column = 0
            } else if character == "\n" {
                row += 1
                column = 0
            } else if !character.isASCIIControl {
                cells.append(
                    CaseinTerminalProbeCell(
                        id: cells.count,
                        row: row,
                        column: column,
                        character: character,
                        color: color,
                        bold: bold
                    )
                )
                column += 1
                if column >= columns {
                    row += 1
                    column = 0
                }
            }
            index = bytes.index(after: index)
        }

        return CaseinTerminalProbeFrame(cells: cells, rows: max(row + 1, 1), columns: columns)
    }

    private func sgrSequence(
        in value: String,
        at escape: String.Index
    ) -> ([Int], String.Index)? {
        let open = value.index(after: escape)
        guard open < value.endIndex, value[open] == "[" else { return nil }
        var cursor = value.index(after: open)
        var digits = ""
        while cursor < value.endIndex, value[cursor] != "m" {
            let character = value[cursor]
            guard character.isNumber || character == ";" else { return nil }
            digits.append(character)
            cursor = value.index(after: cursor)
        }
        guard cursor < value.endIndex else { return nil }
        let parameters = digits.isEmpty ? [0] : digits.split(separator: ";").compactMap { Int($0) }
        return (parameters, value.index(after: cursor))
    }
}

private extension Character {
    var isASCIIControl: Bool {
        unicodeScalars.count == 1 && (unicodeScalars.first?.value ?? 32) < 32
    }
}

@MainActor
private final class CaseinTerminalProbeModel: ObservableObject {
    @Published private(set) var generation = 1
    @Published private(set) var completedCycles = 0
    @Published private(set) var firstFrameMilliseconds: Double?
    @Published private(set) var surfaceVisible = true

    let rendererName: String
    let frame: CaseinTerminalProbeFrame
    let baselineResidentBytes: UInt64

    private let started = ContinuousClock.now

    init(renderer: some CaseinTerminalRendererFacade) {
        rendererName = renderer.rendererName
        frame = renderer.frame(forANSI: CaseinTerminalProbeFixture.ansi, columns: 48)
        baselineResidentBytes = Self.residentBytes()
    }

    func markFirstFrame() {
        guard firstFrameMilliseconds == nil else { return }
        let duration = started.duration(to: .now)
        firstFrameMilliseconds = Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    func recreate() {
        surfaceVisible = false
        generation += 1
        DispatchQueue.main.async { [weak self] in
            self?.surfaceVisible = true
            self?.completedCycles += 1
        }
    }

    func runAutomaticCyclesIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--casein-terminal-probe-auto-cycles") else {
            return
        }
        for _ in 0..<10 {
            recreate()
            try? await Task.sleep(for: .milliseconds(80))
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

private struct CaseinTerminalProbeSurface: View {
    let frame: CaseinTerminalProbeFrame
    let generation: Int
    let onFirstFrame: () -> Void

    private let cellWidth: CGFloat = 8.4
    private let cellHeight: CGFloat = 17

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.04, green: 0.05, blue: 0.06)))
                for cell in frame.cells {
                    let text = Text(String(cell.character))
                        .font(.system(size: 13, weight: cell.bold ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(cell.color)
                    context.draw(
                        text,
                        at: CGPoint(
                            x: CGFloat(cell.column) * cellWidth,
                            y: CGFloat(cell.row) * cellHeight
                        ),
                        anchor: .topLeading
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .id(generation)
        .accessibilityHidden(true)
        .onAppear {
            DispatchQueue.main.async(execute: onFirstFrame)
        }
    }
}

private struct CaseinTerminalRendererProbeView: View {
    @StateObject private var model = CaseinTerminalProbeModel(renderer: CaseinCanvasProbeRenderer())
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
                    CaseinTerminalProbeSurface(
                        frame: model.frame,
                        generation: model.generation,
                        onFirstFrame: model.markFirstFrame
                    )
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
        .task { await model.runAutomaticCyclesIfRequested() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            applicationIsActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            applicationIsActive = false
        }
    }

    private var metricsLabel: String {
        let first = model.firstFrameMilliseconds.map { String(format: "%.2f", $0) } ?? "pending"
        return "renderer=\(model.rendererName) generation=\(model.generation) cycles=\(model.completedCycles) first_ms=\(first) rss_delta=\(model.residentDeltaBytes)"
    }

    private var metricsAccessibilityValue: String {
        let first = model.firstFrameMilliseconds.map { String(format: "%.2f", $0) } ?? "pending"
        return "renderer \(model.rendererName), generation \(model.generation), cycles \(model.completedCycles), first frame milliseconds \(first), resident delta bytes \(model.residentDeltaBytes)"
    }
}

@objc(CaseinTerminalProbeFactory)
public final class CaseinTerminalProbeFactory: NSObject {
    @objc public static func isEnabled() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--casein-terminal-probe")
    }

    @objc public static func makeRootViewController() -> UIViewController {
        UIHostingController(rootView: CaseinTerminalRendererProbeView())
    }

    /// Registration proves the same Casein-owned surface can cross Mob's
    /// native_view seam. Product screens intentionally do not emit it yet.
    @objc public static func registerMobNativeView() {
        MobNativeViewRegistry.shared.register("CaseinMob_IosTerminalProbeComponent") { _, _ in
            AnyView(CaseinTerminalRendererProbeView())
        }
    }
}

@_cdecl("casein_register_terminal_probe")
public func casein_register_terminal_probe() {
    CaseinTerminalProbeFactory.registerMobNativeView()
}
