import Foundation
import SwiftUI
import UIKit

/// Identity fence for one terminal byte stream. The transport owns these
/// opaque values; the renderer only compares them and never persists them.
public struct CaseinTerminalRenderGeneration: Equatable, Sendable {
    public let lifecycle: String
    public let connection: String
    public let stream: String

    public init(lifecycle: String, connection: String, stream: String) {
        self.lifecycle = lifecycle
        self.connection = connection
        self.stream = stream
    }
}

struct CaseinTerminalCell: Identifiable, Equatable {
    let id: Int
    let row: Int
    let column: Int
    let character: Character
    let color: Color
    let bold: Bool
}

struct CaseinTerminalFrame: Equatable {
    let cells: [CaseinTerminalCell]
    let rows: Int
    let columns: Int

    static func empty(columns: Int = 48) -> Self {
        Self(cells: [], rows: 1, columns: columns)
    }
}

protocol CaseinTerminalRenderer {
    var rendererName: String { get }
    func frame(for bytes: Data, columns: Int) -> CaseinTerminalFrame
}

/// Casein-owned bounded ANSI renderer. It intentionally implements only the
/// presentation subset accepted by the mobile terminal surface. Unknown
/// control sequences are discarded instead of being displayed as content.
struct CaseinCanvasTerminalRenderer: CaseinTerminalRenderer {
    let rendererName = "casein_canvas"

    func frame(for bytes: Data, columns: Int) -> CaseinTerminalFrame {
        let boundedColumns = max(columns, 1)
        let glyphs = CaseinTerminalANSIParser().glyphs(for: bytes, columns: boundedColumns)
        let cells = glyphs.enumerated().map { id, glyph in
            CaseinTerminalCell(
                id: id,
                row: glyph.row,
                column: glyph.column,
                character: glyph.character,
                color: color(for: glyph.foreground),
                bold: glyph.bold
            )
        }
        let rows = (glyphs.last?.row ?? 0) + 1

        return CaseinTerminalFrame(
            cells: cells,
            rows: max(rows, 1),
            columns: boundedColumns
        )
    }

    private func color(for foreground: CaseinTerminalForeground) -> Color {
        switch foreground {
        case .standard:
            Color(red: 0.91, green: 0.94, blue: 0.96)
        case .green:
            Color(red: 0.35, green: 0.86, blue: 0.55)
        case .cyan:
            Color(red: 0.35, green: 0.80, blue: 0.95)
        }
    }
}

@MainActor
final class CaseinTerminalRenderState: ObservableObject {
    @Published private(set) var frame = CaseinTerminalFrame.empty()
    @Published private(set) var surfaceGeneration = 0
    @Published private(set) var baselineAccepted = false

    private(set) var generation: CaseinTerminalRenderGeneration?
    private let renderer: any CaseinTerminalRenderer

    init(renderer: any CaseinTerminalRenderer = CaseinCanvasTerminalRenderer()) {
        self.renderer = renderer
    }

    /// Starts a new identity generation. Old pixels are synchronously removed
    /// before the caller can request or receive its baseline.
    func begin(_ generation: CaseinTerminalRenderGeneration) {
        self.generation = generation
        baselineAccepted = false
        frame = .empty(columns: frame.columns)
        surfaceGeneration += 1
    }

    /// Accepts only the baseline for the currently active identity generation.
    /// Live output integration is deliberately outside this renderer-only lane.
    @discardableResult
    func acceptBaseline(
        _ bytes: Data,
        generation: CaseinTerminalRenderGeneration,
        columns: Int
    ) -> Bool {
        guard self.generation == generation else { return false }
        frame = renderer.frame(for: bytes, columns: columns)
        baselineAccepted = true
        surfaceGeneration += 1
        return true
    }
}

struct CaseinTerminalCanvasSurface: View {
    let frame: CaseinTerminalFrame
    let surfaceGeneration: Int

    private let cellWidth: CGFloat = 8.4
    private let cellHeight: CGFloat = 17

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(red: 0.04, green: 0.05, blue: 0.06))
                )
                for cell in frame.cells {
                    let text = Text(String(cell.character))
                        .font(.system(
                            size: 13,
                            weight: cell.bold ? .bold : .regular,
                            design: .monospaced
                        ))
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
        .id(surfaceGeneration)
        // Terminal bytes are pixels only. They never enter VoiceOver, labels,
        // values, diagnostics, telemetry, or persistence through this surface.
        .accessibilityHidden(true)
    }
}

