import CoreGraphics

/// The arithmetic behind keeping the Deckhand window the shape of the picture it shows.
public enum WindowSizing {
    /// A drag of an edge changes one side only, a drag of a corner both.
    public static func isCornerDrag(proposed: CGSize, current: CGSize) -> Bool {
        abs(proposed.width - current.width) > 0.5 && abs(proposed.height - current.height) > 0.5
    }

    /// The window size for a corner drag that keeps the shape the picture has now: the picture is scaled, what the window
    /// has besides it (`chrome`, and `bar` under the picture) is not. It is continuous, so nothing jumps when the drag starts,
    /// and a size below `minimum` is brought up to it with the shape kept. The scale follows the two sides equally.
    public static func scaled(proposed: CGSize, current: CGSize, chrome: CGSize, bar: CGFloat, minimum: CGSize) -> CGSize {
        let picture = CGSize(width: current.width - chrome.width, height: current.height - chrome.height - bar)
        guard picture.width > 1, picture.height > 1 else { return proposed }
        let wide = (proposed.width - chrome.width) / picture.width
        let high = (proposed.height - chrome.height - bar) / picture.height
        var scale = (wide + high) / 2
        let least = max((minimum.width - chrome.width) / picture.width,
                        (minimum.height - chrome.height - bar) / picture.height)
        scale = max(scale, least, 0.05)
        return CGSize(width: chrome.width + picture.width * scale, height: chrome.height + bar + picture.height * scale)
    }

    /// The width of the detail area at which a picture `pictureHeight` tall (and `aspect` wide per height) has no bars
    /// beside it. With the tools column showing, it is a share (`inspectorFraction`) of the area but never narrower than
    /// `inspectorMinimum`, which is how the window lays it out.
    public static func detailWidth(pictureHeight: CGFloat, aspect: CGFloat, showsInspector: Bool,
                                   inspectorFraction: CGFloat, inspectorMinimum: CGFloat) -> CGFloat {
        let picture = pictureHeight * aspect
        guard showsInspector else { return picture }
        let proportional = picture / (1 - inspectorFraction)
        return proportional * inspectorFraction >= inspectorMinimum ? proportional : picture + inspectorMinimum
    }
}
