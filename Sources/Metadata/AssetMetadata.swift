import Foundation

/// Metadane jednego zdjęcia, których PhotoKit nie udostępnia.
///
/// `PHAsset` zna datę, współrzędne i wymiary — i na tym koniec. Nazwy miejsc,
/// rozpoznane osoby, etykiety scen, odczytany tekst i cała technika zdjęcia
/// leżą w bazach biblioteki, do których nie ma publicznego API. Czyta je
/// eksporter i przywozi w pliku cech (kolumna `panel`, schemat 6) — na Maca
/// i na telefon tą samą drogą.
///
/// **Format JSON jest kontraktem między programami.** Klucze krótkie
/// i stałe; nowe pole to nowy klucz, który starszy czytnik zignoruje. Nazwy
/// pliku tu nie ma — daje ją PhotoKit na każdym urządzeniu.
struct AssetMetadata: Sendable, Codable, Equatable {
    var filename: String?
    var people: [String] = []
    var pets: [String] = []
    /// Od najbardziej szczegółowego do najogólniejszego.
    var place: [String] = []
    var scenes: [String] = []
    var occasion: [String] = []
    var words: [String] = []

    var camera: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var shutter: Double?
    var focalLength: Double?
    var flash: Bool?

    var isEmpty: Bool {
        filename == nil && people.isEmpty && place.isEmpty && scenes.isEmpty
            && occasion.isEmpty && words.isEmpty && camera == nil
    }

    private enum CodingKeys: String, CodingKey {
        case people, pets, place, scenes, occasion, words
        case camera, lens, iso, aperture, shutter
        case focalLength = "focal"
        case flash
    }

    init() {}

    /// Puste tablice nie trafiają do JSON-a — plik ma 25 tysięcy wierszy.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !people.isEmpty { try c.encode(people, forKey: .people) }
        if !pets.isEmpty { try c.encode(pets, forKey: .pets) }
        if !place.isEmpty { try c.encode(place, forKey: .place) }
        if !scenes.isEmpty { try c.encode(scenes, forKey: .scenes) }
        if !occasion.isEmpty { try c.encode(occasion, forKey: .occasion) }
        if !words.isEmpty { try c.encode(words, forKey: .words) }
        try c.encodeIfPresent(camera, forKey: .camera)
        try c.encodeIfPresent(lens, forKey: .lens)
        try c.encodeIfPresent(iso, forKey: .iso)
        try c.encodeIfPresent(aperture, forKey: .aperture)
        try c.encodeIfPresent(shutter, forKey: .shutter)
        try c.encodeIfPresent(focalLength, forKey: .focalLength)
        try c.encodeIfPresent(flash, forKey: .flash)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        pets = try c.decodeIfPresent([String].self, forKey: .pets) ?? []
        place = try c.decodeIfPresent([String].self, forKey: .place) ?? []
        scenes = try c.decodeIfPresent([String].self, forKey: .scenes) ?? []
        occasion = try c.decodeIfPresent([String].self, forKey: .occasion) ?? []
        words = try c.decodeIfPresent([String].self, forKey: .words) ?? []
        camera = try c.decodeIfPresent(String.self, forKey: .camera)
        lens = try c.decodeIfPresent(String.self, forKey: .lens)
        iso = try c.decodeIfPresent(Int.self, forKey: .iso)
        aperture = try c.decodeIfPresent(Double.self, forKey: .aperture)
        shutter = try c.decodeIfPresent(Double.self, forKey: .shutter)
        focalLength = try c.decodeIfPresent(Double.self, forKey: .focalLength)
        flash = try c.decodeIfPresent(Bool.self, forKey: .flash)
    }

    /// JSON do pliku; pusty napis, gdy nie ma czego nieść.
    var json: String {
        var copy = self
        copy.filename = nil
        guard copy != AssetMetadata() else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(copy) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    init?(json: String) {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AssetMetadata.self, from: data) else { return nil }
        self = decoded
    }
}
