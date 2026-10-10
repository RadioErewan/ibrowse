#if os(macOS)
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Konwersja do HEIC przy imporcie — **przed** biblioteką, nie w niej
/// (DECYZJE.md, „Konwersja do HEIC — właściwe miejsce jest przed importem").
///
/// Plik HEIC powstaje w katalogu tymczasowym aplikacji i stamtąd idzie do
/// Zdjęć. Oryginał na dysku zostaje nietknięty: folder jest otwarty
/// zakładką tylko do odczytu.
enum HEICMode: String, CaseIterable, Identifiable {
    /// HEIC z JPEG-a z aparatu, RAW zostaje na dysku.
    case fromJPEG
    /// HEIC wywołany z RAW-a, JPEG zostaje na dysku.
    case fromRAW
    /// HEIC z JPEG-a, RAW idzie do Zdjęć jako drugi plik tego samego zdjęcia.
    case keepRAW

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fromJPEG: String(localized: "JPEG → HEIC")
        case .fromRAW: String(localized: "RAW → HEIC")
        case .keepRAW: String(localized: "RAW + HEIC")
        }
    }

    var explanation: String {
        switch self {
        case .fromJPEG: String(localized: "HEIC made from the camera JPEG. RAW files stay on the disk.")
        case .fromRAW: String(localized: "HEIC developed from the RAW file. Camera JPEGs stay on the disk.")
        case .keepRAW: String(localized: "HEIC made from the camera JPEG, with the RAW file kept alongside it in Photos.")
        }
    }
}

/// Co dokładnie idzie do Zdjęć dla jednej pozycji.
struct ImportPlan: Sendable {
    let id: String
    let photo: URL
    let photoName: String
    let alternate: URL?
    /// Pliki zrobione przez nas — do skasowania po imporcie.
    let temporary: [URL]
    /// Ile ważyły oryginały zastąpione HEIC-iem i ile waży HEIC.
    let convertedFrom: Int64
    let convertedTo: Int64

    static func make(for item: ImportItem, mode: HEICMode?) -> ImportPlan {
        let raw = item.raw ?? (item.isRaw ? item.url : nil)
        let shown = item.isRaw ? nil : item.url

        guard let mode else {
            return plain(item, photo: item.url, alternate: item.raw)
        }

        // Źródło HEIC-a: JPEG, chyba że tryb każe wywołać RAW albo
        // JPEG-a po prostu nie ma.
        let source: URL
        let developRAW: Bool
        switch mode {
        case .fromRAW where raw != nil:
            source = raw!
            developRAW = true
        default:
            if let shown {
                source = shown
                developRAW = false
            } else {
                source = raw!
                developRAW = true
            }
        }
        let alternate = mode == .keepRAW ? raw : nil

        // HEIC, PNG, TIFF i inne idą jak są — konwertujemy tylko to, co
        // naprawdę zyskuje: JPEG i RAW.
        if !developRAW && !HEICConversion.isJPEG(source) {
            return plain(item, photo: source, alternate: alternate)
        }

        guard let heic = developRAW
                ? HEICConversion.develop(source)
                : HEICConversion.recompress(source)
        else {
            ImportSession.log.error("conversion failed: \(source.lastPathComponent, privacy: .private)")
            return plain(item, photo: item.url, alternate: item.raw)
        }
        return ImportPlan(
            id: item.id,
            photo: heic,
            photoName: source.deletingPathExtension().lastPathComponent + ".HEIC",
            alternate: alternate,
            temporary: [heic],
            convertedFrom: HEICConversion.size(source),
            convertedTo: HEICConversion.size(heic)
        )
    }

    private static func plain(_ item: ImportItem, photo: URL, alternate: URL?) -> ImportPlan {
        ImportPlan(
            id: item.id, photo: photo, photoName: photo.lastPathComponent,
            alternate: alternate, temporary: [], convertedFrom: 0, convertedTo: 0
        )
    }
}

enum HEICConversion {
    /// Jakość, przy której HEIC z JPEG-a z aparatu jest nie do odróżnienia
    /// w pełnym ekranie, a waży mniej więcej 40% mniej.
    static let quality = 0.8

    static func isJPEG(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .jpeg) ?? false
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "import-\(UUID().uuidString).heic")
    }

    /// JPEG → HEIC przez ImageIO. `AddImageFromSource` przenosi metadane
    /// razem z obrazem: datę, GPS, aparat, obiektyw i orientację.
    static func recompress(_ url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let target = temporaryURL()
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        return target
    }

    private static let context = CIContext()

    /// RAW → HEIC: wywołanie systemowe (to samo co w Podglądzie), 16 bitów
    /// na kanał w Display P3, więc koder zapisuje 10-bitowy HEIC.
    ///
    /// Metadane przepisujemy z RAW-a ręcznie — obraz z `CIRAWFilter` ich nie
    /// niesie. Orientacja 1, bo filtr już obrócił kadr.
    static func develop(_ url: URL) -> URL? {
        guard let filter = CIRAWFilter(imageURL: url),
              let image = filter.outputImage,
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let rendered = context.createCGImage(
                  image, from: image.extent, format: .RGBA16, colorSpace: space
              )
        else { return nil }

        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [
                kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary,
                kCGImagePropertyIPTCDictionary,
            ] {
                if let value = original[key] { properties[key] = value }
            }
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        let target = temporaryURL()
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        return target
    }
}
#endif
