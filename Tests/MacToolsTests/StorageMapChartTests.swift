import Foundation
import XCTest
@testable import MacTools

final class StorageMapChartTests: XCTestCase {
    func testAreaMatchesSizesAndRectanglesCoverWithoutOverlap() {
        let weights: [Int64] = [700, 290, 120, 100, 75, 60, 55, 30, 25, 10, 5, 1]
        let bounds = CGRect(x: 17, y: 9, width: 837, height: 206)
        let rectangles = StorageMapLayout.rectangles(weights: weights, in: bounds)
        let total = Double(weights.reduce(0, +))
        let area = bounds.width * bounds.height

        XCTAssertEqual(rectangles.count, weights.count)
        XCTAssertEqual(rectangles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, area, accuracy: 0.00001)
        for value in rectangles {
            let expected = area * Double(weights[value.index]) / total
            XCTAssertEqual(value.rect.width * value.rect.height, expected, accuracy: 0.00001)
            XCTAssertGreaterThanOrEqual(value.rect.minX, bounds.minX - 0.00001)
            XCTAssertGreaterThanOrEqual(value.rect.minY, bounds.minY - 0.00001)
            XCTAssertLessThanOrEqual(value.rect.maxX, bounds.maxX + 0.00001)
            XCTAssertLessThanOrEqual(value.rect.maxY, bounds.maxY + 0.00001)
        }
        for first in rectangles.indices {
            for second in rectangles.indices where second > first {
                let overlap = rectangles[first].rect.intersection(rectangles[second].rect)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.00001)
            }
        }
    }

    func testZeroAndNegativeSizesDoNotReceiveArea() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 200)
        let rectangles = StorageMapLayout.rectangles(weights: [0, -10, 70, 0, 30], in: bounds)
        XCTAssertEqual(rectangles.map(\.index), [2, 4])
        XCTAssertEqual(rectangles[0].rect.width * rectangles[0].rect.height, 84_000, accuracy: 0.00001)
        XCTAssertTrue(StorageMapLayout.rectangles(weights: [0, -1], in: bounds).isEmpty)
        XCTAssertTrue(StorageMapLayout.rectangles(weights: [], in: bounds).isEmpty)
    }

    func testSingleItemFillsBoundsAndZeroBoundsProduceNoTiles() {
        let bounds = CGRect(x: 10, y: 20, width: 1, height: 2)
        let rectangles = StorageMapLayout.rectangles(weights: [1], in: bounds)
        XCTAssertEqual(rectangles.first?.rect, bounds)
        XCTAssertTrue(StorageMapLayout.rectangles(weights: [1], in: .zero).isEmpty)
    }

    func testLargeSizesDoNotOverflowAndPortraitBoundsStayProportional() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 600)
        let rectangles = StorageMapLayout.rectangles(weights: [.max, .max], in: bounds)
        XCTAssertEqual(rectangles.count, 2)
        for value in rectangles {
            XCTAssertEqual(value.rect.width * value.rect.height, 60_000, accuracy: 0.00001)
        }
    }
}
