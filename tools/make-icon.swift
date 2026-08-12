#!/usr/bin/env swift
// Robi komplet ikon z jednego pliku źródłowego.
//
//   swift tools/make-icon.swift ikona.png [udział]
//
// macOS i iOS potrzebują **innego kadru tego samego rysunku**. Na Macu ikona
// jest rysunkiem swobodnym: sam nosi zaokrąglony kształt i margines wokół
// niego, bo system niczego nie przycina. Na iOS odwrotnie — kanwa musi być
// wypełniona do krawędzi, bo maskę zaokrąglenia nakłada system. Ten sam plik
// wrzucony w oba miejsca daje albo ikonę w ramce, albo ikonę przyciętą.
//
// „udział" to część szerokości zajmowana przez sam kafelek (domyślnie 0.86).
// Stąd bierze się kadr dla iOS. Jeśli ikona na telefonie ma za dużo białego
// marginesu — podnieś; jeśli obcina narożniki — obniż.

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let sourcePath = arguments.count >= 2 ? arguments[1] : "Resources/icon-source.png"
let tileShare = arguments.count >= 3 ? Double(arguments[2]) ?? 0.86 : 0.86

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

/// Rysuje na **białym tle**, zawsze. iOS odrzuca ikony z kanałem alfa, a i na
/// Macu przezroczystość w rogach potrafi wyjść szarym prostokątem.
func render(_ image: CGImage, side: Int, cropping share: Double) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.interpolationQuality = .high

    let cropped: CGImage
    if share < 0.999 {
        let width = Double(image.width) * share
        let height = Double(image.height) * share
        let box = CGRect(
            x: (Double(image.width) - width) / 2,
            y: (Double(image.height) - height) / 2,
            width: width, height: height
        )
        cropped = image.cropping(to: box) ?? image
    } else {
        cropped = image
    }

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
    guard let image = render(original, side: side, cropping: 1.0) else { continue }
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

if let image = render(original, side: 1024, cropping: tileShare) {
    write(image, to: iosSet.appending(path: "icon.png"))
}
try? """
{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],\
"info":{"author":"ibrowse","version":1}}
""".write(to: iosSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

print("macOS: \(macSizes.count) plików · iOS: 1024×1024 z kadru \(Int(tileShare * 100))%")
