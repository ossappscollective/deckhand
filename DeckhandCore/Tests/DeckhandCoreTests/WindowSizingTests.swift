import CoreGraphics
import Testing
@testable import DeckhandCore

private let chrome = CGSize(width: 0, height: 52)

@Test func onlyADragOfACornerChangesBothSides() {
    let current = CGSize(width: 300, height: 700)
    #expect(WindowSizing.isCornerDrag(proposed: CGSize(width: 340, height: 740), current: current))
    #expect(!WindowSizing.isCornerDrag(proposed: CGSize(width: 340, height: 700), current: current))
    #expect(!WindowSizing.isCornerDrag(proposed: CGSize(width: 300, height: 650), current: current))
}

@Test func aCornerDragStartsWithoutAJump() {
    let current = CGSize(width: 300, height: 700)
    let size = WindowSizing.scaled(proposed: CGSize(width: 301, height: 701), current: current, chrome: chrome, bar: 36,
                                   minimum: CGSize(width: 200, height: 300))
    #expect(abs(size.width - 301) < 2 && abs(size.height - 701) < 2)
}

@Test func aCornerDragKeepsTheShapeOfThePictureItStartedWith() {
    let current = CGSize(width: 300, height: 52 + 36 + 600)   // the picture is 300 x 600
    let size = WindowSizing.scaled(proposed: CGSize(width: 450, height: 700), current: current, chrome: chrome, bar: 36,
                                   minimum: CGSize(width: 100, height: 100))
    let picture = CGSize(width: size.width - chrome.width, height: size.height - chrome.height - 36)
    #expect(abs(picture.width / picture.height - 0.5) < 0.0001)
}

@Test func aSizeBelowTheMinimumKeepsTheShape() {
    let current = CGSize(width: 300, height: 52 + 36 + 600)
    let size = WindowSizing.scaled(proposed: CGSize(width: 100, height: 200), current: current, chrome: chrome, bar: 36,
                                   minimum: CGSize(width: 220, height: 360))
    #expect(size.width >= 220 - 0.001 && size.height >= 360 - 0.001)
    #expect(abs(size.width / (size.height - 52 - 36) - 0.5) < 0.0001)
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
