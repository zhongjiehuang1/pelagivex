import Foundation
import Testing
@testable import VisionCore

struct EndToEndDecoderTests {
    @Test func wideVocabularyKeepsExactClassIDsAndMaskCoefficients() throws {
        let rows: [Float] = [10, 20, 50, 80, 0.8, 4583, 0.2, -0.4,
                             1, 2, 3, 4, 0.4, 2, 0.3, 0.6]
        let result = try Decoder.decodeEndToEnd(rows, classes: 4585, channels: 2, proposals: 2)
        #expect(result.count == 2)
        #expect(result[0].classID == 4583)
        #expect(result[0].box == Box(10, 20, 50, 80))
        #expect(result[0].score == 0.8)
        #expect(result[0].coefficients == [0.2, -0.4])
        #expect(result[0].classConfidences.map(\.classID) == [4583])
    }

    @Test func malformedRowsCannotBecomeDetections() throws {
        let rows: [[Float]] = [
            [1, 1, 2, 2, .nan, 0, 1],
            [1, 1, 2, 2, 0.8, .infinity, 1],
            [1, 1, 2, 2, 0.8, 0.5, 1],
            [1, 1, 2, 2, 0.8, 4, 1],
            [2, 1, 1, 2, 0.8, 0, 1],
            [1, 1, 2, 2, 1.2, 0, 1],
            [1, 1, 2, 2, 0.8, 0, .nan],
            [1, 1, 2, 2, 0.1, 0, 1]
        ]
        #expect(try Decoder.decodeEndToEnd(rows.flatMap { $0 }, classes: 4, channels: 1,
                                           proposals: rows.count).isEmpty)
        #expect(throws: (any Error).self) {
            try Decoder.decodeEndToEnd([1], classes: 4585, channels: 1, proposals: 1)
        }
    }

    @Test func contractSelectsTheInspectedEndToEndLayout() throws {
        let names = Array(repeating: "object", count: 4585)
        let payload: [String: Any] = [
            "schema": 2, "format": "yolo26-e2e-seg", "modelName": "YOLOE-26s",
            "inputName": "image", "inputSize": 640, "predictionName": "pred", "prototypeName": "proto",
            "classNames": names, "maskChannels": 32, "prototypeWidth": 160, "prototypeHeight": 160,
            "predictionCount": 300
        ]
        let contract = try JSONDecoder().decode(ModelContract.self, from: JSONSerialization.data(withJSONObject: payload))
        try contract.validate()
        #expect(contract.isEndToEnd)
        #expect(contract.modelName == "YOLOE-26s")
    }
}
