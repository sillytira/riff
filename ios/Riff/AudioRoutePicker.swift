import SwiftUI
import AVKit

/// AVKit provides the system AirPlay/audio-route UI; SwiftUI has no native equivalent.
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .label
        picker.activeTintColor = .systemPurple
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
