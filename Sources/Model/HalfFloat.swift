import Foundation

/// Konwersja `Float` ⟷ 16-bitowy half float (IEEE 754 binary16).
///
/// Napisana ręcznie, a nie przez wbudowany typ `Float16`, bo ten nie istnieje
/// na macOS x86_64. Gdyby format zapisu zależał od architektury, skład zrobiony
/// na Apple Silicon byłby nieczytelny na Intelu — a to jest projekt, który
/// mają budować też inni.
///
/// Deskryptory z Vision mieszczą się w zakresie ±0,7, więc zapas half floata
/// (±65504) jest ogromny, a strata precyzji nie zmienia żadnej decyzji
/// o przynależności do serii — sprawdzone pomiarem na realnej próbce.
enum HalfFloat {
    static func encode(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        var exponent = Int32((bits >> 23) & 0xFF) - 127 + 15
        var mantissa = bits & 0x7F_FFFF

        if exponent <= 0 {
            // Niedomiar: albo zero, albo liczba subnormalna.
            guard exponent >= -10 else { return sign }
            mantissa |= 0x80_0000
            return sign | UInt16(mantissa >> UInt32(14 - exponent))
        }
        if exponent >= 0x1F { return sign | 0x7C00 }  // nadmiar → nieskończoność

        // Zaokrąglenie do najbliższej, remis do parzystej.
        let rounded = mantissa + 0x0FFF + ((mantissa >> 13) & 1)
        if rounded & 0x80_0000 != 0 {
            exponent += 1
            mantissa = 0
        } else {
            mantissa = rounded
        }
        return sign | UInt16(exponent << 10) | UInt16((mantissa >> 13) & 0x3FF)
    }

    static func decode(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let exponent = UInt32((half >> 10) & 0x1F)
        let mantissa = UInt32(half & 0x3FF)

        if exponent == 0 {
            guard mantissa != 0 else { return Float(bitPattern: sign) }
            var e = exponent
            var m = mantissa
            while m & 0x400 == 0 {
                m <<= 1
                e &-= 1
            }
            return Float(bitPattern: sign | ((e &+ 113) << 23) | ((m & 0x3FF) << 13))
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }

    /// Pakuje wektor do połowy rozmiaru. Przy 25 tysiącach zdjęć to różnica
    /// między ~78 a ~39 MB w składzie.
    static func pack(_ values: [Float]) -> Data {
        var halves = values.map(encode)
        return Data(bytes: &halves, count: halves.count * MemoryLayout<UInt16>.size)
    }

    static func unpack(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt16.self).map(decode)
        }
    }
}
