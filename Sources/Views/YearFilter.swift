import SwiftUI

/// Wybór zakresu lat w osobnym okienku.
///
/// Pierwsza wersja miała `Picker` zagnieżdżony w `Menu` — i zwijała się przy
/// każdym kliknięciu. Wybór zapisuje do `@Published`, widok się przebudowuje,
/// a menu znika razem z nim. Popover ma własny cykl życia i przeżywa zmianę
/// stanu, więc można ustawić oba krańce bez otwierania go od nowa.
///
/// Na telefonie to samo zagnieżdżenie wróciło piętro wyżej: popover otwierany
/// **z wnętrza menu** mrugał i nie pokazywał się wcale, bo dotknięcie zamyka
/// menu, a razem z nim znika kotwica, do której popover był przypięty. Dlatego
/// iOS dostaje arkusz przypięty do ekranu i osobny przycisk na pasku.
struct YearFilter: View {
    @ObservedObject var library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        phone
        #else
        desktop
        #endif
    }

    #if os(iOS)
    /// Lata idą jako pełna lista do przewinięcia, nie jako rozwijane menu.
    /// Dwadzieścia pozycji w menu na telefonie ucinało się w połowie, a to
    /// właśnie środek puli jest tu najciekawszy.
    private var phone: some View {
        NavigationStack {
            Form {
                Section("Od") { yearList(selection: $library.fromYear, openEnd: 0, label: "od początku") }
                Section("Do") { yearList(selection: $library.toYear, openEnd: 9999, label: "do końca") }

                Section {
                    LabeledContent("W zakresie", value: "\(library.visibleAssets.count) zdjęć")
                    Button("wszystkie lata") {
                        library.fromYear = 0
                        library.toYear = 9999
                    }
                }
            }
            .navigationTitle("Zakres lat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotowe") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Rok zaznaczamy dotknięciem wiersza. `Picker` w arkuszu wracałby do
    /// tego samego zagnieżdżenia, od którego zaczął się cały problem.
    @ViewBuilder
    private func yearList(selection: Binding<Int>, openEnd: Int, label: String) -> some View {
        row(title: label, count: nil, value: openEnd, selection: selection)
        ForEach(library.years, id: \.year) { entry in
            row(title: String(entry.year), count: entry.count, value: entry.year, selection: selection)
        }
    }

    private func row(title: String, count: Int?, value: Int, selection: Binding<Int>) -> some View {
        Button {
            selection.wrappedValue = value
        } label: {
            HStack {
                Text(title)
                if let count {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selection.wrappedValue == value {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
    #endif

    private var desktop: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Zakres lat")
                .font(.headline)

            // Liczba zdjęć przy roku pokazuje od razu, gdzie w archiwum
            // siedzi materiał do pracy.
            Picker("od", selection: $library.fromYear) {
                Text("od początku").tag(0)
                ForEach(library.years, id: \.year) { entry in
                    Text("\(String(entry.year))  ·  \(entry.count)").tag(entry.year)
                }
            }
            Picker("do", selection: $library.toYear) {
                Text("do końca").tag(9999)
                ForEach(library.years.reversed(), id: \.year) { entry in
                    Text(String(entry.year)).tag(entry.year)
                }
            }

            HStack {
                Text("\(library.visibleAssets.count) zdjęć w zakresie")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("wszystkie") {
                    library.fromYear = 0
                    library.toYear = 9999
                }
            }
        }
        .pickerStyle(.menu)
        .padding(18)
        .frame(minWidth: 280)
    }
}
