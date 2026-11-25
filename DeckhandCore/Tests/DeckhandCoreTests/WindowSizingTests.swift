import CoreGraphics
import Testing
@testable import DeckhandCore

private let chrome = CGSize(width: 0, height: 52)

@Test func draggingTheWidthDrivesTheHeightAtThePicturesShape() {
    // a 9:19.5 picture; the window is 300 wide with a 52 high titlebar and a 36 high bar
    let aspect: CGFloat = 9 / 19.5
    let size = WindowSizing.constrained(proposed: CGSize(width: 360, height: 700), current: CGSize(width: 300, height: 700),
                                        chrome: chrome, bar: 36, aspect: aspect, minimum: CGSize(width: 200, height: 300))
    #expect(size.width == 360)
    #expect(abs((size.width) / (size.height - 52 - 36) - aspect) < 0.0001)
}

@Test func draggingTheHeightDrivesTheWidth() {
    let aspect: CGFloat = 0.5
    let size = WindowSizing.constrained(proposed: CGSize(width: 300, height: 788), current: CGSize(width: 300, height: 600),
                                        chrome: chrome, bar: 36, aspect: aspect, minimum: CGSize(width: 100, height: 100))
    #expect(size.height == 788)
    #expect(size.width == (788 - 52 - 36) * aspect)
}

@Test func aSizeBelowTheMinimumKeepsTheShape() {
    let aspect: CGFloat = 0.5
    let size = WindowSizing.constrained(proposed: CGSize(width: 100, height: 200), current: CGSize(width: 300, height: 600),
                                        chrome: chrome, bar: 36, aspect: aspect, minimum: CGSize(width: 220, height: 360))
    #expect(size.width >= 220 && size.height >= 360)
    #expect(abs(size.width / (size.height - 52 - 36) - aspect) < 0.0001)
}

@Test func theWindowWidthForAPictureWithoutTheToolsColumnIsThePicturesWidth() {
    #expect(WindowSizing.detailWidth(pictureHeight: 800, aspect: 0.5, showsInspector: false,
                                     inspectorFraction: 0.38, inspectorMinimum: 340) == 400)
}

@Test func withTheToolsColumnThePictureKeepsItsWidthAfterTheSplit() {
    for (fraction, minimum) in [(0.38, 340.0), (0.38, 640.0), (0.5, 340.0)] {
        let total = WindowSizing.detailWidth(pictureHeight: 800, aspect: 0.5, showsInspector: true,
                                             inspectorFraction: fraction, inspectorMinimum: minimum)
        // the same split as the window: the column is a share of the width, never narrower than its content
        let inspector = max(total * fraction, minimum)
        #expect(abs((total - inspector) - 400) < 0.001)
    }
}
