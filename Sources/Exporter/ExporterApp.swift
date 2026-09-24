import SwiftUI

/// Mała aplikacja w pasku menu, bez ikony w Docku (`LSUIElement`).
/// Pełny dostęp do dysku nadaje się aplikacji, nie Terminalowi — stąd nie
/// narzędzie wiersza poleceń.
@main
struct ExporterApp: App {
    @StateObject private var exporter = Exporter()

    var body: some Scene {
        MenuBarExtra {
            ExporterMenu(exporter: exporter)
        } label: {
            Image(nsImage: RegistrationMark.image(busy: exporter.isWorking))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Znak pasowania — ten sam, który siedzi w rogu ikony lightbrary (i w faviconie
/// 3210.lu): tarcza z dwiema zaczernionymi ćwiartkami, prawą górną i lewą dolną,
/// w pierścieniu. Rysowany jako obraz **szablonowy**, więc pasek menu sam
/// dobiera mu kolor w jasnym i ciemnym wyglądzie. Podczas eksportu zaczernione
/// ćwiartki zamieniają się miejscami.
enum RegistrationMark {
    private static let idle = draw(filled: [(0, 90), (180, 270)])
    private static let busy = draw(filled: [(90, 180), (270, 360)])

    static func image(busy: Bool) -> NSImage { busy ? Self.busy : idle }

    private static func draw(filled quadrants: [(CGFloat, CGFloat)]) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = rect.insetBy(dx: 1.5, dy: 1.5)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            // Tarcza mniejsza od okręgu: szczelina to pierścień z ikony aplikacji.
            let disk = ring.width / 2 - 2.2
            NSColor.black.set()

            // Kąty jak w AppKit: 0° w prawo, rosną przeciwnie do wskazówek zegara.
            for (start, end) in quadrants {
                let wedge = NSBezierPath()
                wedge.move(to: center)
                wedge.appendArc(withCenter: center, radius: disk,
                                startAngle: start, endAngle: end)
                wedge.close()
                wedge.fill()
            }
            let face = NSBezierPath(ovalIn: NSRect(x: center.x - disk, y: center.y - disk,
                                                   width: disk * 2, height: disk * 2))
            face.lineWidth = 0.8
            face.stroke()

            let outline = NSBezierPath(ovalIn: ring)
            outline.lineWidth = 1.2
            outline.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct ExporterMenu: View {
    @ObservedObject var exporter: Exporter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("lightbrary exporter")
                .font(.headline)

            if let last = exporter.lastExport {
                Text("Last export \(last.formatted(.relative(presentation: .named))) · \(exporter.lastCount) photos")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not exported yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if exporter.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(exporter.status ?? "Working…").font(.callout)
                }
            } else if let status = exporter.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if exporter.needsFullDiskAccess {
                Button("Open Full Disk Access settings…") { exporter.openFullDiskAccessSettings() }
                Text("Add the exporter with the **+** button, then quit and open it again — the permission only takes effect at startup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            LabeledContent("Shared folder", value: exporter.folderName ?? "not chosen")
                .font(.callout)
            HStack {
                Button(exporter.folderName == nil ? "Choose folder…" : "Change folder…") {
                    exporter.chooseFolder()
                }
                Spacer()
                Button("Export now") {
                    Task { await exporter.export() }
                }
                .disabled(exporter.isWorking || exporter.folderName == nil)
            }

            Toggle("Open at login", isOn: Binding(
                get: { exporter.opensAtLogin },
                set: { exporter.opensAtLogin = $0 }
            ))

            Divider()

            Text("Reads the Photos library databases and writes photo measures for the lightbrary apps. It never changes your library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }
}
