//
//  ParameterEstimation.swift
//  Loop
//
//  Created by Dragan Maksimovic on 7/16/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

// dm61 parameter estimation wip, new class July 15 collect all wip
class ParameterEstimation {
    var startDate: Date
    var endDate: Date
    var glucose: [GlucoseValue]?
    var insulinEffect: [GlucoseEffect]?
    var basalEffect: [GlucoseEffect]?
    var enteredCarbs: HKQuantity?
    var observedCarbs: HKQuantity?
    var estimatedMultipliers: EstimatedMultipliers?
    var estimatedMultipliersSubIntervals: [EstimatedMultipliers] = []
    var parameterEstimationType: ParameterEstimationType
    
    let unit = HKUnit.milligramsPerDeciliter
    let velocityUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
    
    init(startDate: Date, endDate: Date, type: ParameterEstimationType, glucose: [GlucoseValue], insulinEffect: [GlucoseEffect], basalEffect: [GlucoseEffect]? = nil, enteredCarbs: HKQuantity? = nil, observedCarbs: HKQuantity? = nil) {
        self.startDate = startDate
        self.endDate = endDate
        self.parameterEstimationType = type
        self.insulinEffect = insulinEffect
        self.glucose = glucose
        self.basalEffect = basalEffect
        self.enteredCarbs = enteredCarbs
        self.observedCarbs = observedCarbs
    }
    
    func estimateParameters() {

        switch self.parameterEstimationType {
            
        case .carbAbsorption:
            estimateParametersForCarbEntries()
            return
            
        case .fasting:
            estimateParametersDuringFasting(start: self.startDate, end: self.endDate)
            return
            
        default:
            return
        
        }

    }
    
    func estimateParametersDuringFasting(start: Date, end: Date) {
        
        let glucoseValues = self.glucose?.filter { (value) -> Bool in
            if value.startDate < start {
                return false
            }
            if value.startDate > end {
                return false
            }
            return true
        }
        
        guard
            let glucose = glucoseValues,
            let insulinEffect = self.insulinEffect?.filterDateRange(start, end),
            let basalEffect = self.basalEffect?.filterDateRange(start, end),
            glucose.count > 5
            else {
                return
        }
        
        guard
            let startGlucose = glucose.first?.quantity.doubleValue(for: unit),
            let endGlucose = glucose.last?.quantity.doubleValue(for: unit),
            let startInsulin = insulinEffect.first?.quantity.doubleValue(for: unit),
            let endInsulin = insulinEffect.last?.quantity.doubleValue(for: unit),
            let startBasal = basalEffect.first?.quantity.doubleValue(for: unit),
            let endBasal = basalEffect.last?.quantity.doubleValue(for: unit)
            else {
                return
        }
        
        //let startHour = startDate.addingTimeInterval(.hours(1)).addingTimeInterval(.minutes(-Double(Calendar.current.component(.minute, from: startDate))))
        //let endHour = endDate.addingTimeInterval(.minutes(-Double(Calendar.current.component(.minute, from: endDate))))
        
        let deltaGlucose = endGlucose - startGlucose
        let deltaGlucoseInsulin = startInsulin - endInsulin
        let deltaGlucoseBasal = endBasal - startBasal
        
        let (basalMultiplier, insulinSensitivityMultiplierInverse) = projectionToLine(a: deltaGlucoseBasal, b: -deltaGlucose, c: deltaGlucoseBasal + deltaGlucoseInsulin)
        let insulinSensitivityMultiplier = 1.0 / insulinSensitivityMultiplierInverse
        
        let estimatedMultipliers = EstimatedMultipliers(startDate: startDate, endDate: endDate, basalMultiplier: basalMultiplier, insulinSensitivityMultiplier: insulinSensitivityMultiplier, carbSensitivityMultiplier: insulinSensitivityMultiplier, carbRatioMultiplier: 1.0)
        
        self.estimatedMultipliers = estimatedMultipliers
    }
    