private struct CaseinTerminalProductView: View {
    @ObservedObject var state: CaseinTerminalRenderState

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.035, blue: 0.045).ignoresSafeArea()
            CaseinTerminalCanvasSurface(
                frame: state.frame,
                surfaceGeneration: state.surfaceGeneration
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("casein.terminal.product.root")
    }
}

private enum CaseinTerminalComponentUpdate: Equatable {
    case frame(CaseinTerminalComponentPayload)
    case consumed
    case covered
    case invalid
}

private struct CaseinTerminalComponentPayload: Equatable {
    let generation: Int
    let revision: Int
    let frame: CaseinTerminalFrame

    static func decode(_ props: [String: Any]) -> CaseinTerminalComponentUpdate {
        let maximumFrameBytes = 65_536
        let maximumEncodedBytes = 87_384

        guard let deliveryState = props["delivery_state"] as? String else { return .invalid }
        if deliveryState == "consumed" { return .consumed }
        if deliveryState == "covered" { return .covered }
        guard deliveryState == "frame" else { return .invalid }

        guard let encoded = props["encoded_frame"] as? String,
              let declaredBytes = (props["frame_bytes"] as? NSNumber)?.intValue,
              let generation = (props["baseline_generation"] as? NSNumber)?.intValue,
              let revision = (props["revision"] as? NSNumber)?.intValue,
              let baselineReady = (props["baseline_ready"] as? NSNumber)?.boolValue,
              let columns = (props["columns"] as? NSNumber)?.intValue,
              baselineReady,
              generation > 0,
              revision >= 0,
              declaredBytes >= 0,
              declaredBytes <= maximumFrameBytes,
              columns > 0,
              columns <= 400,
              encoded.utf8.count <= maximumEncodedBytes,
              encoded.utf8.count % 4 == 0,
              encoded.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (65...90).contains(value)
                      || (97...122).contains(value)
                      || (48...57).contains(value)
                      || value == 43 || value == 47 || value == 61
              }) else { return .invalid }

        let padding = encoded.hasSuffix("==") ? 2 : (encoded.hasSuffix("=") ? 1 : 0)
        let decodedUpperBound = (encoded.utf8.count / 4) * 3 - padding
        guard decodedUpperBound == declaredBytes,
              decodedUpperBound <= maximumFrameBytes,
              let bytes = Data(base64Encoded: encoded, options: []),
              bytes.count == declaredBytes else { return .invalid }

        let frame = CaseinCanvasTerminalRenderer().frame(for: bytes, columns: columns)
        return .frame(Self(generation: generation, revision: revision, frame: frame))
    }
}

@MainActor
private final class CaseinTerminalComponentState: ObservableObject {
    @Published private(set) var frame = CaseinTerminalFrame.empty()
    @Published private(set) var covered = true
    @Published private(set) var surfaceGeneration = 0

    private var generation: Int?
    private var revision = -1
    private var requiresGenerationAfter = -1

    @discardableResult
    func apply(_ update: CaseinTerminalComponentUpdate) -> Bool {
        switch update {
        case .consumed:
            return false
        case .covered, .invalid:
            requireFreshGeneration()
            return false
        case let .frame(payload):
            return applyFrame(payload)
        }
    }

    private func applyFrame(_ payload: CaseinTerminalComponentPayload) -> Bool {
        guard payload.generation > requiresGenerationAfter else {
            requireFreshGeneration()
            return false
        }

        if let generation, payload.generation < generation {
            requireFreshGeneration()
            return false
        }

        if generation != payload.generation {
            generation = payload.generation
            revision = -1
            frame = .empty(columns: payload.frame.columns)
        }

        guard payload.revision >= revision else {
            requireFreshGeneration()
            return false
        }

        revision = payload.revision
        frame = payload.frame
        surfaceGeneration += 1
        covered = UIApplication.shared.applicationState != .active
        return true
    }

    func applicationWillResignActive() { requireFreshGeneration() }
    func applicationDidBecomeActive() { requireFreshGeneration() }

    private func requireFreshGeneration() {
        if let generation { requiresGenerationAfter = max(requiresGenerationAfter, generation) }
        frame = .empty(columns: frame.columns)
        surfaceGeneration += 1
        covered = true
    }
}

