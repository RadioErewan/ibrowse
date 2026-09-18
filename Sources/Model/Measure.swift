import Foundation

/// Miara policzona przez system, której **znaczenie opisujemy ręcznie**.
///
/// Podział pracy jest taki: aplikacja sama sprawdza, czy kolumna istnieje
/// w tej wersji systemu, ile ma wartości i jaki ma rozkład. Nie ma natomiast jak
/// zgadnąć, co liczba znaczy — w której stronie jest lepiej, czy to przełącznik,
/// jak ją nazwać po ludzku. Na to są twarde dowody: kolumna `ZBLURRINESSSCORE`
/// rośnie wraz z ostrością, szum ma wyłącznie wartości ujemne z zerem jako
/// najlepszym wynikiem, a ikoniczność ma zakres od −2 do 1. Dlatego ten spis
/// jest pisany, a nie odkrywany.
///
/// Zapisane w `DECYZJE.md`, rozdział „Sekcja cech musi być otwarta".
struct Measure: Identifiable, Hashable, Sendable {

    /// Czego miara dotyczy — i od razu, do jakiego zadania służy.
    /// Jak w `Filters.Feature`: `rawValue` jest kluczem, `label` napisem.
    enum Group: String, CaseIterable, Sendable {
        case photo, archive, technique

        var label: String {
            switch self {
            case .photo: String(localized: "photo qualities")
            case .archive: String(localized: "archive status")
            case .technique: String(localized: "technique")
            }
        }
    }

    enum Kind: Sendable {
        /// Liczba na skali — nadaje się na próg i na sortowanie.
        case continuous
        /// Tak albo nie — nadaje się na wiersz z licznikiem.
        case flag
    }

    /// **Stały na zawsze.** To on jedzie w składzie i w pliku wymiany, więc
    /// raz nadany nie może zmienić znaczenia ani trafić do innej miary. Miara
    /// wycofana zostawia swój kod nieużywany.
    let code: UInt8

    /// Napis **źródłowy, po angielsku** — jednocześnie klucz w katalogu
    /// tłumaczeń. Sam `code` pozostaje tym, co jedzie w składzie i w pliku
    /// wymiany; nazwa wolno się zmienia i wolno ją tłumaczyć.
    let key: String
    let group: Group
    let kind: Kind

    /// Po której stronie skali leży lepszy wynik. Warunek „najgorsze" bierze
    /// zdjęcia z przeciwnej strony, więc bez tego próg odsiewałby odwrotnie.
    let higherIsBetter: Bool

    /// Wyrażenie SQL nad aliasami `a` (ZASSET), `c` (ZCOMPUTEDASSETATTRIBUTES),
    /// `m` (ZMEDIAANALYSISASSETATTRIBUTES) i `x` (ZADDITIONALASSETATTRIBUTES).
    let expression: String

    var id: UInt8 { code }

    /// Nazwa w języku interfejsu. Wyszukiwana po kluczu, bo spis powstaje raz
    /// przy starcie, a język ma obowiązywać wszędzie tam, gdzie miara się
    /// pokazuje.
    var label: String { String(localized: String.LocalizationValue(key)) }

    /// Jak nazwać stronę, którą warunek wybiera.
    var worstSide: String {
        switch kind {
        case .flag: return label
        case .continuous: return higherIsBetter ? "below" : "above"
        }
    }
}

extension Measure {
    private static func photo(_ code: UInt8, _ key: String, _ expr: String,
                              higherIsBetter: Bool = true) -> Measure {
        Measure(code: code, key: key, group: .photo, kind: .continuous,
                higherIsBetter: higherIsBetter, expression: expr)
    }

    private static func flag(_ code: UInt8, _ key: String, _ group: Group,
                             _ condition: String) -> Measure {
        Measure(code: code, key: key, group: group, kind: .flag,
                higherIsBetter: true,
                expression: "CASE WHEN \(condition) THEN 1 END")
    }

