import SwiftUI

/// Suwak z dwoma znacznikami nad histogramem rozkładu.
///
/// Powstał z pytania, na które zwykły suwak z progiem nie umiał odpowiedzieć:
/// „czy ikoniczność ma być większa, czy mniejsza od wybranej wartości?". Przy
/// mierze od −2 do 1 nie wiadomo, która strona jest ciekawa. Dwa znaczniki
/// zdejmują to pytanie — „poniżej" to lewy znacznik na krańcu, „powyżej" prawy,
/// a środek skali też da się wziąć.
///
/// Histogram pod ścieżką jest tu częścią kontrolki, nie ozdobą: dopiero kształt
/// rozkładu pokazuje, gdzie leży większość zdjęć i gdzie jest ta rzadka
/// końcówka, po którą zwykle się sięga. Słupki w wybranym przedziale są
/// podświetlone, więc od razu widać, ile archiwum się bierze.
///
/// Własna kontrolka, bo system nie ma suwaka z dwoma znacznikami. Rysowana
/// kolorami systemowymi i w proporcjach zwykłego suwaka, żeby nie wyglądała
/// na obcą.
struct RangeSlider: View {
    @Binding var range: ClosedRange<Double>
    let bounds: ClosedRange<Double>
    var histogram: [Int] = []

    private let knob: CGFloat = 14
    @State private var dragStart: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - knob, 1)
            let lowX = position(range.lowerBound, width: width)
            let highX = position(range.upperBound, width: width)

            ZStack(alignment: .topLeading) {
                bars(width: width)
                    .frame(height: 22)
                    .offset(x: knob / 2)

                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                    .offset(x: knob / 2, y: 26)
                    .frame(width: width)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(highX - lowX, 0), height: 4)
                    .offset(x: lowX + knob / 2, y: 26)

                handle
                    .offset(x: lowX, y: 21)
                    .gesture(drag(lower: true, width: width))
                handle
                    .offset(x: highX, y: 21)
                    .gesture(drag(lower: false, width: width))
            }
        }
        .frame(height: 36)
    }

    private var handle: some View {
        Circle()
            .fill(.white)
            .frame(width: knob, height: knob)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .contentShape(Rectangle().inset(by: -6))
    }

    @ViewBuilder
    private func bars(width: CGFloat) -> some View {
        let peak = max(histogram.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(histogram.indices, id: \.self) { index in
                let center = bounds.lowerBound
                    + (Double(index) + 0.5) / Double(max(histogram.count, 1))
                    * (bounds.upperBound - bounds.lowerBound)
                // Pierwiastek z wysokości: przy rozkładach z jednym ogromnym
                // słupkiem reszta byłaby niewidoczną kreską, a to właśnie
                // w reszcie zwykle siedzi to, czego się szuka.
                let height = sqrt(Double(histogram[index]) / Double(peak))
                Rectangle()
                    .fill(range.contains(center)
                          ? Color.accentColor.opacity(0.55)
                          : Color.secondary.opacity(0.25))
                    .frame(height: max(1, 22 * height))
            }
        }
        .frame(width: width, height: 22, alignment: .bottom)
    }

    private func position(_ value: Double, width: CGFloat) -> CGFloat {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - bounds.lowerBound) / span) * width
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max(Double(x / width), 0), 1)
        return bounds.lowerBound + fraction * (bounds.upperBound - bounds.lowerBound)
    }

    private func drag(lower: Bool, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let start = dragStart ?? range
                if dragStart == nil { dragStart = range }
                let origin = position(lower ? start.lowerBound : start.upperBound, width: width)
                let moved = value(at: origin + gesture.translation.width, width: width)
                // Znaczniki nie przechodzą przez siebie: lewy zatrzymuje się na
                // prawym i odwrotnie. Zamiana ról w trakcie przeciągania byłaby
                // dla ręki kompletnie nieczytelna.
                if lower {
                    range = min(moved, range.upperBound)...range.upperBound
                } else {
                    range = range.lowerBound...max(moved, range.lowerBound)
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}
