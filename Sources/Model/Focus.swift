import Foundation

/// Wskaźnik miejsca i zaznaczenie — wspólne dla siatki, pełnego ekranu,
/// parowania i podglądu.
///
/// Mieszkały jako `@State` w widoku głównym. Każda strzałka i każda ocena
/// przesuwa wskaźnik, więc każda przebudowywała **całe okno**: pasek narzędzi,
/// obie kolumny, panel filtrów i pasek stanu — po pół sekundy na klawisz,
/// a w siatce autorepetycja w ogóle nie nadążała. Tu obserwują je tylko
/// widoki, które ich naprawdę używają; widok główny trzyma sam obiekt.
@MainActor
final class Focus: ObservableObject {
    @Published var id: String?
    @Published var selection: Set<String> = []
}