    /// Spis. Kody nadane raz — nowe pozycje dostają kolejne, nigdy stare.
    static let all: [Measure] = [
        // Właściwości zdjęcia — miary ciągłe.
        photo(1, "overall aesthetics", "a.ZOVERALLAESTHETICSCORE"),
        photo(2, "curation", "a.ZCURATIONSCORE"),
        photo(3, "iconic", "a.ZICONICSCORE"),
        photo(4, "composition", "c.ZPLEASANTCOMPOSITIONSCORE"),
        photo(5, "lighting", "c.ZPLEASANTLIGHTINGSCORE"),
        photo(6, "interesting subject", "c.ZINTERESTINGSUBJECTSCORE"),
        photo(7, "subject choice", "c.ZWELLCHOSENSUBJECTSCORE"),
        photo(8, "framing", "c.ZWELLFRAMEDSUBJECTSCORE"),
        photo(9, "timing", "c.ZWELLTIMEDSHOTSCORE"),
        photo(10, "subject sharpness", "c.ZSHARPLYFOCUSEDSUBJECTSCORE"),
        photo(11, "lively colour", "c.ZLIVELYCOLORSCORE"),
        photo(12, "colour harmony", "c.ZHARMONIOUSCOLORSCORE"),
        photo(13, "background blur", "c.ZTASTEFULLYBLURREDSCORE"),
        photo(14, "perspective", "c.ZPLEASANTPERSPECTIVESCORE"),
        photo(15, "symmetry", "c.ZPLEASANTSYMMETRYSCORE"),
        photo(16, "patterns", "c.ZPLEASANTPATTERNSCORE"),
        photo(17, "reflections", "c.ZPLEASANTREFLECTIONSSCORE"),
        photo(18, "post-processing", "c.ZPLEASANTPOSTPROCESSINGSCORE"),
        // Przechył, szum, nieudane ujęcie i natrętny obiekt mają **tylko**
        // wartości ujemne albo bliskie zera, a zero jest najlepsze. Wyżej
        // znaczy więc lepiej, choć nazwy sugerują odwrotnie.
        photo(19, "camera tilt", "c.ZPLEASANTCAMERATILTSCORE"),
        photo(20, "noise", "c.ZNOISESCORE"),
        photo(21, "failed shot", "c.ZFAILURESCORE"),
        photo(22, "intrusive object", "c.ZINTRUSIVEOBJECTPRESENCESCORE"),
        photo(23, "low light", "c.ZLOWLIGHT", higherIsBetter: false),
        photo(24, "immersiveness", "c.ZIMMERSIVENESSSCORE"),
        photo(25, "activity", "m.ZACTIVITYSCORE"),
        photo(26, "wallpaper suitability", "m.ZWALLPAPERSCORE"),

        // Stan w archiwum — historia zdjęcia, nie obraz.
        flag(40, "never viewed", .archive, "x.ZVIEWCOUNT = 0"),
        flag(41, "shared at some point", .archive, "x.ZSHARECOUNT > 0"),
        flag(42, "favourite", .archive, "a.ZFAVORITE = 1"),
        flag(43, "camera burst", .archive, "a.ZAVALANCHEUUID IS NOT NULL"),
        flag(44, "system duplicate", .archive, "a.ZDUPLICATEASSETVISIBILITYSTATE > 0"),

        // Technika i obecność ludzi.
        // „Bez twarzy" z jawnej kolumny liczby twarzy, **nie** ze zliczenia
        // wykrytych twarzy: tam zero znaczy też „nie analizowano".
        flag(60, "no faces", .technique, "m.ZFACECOUNT = 0"),
        flag(61, "people in frame", .technique, "x.ZHASPEOPLESCENEMIDORGREATERCONFIDENCE = 1"),
        flag(62, "HDR", .technique, "a.ZHDRTYPE > 0"),
        flag(63, "portrait with depth map", .technique, "a.ZDEPTHTYPE > 0"),
        flag(64, "video", .technique, "a.ZKIND = 1"),
        flag(65, "no location", .technique, "(a.ZLATITUDE IS NULL OR a.ZLATITUDE <= -180)"),
        flag(66, "low resolution", .technique, "a.ZWIDTH * a.ZHEIGHT < 2000000"),
    ]

    static let byCode: [UInt8: Measure] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.code, $0) }
    )
}

/// Pakowanie miar jednego zdjęcia do bajtów.
///
/// Format: powtórzone pięć bajtów — kod miary (UInt8) i wartość (Float32,
/// little-endian). Nic więcej, bez nagłówka i bez wersji, bo **kody są stałe**:
/// starsza wersja aplikacji pomija kody, których nie zna, a nowsza przy starym
/// pliku po prostu znajduje ich mniej. Zgodność idzie w obie strony bez
/// migracji.
///
/// Przełączniki zapisujemy **tylko wtedy, gdy są prawdą**. Czterdzieści miar
/// na 26 tysięcy zdjęć to wtedy około 4 MB, wobec 39 MB odcisków wizualnych,
/// które i tak jeżdżą w pliku wymiany.
enum MeasurePacking {
    static func pack(_ values: [UInt8: Float]) -> Data {
        var data = Data(capacity: values.count * 5)
        for (code, value) in values.sorted(by: { $0.key < $1.key }) {
            data.append(code)
            var little = value.bitPattern.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack(_ data: Data) -> [UInt8: Float] {
        var result: [UInt8: Float] = [:]
        let bytes = [UInt8](data)
        var index = 0
        while index + 5 <= bytes.count {
            let code = bytes[index]
            let bits = UInt32(bytes[index + 1])
                | UInt32(bytes[index + 2]) << 8
                | UInt32(bytes[index + 3]) << 16
                | UInt32(bytes[index + 4]) << 24
            result[code] = Float(bitPattern: bits)
            index += 5
        }
        return result
    }
}