private struct CaseinTerminalProductComponentView: View {
    let update: CaseinTerminalComponentUpdate
    let consumed: (Int, Int) -> Void

    @StateObject private var state = CaseinTerminalComponentState()

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.035, blue: 0.045)
            CaseinTerminalCanvasSurface(
                frame: state.frame,
                surfaceGeneration: state.surfaceGeneration
            )

            if state.covered {
                Color.black
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Terminal waiting for a fresh baseline")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("casein.terminal.product.root")
        .onAppear { apply(update) }
        .onChange(of: update) { _, value in apply(value) }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )) { _ in state.applicationWillResignActive() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in state.applicationDidBecomeActive() }
    }

    private func apply(_ update: CaseinTerminalComponentUpdate) {
        let accepted = state.apply(update)
        if accepted, case let .frame(payload) = update {
            consumed(payload.generation, payload.revision)
        }
    }
}

@MainActor
@_cdecl("casein_register_terminal_product")
public func casein_register_terminal_product() {
    MobNativeViewRegistry.shared.register("CaseinMob_IOSTerminalComponent") { props, send in
        // Decode and render immediately. The returned SwiftUI value retains
        // cells and identity metadata, never the encoded terminal prop.
        let update = CaseinTerminalComponentPayload.decode(props)
        return AnyView(CaseinTerminalProductComponentView(
            update: update,
            consumed: { generation, revision in
                send("terminal_consumed", [
                    "generation": generation,
                    "revision": revision
                ])
            }
        ))
    }
}

/// UIKit owns the privacy boundary so it changes synchronously with app
/// lifecycle notifications. Foregrounding never uncovers old terminal pixels:
/// a matching fresh baseline must be accepted first.
@MainActor
@objc(CaseinTerminalHostingController)
public final class CaseinTerminalHostingController: UIViewController {
    private let state = CaseinTerminalRenderState()
    private let privacyCover = UIView()
    private var host: UIHostingController<CaseinTerminalProductView>!
    private var generationReadyForBaseline = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        host = UIHostingController(rootView: CaseinTerminalProductView(state: state))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        host.didMove(toParent: self)

        privacyCover.backgroundColor = .black
        privacyCover.translatesAutoresizingMaskIntoConstraints = false
        privacyCover.isAccessibilityElement = true
        privacyCover.accessibilityLabel = "Terminal waiting for a fresh baseline"
        view.addSubview(privacyCover)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            privacyCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            privacyCover.topAnchor.constraint(equalTo: view.topAnchor),
            privacyCover.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

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
        showPrivacyCover()
    }

    /// Called before starting or replacing a byte-plane connection.
    @objc public func beginGeneration(
        lifecycle: String,
        connection: String,
        stream: String
    ) {
        showPrivacyCover()
        generationReadyForBaseline = true
        state.begin(.init(lifecycle: lifecycle, connection: connection, stream: stream))
    }

    /// Returns false without changing pixels or cover state for stale identity.
    @discardableResult
    @objc public func acceptFreshBaseline(
        _ bytes: Data,
        lifecycle: String,
        connection: String,
        stream: String,
        columns: Int
    ) -> Bool {
        guard generationReadyForBaseline else { return false }
        let accepted = state.acceptBaseline(
            bytes,
            generation: .init(lifecycle: lifecycle, connection: connection, stream: stream),
            columns: columns
        )
        guard accepted else { return false }
        // A baseline is one-shot even if it arrives while inactive. In that
        // case the cover stays up and a newly begun generation is required.
        generationReadyForBaseline = false
        guard UIApplication.shared.applicationState == .active else { return true }
        hidePrivacyCover()
        return true
    }

    @objc private func applicationWillResignActive() {
        generationReadyForBaseline = false
        showPrivacyCover()
    }

    @objc private func applicationDidBecomeActive() {
        // Stay covered. The transport must begin a new connection generation
        // and deliver its authoritative baseline before pixels are revealed.
        showPrivacyCover()
    }

    private func showPrivacyCover() {
        privacyCover.isHidden = false
        view.bringSubviewToFront(privacyCover)
    }

    private func hidePrivacyCover() { privacyCover.isHidden = true }

    deinit { NotificationCenter.default.removeObserver(self) }
}
