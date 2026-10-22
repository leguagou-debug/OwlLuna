import SwiftUI

/// The files shared stay in their export folder until what was chosen has finished: shared, saved or cancelled.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let files = items.compactMap { $0 as? URL }.filter(\.isFileURL)
        ExportFolder.beginReading(files)
        controller.completionWithItemsHandler = { _, _, _, _ in ExportFolder.endReading(files) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
