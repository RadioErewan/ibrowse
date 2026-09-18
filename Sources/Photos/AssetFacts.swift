import CoreLocation
import ImageIO
import Photos

/// Fakty o zdjęciu dostępne **na obu platformach**, bez zaglądania do baz
/// biblioteki.
///
/// Panel na Macu czyta `psi.sqlite` i `Photos.sqlite`, więc zna etykiety scen,
/// imiona i odczytany tekst. Na telefonie tych baz nie ma i nie będzie: iOS
/// trzyma swój odpowiednik w piaskownicy aplikacji Zdjęcia, gdzie nie sięga
/// żadne API. Zostaje to, co da się wziąć z samego PhotoKit i z pliku zdjęcia.
struct AssetFacts: Sendable {
    var filename: String?
    var camera: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var shutter: Double?
    var focalLength: Double?

    /// Nazwa miejsca z odwrotnego geokodowania. Osobno od reszty, bo wymaga
    /// sieci i przychodzi później niż wszystko inne.
    var place: String?

    /// Czy oryginał leżał na urządzeniu. Gdy nie leży, technika jest pusta
    /// i trzeba to powiedzieć wprost, zamiast pokazywać puste pola.
    var hasLocalOriginal = false

    var hasExposure: Bool {
        iso != nil || aperture != nil || shutter != nil || focalLength != nil
    }
}

extension AssetFacts {

    /// Nazwa pliku jest darmowa — `PHAssetResource` zna ją bez dotykania
    /// zawartości, więc nie kosztuje ani bajtu z iCloud.
    static func quick(for asset: PHAsset) -> AssetFacts {
        var facts = AssetFacts()
        facts.filename = PHAssetResource.assetResources(for: asset)
            .first { $0.type == .photo || $0.type == .fullSizePhoto }?
            .originalFilename
        return facts
    }

    /// Dociąga technikę zdjęcia z **lokalnego** pliku.
    ///
    /// `isNetworkAccessAllowed = false` jest tu decyzją o miejscu na dysku,
    /// nie o szybkości: pobranie oryginału z iCloud zostawiłoby go na telefonie
    /// na stałe, a PhotoKit nie daje sposobu, żeby go potem usunąć. Lepiej
    /// przyznać się do braku danych, niż po cichu zapełniać pamięć.
    static func detailed(for asset: PHAsset) async -> AssetFacts {
        var facts = quick(for: asset)

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }

        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return facts }

        facts.hasLocalOriginal = true

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = tiff[kCGImagePropertyTIFFMake] as? String
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            facts.camera = [make, model].compactMap { $0 }.joined(separator: " ")
            if facts.camera?.isEmpty == true { facts.camera = nil }
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            // ISO bywa tablicą — aparaty potrafią zapisać kilka wartości.
            if let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                facts.iso = speeds.first
            }
            facts.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            facts.shutter = exif[kCGImagePropertyExifExposureTime] as? Double
            facts.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            facts.lens = exif[kCGImagePropertyExifLensModel] as? String
        }

        return facts
    }

    /// Odwrotne geokodowanie jednego zdjęcia na żądanie.
    ///
    /// Apple ostro ogranicza tempo tych zapytań, więc nadaje się wyłącznie do
    /// pojedynczego zdjęcia otwartego świadomie — nigdy do przewijania.
    static func place(for asset: PHAsset) async -> String? {
        guard let location = asset.location else { return nil }
        guard let marks = try? await CLGeocoder().reverseGeocodeLocation(location),
              let mark = marks.first else { return nil }

        return [mark.name, mark.locality, mark.country]
            .compactMap { $0 }
            .reduce(into: [String]()) { unique, part in
                if !unique.contains(part) { unique.append(part) }
            }
            .joined(separator: " · ")
    }

    // MARK: - Wspólne formatowanie

    static func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    static func megapixels(_ asset: PHAsset) -> String {
        let value = Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000
        return String(format: "%.1f Mpx", value)
    }

    static func traits(_ asset: PHAsset) -> [String] {
        var traits: [String] = []
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoPanorama) { traits.append("panorama") }
        if subtypes.contains(.photoHDR) { traits.append("HDR") }
        if subtypes.contains(.photoScreenshot) { traits.append("screenshot") }
        if subtypes.contains(.photoLive) { traits.append("Live") }
        if subtypes.contains(.photoDepthEffect) { traits.append("portrait") }
        if asset.representsBurst { traits.append("burst") }
        return traits
    }

    static func exposureLine(
        focalLength: Double?, aperture: Double?, shutter: Double?, iso: Int?
    ) -> String? {
        let parts = [
            focalLength.map { String(format: "%.0f mm", $0) },
            aperture.map { String(format: "f/%.1f", $0) },
            shutter.map(shutterText),
            iso.map { "ISO \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
