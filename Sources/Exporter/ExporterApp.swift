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
            Image(systemName: exporter.isWorking
                  ? "arrow.triangle.2.circlepath"
                  : "square.and.arrow.up.on.square")
        }
        .menuBarExtraStyle(.window)
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
