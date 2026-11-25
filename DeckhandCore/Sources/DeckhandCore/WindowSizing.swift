import CoreGraphics

/// The arithmetic behind keeping the Deckhand window the shape of the picture it shows.
public enum WindowSizing {
    /// The window size to use instead of `proposed` while the picture must keep `aspect` (width over height).
    /// `chrome` is what the window has besides the picture and `bar` the strip under it. The side the pointer moved
    /// more decides, and a size below `minimum` is brought up to it with the shape kept.
    public static func constrained(proposed: CGSize, current: CGSize, chrome: CGSize, bar: CGFloat,
                                   aspect: CGFloat, minimum: CGSize) -> CGSize {
        guard aspect > 0 else { return proposed }
        let pictureWidth = max(proposed.width - chrome.width, 1)
        let pictureHeight = max(proposed.height - chrome.height - bar, 1)
        let widthMoved = abs(proposed.width - current.width) / max(current.width, 1)
        let heightMoved = abs(proposed.height - current.height) / max(current.height, 1)
        var width = pictureWidth
        var height = pictureHeight
        if widthMoved >= heightMoved { height = width / aspect } else { width = height * aspect }
        var size = CGSize(width: width + chrome.width, height: height + chrome.height + bar)
        if size.width < minimum.width {
            size.width = minimum.width
            size.height = (size.width - chrome.width) / aspect + chrome.height + bar
        }
        if size.height < minimum.height {
            size.height = minimum.height
            size.width = (size.height - chrome.height - bar) * aspect + chrome.width
        }
        return size
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
