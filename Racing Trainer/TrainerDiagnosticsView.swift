import SwiftUI

/// Development tools retain their datasets but are absent from the driving view.
struct TrainerDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    let analyzer: FrameAnalyzer
    let datasetRecorder: MinimapDatasetRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Input Diagnostics").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        RouteDetectionStatusBadge(analyzer: analyzer)
                        FrameDebugView(analyzer: analyzer, maximumHeight: 1_200,
                                       allowsDragging: false, isEmbedded: true)
                    }.padding()
                }.tabItem { Label("Live Input", systemImage: "waveform.path") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        GroupBox("Minimap Dataset") { MinimapDatasetControls(recorder: datasetRecorder) }
                        GroupBox("Route Mask Dataset") {
                            DatasetMetadataCounterView(store: datasetRecorder.routeMaskDatasetStore, isOverlay: false)
                        }
                    }.padding()
                }.tabItem { Label("Datasets", systemImage: "tray.full") }
            }
        }.padding(20).frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 700)
    }
}
