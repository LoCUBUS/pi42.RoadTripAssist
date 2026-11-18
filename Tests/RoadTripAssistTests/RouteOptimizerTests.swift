import XCTest
@testable import RoadTripAssist

final class RouteOptimizerTests: XCTestCase {
    func testFindsShortestStopOrderAndKeepsEndpointsFixed() throws {
        let times: [[TimeInterval]] = [
            [0, 9, 2, 20],
            [2, 0, 8, 3],
            [9, 3, 0, 10],
            [20, 7, 1, 0]
        ]

        let order = try RouteOptimizer.optimize(
            travelTimes: times,
            startIndex: 0,
            stopIndices: [1, 2],
            destinationIndex: 3
        )

        XCTAssertEqual(order, [2, 1])
    }

    func testReturnsEmptyOrderWhenThereAreNoIntermediateStops() throws {
        let order = try RouteOptimizer.optimize(
            travelTimes: [[0, 7], [9, 0]],
            startIndex: 0,
            stopIndices: [],
            destinationIndex: 1
        )

        XCTAssertTrue(order.isEmpty)
    }

    func testRejectsNonSquareTravelTimeMatrix() {
        XCTAssertThrowsError(
            try RouteOptimizer.optimize(
                travelTimes: [[0, 1], [1]],
                startIndex: 0,
                stopIndices: [],
                destinationIndex: 1
            )
        )
    }

    func testRejectsMatrixWithoutACompleteRoute() {
        let times: [[TimeInterval]] = [
            [0, 1, .infinity, .infinity],
            [.infinity, 0, 1, .infinity],
            [.infinity, .infinity, 0, .infinity],
            [.infinity, .infinity, .infinity, 0]
        ]

        XCTAssertThrowsError(
            try RouteOptimizer.optimize(
                travelTimes: times,
                startIndex: 0,
                stopIndices: [1, 2],
                destinationIndex: 3
            )
        ) { error in
            XCTAssertEqual(error as? RouteOptimizationError, .noCompleteRoute)
        }
    }

    func testUsesAvailableEdgesWhenSomeCandidateLegsAreMissing() throws {
        let times: [[TimeInterval]] = [
            [0, 4, 2, .infinity],
            [4, 0, .infinity, 3],
            [2, 1, 0, 8],
            [.infinity, .infinity, .infinity, 0]
        ]

        let order = try RouteOptimizer.optimize(
            travelTimes: times,
            startIndex: 0,
            stopIndices: [1, 2],
            destinationIndex: 3
        )

        XCTAssertEqual(order, [2, 1])
    }
}
