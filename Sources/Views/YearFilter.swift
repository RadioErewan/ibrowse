import SwiftUI

/// Wybór zakresu lat w osobnym okienku.
///
/// Pierwsza wersja miała `Picker` zagnieżdżony w `Menu` — i zwijała się przy
/// każdym kliknięciu. Wybór zapisuje do `@Published`, widok się przebudowuje,
/// a menu znika razem z nim. Popover ma własny cykl życia i przeżywa zmianę
/// stanu, więc można ustawić oba krańce bez otwierania go od nowa.
struct YearFilter: View {
    @ObservedObject var library: PhotoLibrary

    var body: some View {
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
