//
//  BolusSuggestionUserInfo.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/20/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation


struct BolusSuggestionUserInfo: RawRepresentable {
    let recommendedBolus: Double?
    let recommendedSuperBolus: Double?
    var maxBolus: Double?

    init(recommendedBolus: Double?, recommendedSuperBolus: Double? = nil, maxBolus: Double? = nil) {
        self.recommendedBolus = recommendedBolus
        self.recommendedSuperBolus = recommendedSuperBolus
        self.maxBolus = maxBolus
    }

    // MARK: - RawRepresentable
    typealias RawValue = [String: Any]

    static let version = 1
    static let name = "BolusSuggestionUserInfo"

    init?(rawValue: RawValue) {
        guard rawValue["v"] as? Int == type(of: self).version && rawValue["name"] as? String == BolusSuggestionUserInfo.name,
            let recommendedBolus = rawValue["br"] as? Double else
        {
            return nil
        }

        self.recommendedBolus = recommendedBolus
        self.recommendedSuperBolus = rawValue["sb"] as? Double
        self.maxBolus = rawValue["mb"] as? Double
    }

    var rawValue: RawValue {
        var raw: RawValue = [
            "v": type(of: self).version,
            "name": BolusSuggestionUserInfo.name,
        ]

        raw["br"] = recommendedBolus
        raw["sb"] = recommendedSuperBolus
        raw["mb"] = maxBolus

        return raw
    }
}
