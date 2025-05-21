//
//  CoreMLHelper.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-19.
//

import CoreML

/// Simple 0-1 Min-Max scaler that works on a [1, 8, 4] MLMultiArray
/// (`sequenceLength = 8`, `featureCount = 4`)
final class SequenceMinMaxScaler {

    struct Params: Decodable {
        let min:   [Float]   // length == 4
        let max:   [Float]   // length == 4
        // Convenience
        var range: [Float] { zip(max, min).map { $0 - $1 } }
    }

    let params: Params  // Made public for inverse transformation

    /// Load params from *scaler_params.json* in the main bundle
    init() throws {
        guard let url = Bundle.main.url(forResource: "scaler_params",
                                        withExtension: "json") else {
            throw NSError(
                domain: "SequenceMinMaxScaler",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "❌ scaler_params.json not found in app bundle. " +
                    "Make sure the file is added to the project and that its “Target Membership” " +
                    "includes NightScouttoHealthKit."])
        }
        let data = try Data(contentsOf: url)
        params = try JSONDecoder().decode(Params.self, from: data)
        precondition(params.min.count == 4 && params.max.count == 4, "Expect 4 features")
    }

    /// In-place scale of a [1, 8, 4] MLMultiArray (Float32)
    func transform(_ x: MLMultiArray) {
        precondition(x.shape == [1, 8, 4] as [NSNumber],
                     "Shape must be [1,8,4]")
        let seqLen = 8, featCnt = 4
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(x.dataPointer))

        // Core ML uses row-major; iterate over timesteps then features
        for t in 0..<seqLen {
            for f in 0..<featCnt {
                let idx = t * featCnt + f                      // (1 × 8 × 4) flatten
                let v   = ptr[idx]
                ptr[idx] = (v - params.min[f]) / params.range[f]         // (v - min) / (max - min)
            }
        }
    }
}
