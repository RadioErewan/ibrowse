#!/usr/bin/env swift
// Robi komplet ikon z jednego pliku źródłowego.
//
//   swift tools/make-icon.swift [mac.png] [ios.png]
//
// macOS i iOS potrzebują **innego kadru tego samego rysunku**. Na Macu ikona
// jest rysunkiem swobodnym: sam nosi zaokrąglony kształt i margines wokół
// niego, bo system niczego nie przycina. Na iOS odwrotnie — kanwa musi być
// wypełniona do krawędzi, bo maskę zaokrąglenia nakłada system. Ten sam plik
// wrzucony w oba miejsca daje albo ikonę w ramce, albo ikonę przyciętą.
//
// Najlepiej podać **dwa mastery**, po jednym na kadr: `icon-source.png`
// z marginesem i cieniem dla Maca, `icon-source-ios.png` wypełniony do
// krawędzi dla telefonu. Wtedy nic nie trzeba zgadywać ani przycinać.
//
// Gdy drugiego nie ma, narzędzie **znajduje kafelek samo** w pierwszym: szuka
// pikseli jaśniejszych od tła i przycina do nich. Działa, ale gorzej — rysunek
// dla Maca ma na brzegach cień, a wycięty z niego kadr dla iOS niesie go ze
// sobą.
//
// Przezroczystość traktujemy różnie na każdej platformie i to jest celowe.
// macOS **potrzebuje** alfy: ikona jest tam rysunkiem swobodnym, a spłaszczona
// na biało wychodzi w Docku białym kwadratem. iOS alfy **nie przyjmuje**
// w ogóle, więc tam spłaszczamy. Poprzednia wersja spłaszczała wszędzie i na
// Macu to był błąd, tyle że niewidoczny, bo rysunek miał białe tło.

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let sourcePath = arguments.count >= 2 ? arguments[1] : "Resources/icon-source.png"
let iosPath = arguments.count >= 3 ? arguments[2] : "Resources/icon-source-ios.png"

guard FileManager.default.fileExists(atPath: sourcePath) else {
    print("""
        Nie ma pliku \(sourcePath).
        Zapisz rysunek ikony (kwadrat, najlepiej 1024×1024) pod tą nazwą albo \
        podaj ścieżkę: swift tools/make-icon.swift <plik.png> [udział kafelka]
        """)
    exit(1)
}

guard let source = NSImage(contentsOfFile: sourcePath),
      let original = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("nie umiem odczytać: \(sourcePath)")
    exit(1)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// MARK: - Znajdowanie kafelka

/// Prostokąt kafelka albo `nil`, gdy nie da się go odróżnić od tła.
///
/// Kafelek jest jaśniejszy niż tło, a **między** nimi leży cień, czyli pasmo
/// ciemniejsze od obu. Dlatego szukamy pikseli jaśniejszych od tła, a nie
/// „różnych od tła" — to drugie łapie cień i daje kadr o kilka procent za
/// szeroki. Skanujemy środkowy wiersz i środkową kolumnę, bo tam kafelek nie
/// ma zaokrągleń i jego krawędź jest prosta.
func findTile(in image: CGImage) -> CGRect? {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(
        data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    func luminance(_ x: Int, _ y: Int) -> Int {
        let i = (y * w + x) * 4
        return (Int(data[i]) * 299 + Int(data[i + 1]) * 587 + Int(data[i + 2]) * 114) / 1000
    }

    let background = luminance(2, 2)
    let brighter = { (x: Int, y: Int) in luminance(x, y) > background + 2 }
    let midY = h / 2, midX = w / 2

    var left = -1, right = -1, bottom = -1, top = -1
    for x in 0..<w where brighter(x, midY) { left = x; break }
    for x in stride(from: w - 1, through: 0, by: -1) where brighter(x, midY) { right = x; break }
    for y in 0..<h where brighter(midX, y) { bottom = y; break }
    for y in stride(from: h - 1, through: 0, by: -1) where brighter(midX, y) { top = y; break }

    guard left >= 0, right > left, bottom >= 0, top > bottom else { return nil }

    // Kafelek zajmujący prawie całą kanwę albo jej ułamek to znak, że
    // trafiliśmy w coś innego niż kafelek. Wtedy lepiej oddać pole liczbie.
    let share = Double(right - left + 1) / Double(w)
    guard share > 0.5, share < 0.98 else { return nil }

    // Kadr musi być kwadratem, bo ikona jest kwadratem. Bierzemy krótszy bok
    // i środek **kafelka**, nie kanwy.
    let side = Double(min(right - left + 1, top - bottom + 1))
    return CGRect(
        x: Double(left + right + 1) / 2 - side / 2,
        y: Double(bottom + top + 1) / 2 - side / 2,
        width: side, height: side
    )
}

/// `flatten` decyduje o tle: biel dla iOS, przezroczystość dla Maca.
/// Patrz komentarz na górze pliku — to nie jest szczegół, tylko różnica
/// między ikoną w Docku a białym kwadratem w Docku.
func render(_ image: CGImage, side: Int, cropping box: CGRect?, flatten: Bool) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: (flatten ? CGImageAlphaInfo.noneSkipLast
                             : CGImageAlphaInfo.premultipliedLast).rawValue
    ) else { return nil }

    if flatten {
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
    context.interpolationQuality = .high

    let cropped = box.flatMap { image.cropping(to: $0) } ?? image

    context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

// MARK: - macOS

/// Klasyczny komplet zamiast pojedynczego 1024. Xcode przyjmuje jedną
/// wielkość, ale wtedy Finder skaluje w locie i przy 16 px z rysunku
/// zostaje plama — te małe kafelki widuje się częściej niż duże.
let macSizes: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

let macSet = root.appending(path: "Resources/Mac.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: macSet, withIntermediateDirectories: true)

var macEntries: [String] = []
for (point, scale) in macSizes {
    let side = point * scale
    let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
    guard let image = render(original, side: side, cropping: nil, flatten: false)
    else { continue }
    write(image, to: macSet.appending(path: name))
    macEntries.append("""
        {"filename":"\(name)","idiom":"mac","scale":"\(scale)x","size":"\(point)x\(point)"}
        """)
}

try? """
{"images":[\(macEntries.joined(separator: ","))],"info":{"author":"ibrowse","version":1}}
""".write(to: macSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

// MARK: - iOS

let iosSet = root.appending(path: "Resources/iOS.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iosSet, withIntermediateDirectories: true)

// Własny master wygrywa z przycinaniem cudzego — patrz komentarz na górze.
let iosSource = NSImage(contentsOfFile: iosPath)?
    .cgImage(forProposedRect: nil, context: nil, hints: nil)
let iosImage = iosSource ?? original
let iosBox: CGRect? = iosSource != nil ? nil : findTile(in: original)

if let image = render(iosImage, side: 1024, cropping: iosBox, flatten: true) {
    write(image, to: iosSet.appending(path: "icon.png"))
}
try? """
{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],\
"info":{"author":"ibrowse","version":1}}
""".write(to: iosSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

let howIOS: String
if iosSource != nil {
    howIOS = "z własnego mastera \(iosPath)"
} else if let box = iosBox {
    howIOS = "z kadru \(Int(box.width))×\(Int(box.height)) znalezionego w rysunku dla Maca"
} else {
    howIOS = "z całego rysunku dla Maca — kafelka nie znalazłem, sprawdź wynik"
}
print("""
    macOS: \(macSizes.count) plików, z przezroczystością
    iOS:   1024×1024, spłaszczone na biało, \(howIOS)
    """)
