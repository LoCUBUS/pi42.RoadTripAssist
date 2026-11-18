import Foundation

enum RouteOptimizationError: Error, Equatable {
    case invalidMatrix
    case invalidStopIndices
    case noCompleteRoute
    case tooManyStops(Int)
}

extension RouteOptimizationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidMatrix:
            "The route-time matrix contains invalid values."
        case .invalidStopIndices:
            "The start, destination, and intermediate stops must be distinct valid indices."
        case .noCompleteRoute:
            "No complete route through all intermediate stops is available."
        case .tooManyStops(let count):
            "The exact prototype optimizer supports up to \(RouteOptimizer.maximumExactStopCount) stops; \(count) were selected."
        }
    }
}

enum RouteOptimizer {
    static let maximumExactStopCount = 18

    /// Returns indices in visit order, excluding the fixed start and destination.
    static func optimize(
        travelTimes: [[TimeInterval]],
        startIndex: Int,
        stopIndices: [Int],
        destinationIndex: Int
    ) throws -> [Int] {
        let locationCount = travelTimes.count
        guard travelTimes.allSatisfy({ $0.count == locationCount }),
              travelTimes.indices.allSatisfy({ row in
                  travelTimes[row].allSatisfy { !$0.isNaN && $0 >= 0 }
              }) else {
            throw RouteOptimizationError.invalidMatrix
        }

        let allIndices = [startIndex] + stopIndices + [destinationIndex]
        guard Set(allIndices).count == allIndices.count,
              allIndices.allSatisfy({ travelTimes.indices.contains($0) }) else {
            throw RouteOptimizationError.invalidStopIndices
        }

        let stopCount = stopIndices.count
        guard stopCount <= maximumExactStopCount else {
            throw RouteOptimizationError.tooManyStops(stopCount)
        }
        guard stopCount > 0 else {
            return []
        }

        let stateCount = 1 << stopCount
        let infinity = TimeInterval.infinity
        var costs = Array(
            repeating: Array(repeating: infinity, count: stopCount),
            count: stateCount
        )
        var previous = Array(
            repeating: Array(repeating: -1, count: stopCount),
            count: stateCount
        )

        for stopPosition in 0..<stopCount {
            let mask = 1 << stopPosition
            costs[mask][stopPosition] = travelTimes[startIndex][stopIndices[stopPosition]]
        }

        for mask in 1..<stateCount {
            for last in 0..<stopCount where mask & (1 << last) != 0 {
                let currentCost = costs[mask][last]
                guard currentCost.isFinite else { continue }

                for next in 0..<stopCount where mask & (1 << next) == 0 {
                    let nextMask = mask | (1 << next)
                    let candidate = currentCost
                        + travelTimes[stopIndices[last]][stopIndices[next]]
                    if candidate < costs[nextMask][next] {
                        costs[nextMask][next] = candidate
                        previous[nextMask][next] = last
                    }
                }
            }
        }

        let fullMask = stateCount - 1
        let finalCosts = (0..<stopCount).map { stopPosition in
            costs[fullMask][stopPosition]
                + travelTimes[stopIndices[stopPosition]][destinationIndex]
        }
        guard let lastStop = finalCosts.indices
            .filter({ finalCosts[$0].isFinite })
            .min(by: { finalCosts[$0] < finalCosts[$1] }) else {
            throw RouteOptimizationError.noCompleteRoute
        }

        var orderedPositions: [Int] = []
        var mask = fullMask
        var current = lastStop
        while current >= 0 {
            orderedPositions.append(current)
            let prior = previous[mask][current]
            mask ^= 1 << current
            current = prior
        }

        return orderedPositions.reversed().map { stopIndices[$0] }
    }
}
