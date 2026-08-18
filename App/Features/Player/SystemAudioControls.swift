import AVKit
import MediaPlayer
import SwiftUI

/// The system volume slider.
///
/// `MPVolumeView` rather than a slider of my own, because **system volume cannot be
/// set programmatically** — `AVAudioSession.outputVolume` is read-only, and the
/// private setter is a rejection. This is the only sanctioned way for an app to put a
/// working volume control on its own player screen, and it comes with the right
/// behaviour for free: it tracks the hardware buttons, shows the routing state, and
/// turns into an AirPlay-aware control when output is remote.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        // The route button lives beside the mode switcher instead, where it can be
        // sized and tinted to match the other controls.
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.tintColor = UIColor(Color.appTint)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    /// Without this the view reports its intrinsic size and the slider ends up
    /// vertically centred in far too much space.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MPVolumeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 28)
    }
}

/// AirPlay and Bluetooth output picker. Shows the system route sheet, and its icon
/// changes on its own when a remote route is active.
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(Color.white.opacity(0.6))
        view.activeTintColor = UIColor(Color.appTint)
        // The default behaviour also offers to mirror the whole screen, which is never
        // what someone wants from a music player.
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}

    /// Without this the view reports no intrinsic size and expands to fill whatever it
    /// is given — which is how it ended up rendering many times larger than the icons
    /// beside it. The glyph is drawn to the view's bounds, so the bounds *are* the icon
    /// size, and this matches the `.title3` symbols it sits next to.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AVRoutePickerView,
        context: Context
    ) -> CGSize? {
        CGSize(width: 22, height: 22)
    }
}
