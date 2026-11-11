import Charts
import SwiftUI

struct GraphView: View {
    let meter: FlukeMeter

    private var recorder: GraphRecorder { meter.recorder }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(recorder.graphing ? "Stop" : "Start") {
                    recorder.graphing ? recorder.stop() : recorder.start()
                }
                .buttonStyle(.glassProminent)
                .help(recorder.graphing ? "Stop recording readings" : "Start recording readings")
                Button("Clear") { recorder.clear() }
                    .help("Clear all recorded data")
                Spacer()
                Button("Export CSV…") { recorder.exportCSV() }
                    .disabled(recorder.series?.points.isEmpty ?? true)
                    .help("Save recorded data as a CSV file")
            }

            if let notice = recorder.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let series = recorder.series {
                chartSection(series: series)
                statistics(series)
            } else {
                Spacer()
                Text("No data recorded yet. Click Start to begin.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    // MARK: Chart

    private func chartSection(series: GraphSeries) -> some View {
        // Over-range samples are excluded from the y-domain entirely; they'd otherwise stretch the
        // axis to a meaningless value and squash every real reading into a sliver.
        let validPoints = series.points.filter { !$0.isOverload }
        let maxT = max(1, series.points.last?.t ?? 1)
        let rawMax = validPoints.map(\.y).max() ?? 0
        let rawMin = validPoints.map(\.y).min() ?? 0
        let span = max(rawMax - rawMin, abs(rawMax) * 0.01, 1e-12)
        let yMax = rawMax + span * 0.1
        let yMin = rawMin - span * 0.1
        return VStack(alignment: .leading, spacing: 4) {
            Text(series.label).font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(downsampled(series.points), id: \.t) { point in
                    // NaN is how a gap is drawn: Charts skips a line segment through a coordinate it can't render.
                    let y: Double = point.isOverload ? .nan : point.y
                    LineMark(x: .value("t", point.t), y: .value("value", y))
                        .foregroundStyle(Color.fluke)
                }
            }
            .chartXScale(domain: 0...maxT)
            .chartYScale(domain: yMin...yMax)
            .chartXAxisLabel("Time (s)")
            .chartYAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let d = value.as(Double.self) { Text(Format.axis(d)) }
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
        }
    }

    private func statistics(_ series: GraphSeries) -> some View {
        HStack(spacing: 20) {
            stat("Min", series.hasStatistics ? Format.si(series.minimum, unit: series.symbol) : "–")
            stat("Max", series.hasStatistics ? Format.si(series.maximum, unit: series.symbol) : "–")
            stat("Average", series.mean.map { Format.si($0, unit: series.symbol) } ?? "–")
            stat("Samples", String(series.points.count))
            Spacer()
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    /// Display-only decimation: the chart rebuilds a LineMark per point on every update, so an
    /// hours-long recording would get sluggish. Strided sampling caps rendering at ~500 marks.
    private func downsampled(_ points: [GraphPoint]) -> [GraphPoint] {
        let maxPoints = 500
        guard points.count > maxPoints else { return points }
        let step = (points.count + maxPoints - 1) / maxPoints
        var out = [GraphPoint]()
        out.reserveCapacity(maxPoints + 1)
        var i = 0
        while i < points.count {
            out.append(points[i])
            i += step
        }
        // Always keep the newest sample so the line's leading edge tracks live.
        if let last = points.last, out.last!.t != last.t { out.append(last) }
        return out
    }
}