    func estimateParametersForCarbEntries() {
        
        let start = self.startDate
        let end = self.endDate
        
        let glucoseValues = self.glucose?.filter { (value) -> Bool in
            if value.startDate < start {
                return false
            }
            if value.startDate > end {
                return false
            }
            return true
        }
        
        guard
            let glucose = glucoseValues,
            let insulinEffect = self.insulinEffect?.filterDateRange(start, end),
            glucose.count > 5
            else {
                return
        }
        
        guard
            let startGlucose = glucose.first?.quantity.doubleValue(for: unit),
            let endGlucose = glucose.last?.quantity.doubleValue(for: unit),
            let startInsulin = insulinEffect.first?.quantity.doubleValue(for: unit),
            let endInsulin = insulinEffect.last?.quantity.doubleValue(for: unit),
            let observedCarbs = self.observedCarbs?.doubleValue(for: .gram()),
            let enteredCarbs = self.enteredCarbs?.doubleValue(for: .gram()),
            enteredCarbs > 0.0
            else {
                return
        }
        
        //dm61 July 7-12 notes: redo cr, csf, isf multipliers
        // notes in ParameterEstimationNotes.pptx
        
        let observedOverEnteredRatio = observedCarbs / enteredCarbs
        let deltaGlucose = endGlucose - startGlucose
        let deltaGlucoseInsulin = startInsulin - endInsulin
        
        let deltaGlucoseCounteraction = deltaGlucose + deltaGlucoseInsulin
        guard
            deltaGlucoseCounteraction != 0.0,
            observedOverEnteredRatio != 0.0
            else {
                return
        }
        
        // sqrt models the assumption that observed/entered is a product of mis-estimated carbs factor and a mimatched parameters factor
        let actualOverObservedRatio = (1.0 / observedOverEnteredRatio).squareRoot() // c
        let csfWeight = deltaGlucose / deltaGlucoseCounteraction // a
        let crWeight = 1.0 - csfWeight // b
        
        let (csfMultiplierInverse, crMultiplier) = projectionToLine(a: csfWeight, b: crWeight, c: actualOverObservedRatio)
        
        let carbSensitivityMultiplier = 1.0 / csfMultiplierInverse
        let insulinSensitivityMultiplier = crMultiplier / csfMultiplierInverse
        
        
        let estimatedMultipliers = EstimatedMultipliers(startDate: startDate, endDate: endDate, basalMultiplier: 1.0, insulinSensitivityMultiplier: insulinSensitivityMultiplier, carbSensitivityMultiplier: carbSensitivityMultiplier, carbRatioMultiplier: crMultiplier)
        
        self.estimatedMultipliers = estimatedMultipliers
        
        return
    }
    
    
}

class EstimatedMultipliers {
    var startDate: Date
    var endDate: Date
    var basalMultiplier: Double
    var insulinSensitivityMultiplier: Double
    var carbSensitivityMultiplier: Double
    var carbRatioMultiplier: Double
    
    init(startDate: Date, endDate: Date, basalMultiplier: Double, insulinSensitivityMultiplier: Double, carbSensitivityMultiplier: Double, carbRatioMultiplier: Double) {
        self.startDate = startDate
        self.endDate = endDate
        self.basalMultiplier = basalMultiplier
        self.insulinSensitivityMultiplier = insulinSensitivityMultiplier
        self.carbSensitivityMultiplier = carbSensitivityMultiplier
        self.carbRatioMultiplier = carbRatioMultiplier
    }
    
}

struct ParameterEstimationType: OptionSet {
    let rawValue: Int
    
    static let carbAbsorption = ParameterEstimationType(rawValue: 1 << 0)
    static let fasting = ParameterEstimationType(rawValue: 1 << 1)
}

/// projection of point (1, 1) to line a * x + b * y = c
fileprivate func projectionToLine(a: Double, b: Double, c: Double) -> (Double, Double) {
    let dotProduct = pow(a, 2.0) + pow(b, 2.0)
    if dotProduct == 0.0 {
        return(1.0, 1.0)
    } else {
        let x = (pow(b, 2.0) - a * b + a * c) / dotProduct
        let y = (pow(a, 2.0) - a * b + b * c) / dotProduct
        return(x, y)
    }
}
