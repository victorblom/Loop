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

class ParameterEstimation {
    var startDate: Date
    var endDate: Date
    var glucose: [GlucoseValue] = []
    var insulinEffect: [GlucoseEffect]?
    var basalEffect: [GlucoseEffect]?
    var carbStatuses: [CarbStatus<StoredCarbEntry>] = []
    var estimationIntervals: [EstimationInterval] = []
    
    let unit = HKUnit.milligramsPerDeciliter
    let velocityUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
    
    init(startDate: Date, endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
    }
    
    func updateParameterEstimates() {
        assembleEstimationIntervals()
        for estimationInterval in estimationIntervals {
            estimationInterval.estimateParameters()
        }
    }
    
    func assembleEstimationIntervals() {
        var runningEndDate = self.endDate
        for carbStatus in carbStatuses {
            guard
                let entryStart = carbStatus.absorption?.observedDate.start,
                let entryEnd = carbStatus.absorption?.observedDate.end,
                let enteredCarbs = carbStatus.absorption?.total,
                let observedCarbs = carbStatus.absorption?.observed,
                let timeRemaining = carbStatus.absorption?.estimatedTimeRemaining
                else {
                    continue
            }
            
            // clean-up if an active carb absorption entry is detected and terminate interval assembly
            if timeRemaining > 0 {
                if entryStart < self.startDate {
                    self.endDate = self.startDate
                    return // if active carb absorption started before start of the estimation interval we have no valid intervals available for estimation
                }
                runningEndDate = min(entryStart, self.endDate)
                for (index, estimationInterval) in self.estimationIntervals.enumerated() {
                    // trim any fasting intervals up to start of active carb absorption
                    if estimationInterval.estimationIntervalType == .fasting {
                        estimationInterval.endDate = min(runningEndDate, estimationInterval.endDate)
                    }
                    // remove any completed carb absorption that overlaps with active carb absorption
                    if estimationInterval.estimationIntervalType == .carbAbsorption {
                        if estimationInterval.endDate > runningEndDate {
                            self.estimationIntervals.remove(at: index)
                        }
                    }
                }
                // clamp endDate and return
                self.endDate = runningEndDate
                return
            }
            
            if estimationIntervals.count == 0 {
                // no intervals setup yet
                if entryStart > self.startDate {
                    // add first fasting interval between self.startDate and entryStart
                    let glucoseEffect = self.glucose.filterDateRange(self.startDate, entryStart)
                    let insulinEffect = self.insulinEffect?.filterDateRange(self.startDate, entryStart)
                    let basalEffect = self.basalEffect?.filterDateRange(self.startDate, entryStart)
                    estimationIntervals.append(EstimationInterval(startDate: self.startDate, endDate: entryStart, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
                }
                if entryEnd < self.endDate {
                    if estimationIntervals.count == 0 {
                        // carbs started before startDate; move startDate to entryEnd
                        self.startDate = entryEnd
                    } else {
                        // add first carbAbsorption interval entryStart to entryEnd
                        let glucoseEffect = self.glucose.filterDateRange(entryStart, entryEnd)
                        let insulinEffect = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                        let basalEffect = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                        estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                        runningEndDate = entryEnd
                    }
                }
            } else {
                // at least one interval already setup
                if estimationIntervals.last!.estimationIntervalType == .fasting {
                    estimationIntervals.last!.endDate = entryStart // terminate fasting interval
                    // add carbAbsorption interval from entryStart to entryEnd
                    let glucoseEffect = self.glucose.filterDateRange(entryStart, entryEnd)
                    let insulinEffect = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                    let basalEffect = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                    estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                    runningEndDate = entryEnd
                } else {
                    // here previous estimaton interval must be .carbAbsorption
                    if entryStart > estimationIntervals.last!.endDate {
                        // add fasting interval between last endDate and entryStart
                        let glucoseEffect = self.glucose.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        let insulinEffect = self.insulinEffect?.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        let basalEffect = self.basalEffect?.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        estimationIntervals.append(EstimationInterval(startDate: estimationIntervals.last!.endDate, endDate: entryStart, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
                        //** add carbAbsorption interval from entryStart to entryEnd
                        let glucoseEffectEntry = self.glucose.filterDateRange(entryStart, entryEnd)
                        let insulinEffectEntry = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                        let basalEffectEntry = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                        estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseEffectEntry, insulinEffect: insulinEffectEntry, basalEffect: basalEffectEntry, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                        runningEndDate = entryEnd
                    } else {
                        // merge carbAbsorption interval into previous carbAbsorption interval
                        runningEndDate = max(estimationIntervals.last!.endDate, entryEnd)
                        estimationIntervals.last!.endDate = runningEndDate
                        let previouslyEnteredCarbGrams = estimationIntervals.last!.enteredCarbs!.doubleValue(for: .gram())
                        let enteredCarbGrams = enteredCarbs.doubleValue(for: .gram())
                        estimationIntervals.last!.enteredCarbs = HKQuantity(unit: .gram(), doubleValue: enteredCarbGrams + previouslyEnteredCarbGrams)
                        let previouslyObservedCarbGrams = estimationIntervals.last!.observedCarbs!.doubleValue(for: .gram())
                        let observedCarbGrams = observedCarbs.doubleValue(for: .gram())
                        estimationIntervals.last!.observedCarbs = HKQuantity(unit: .gram(), doubleValue: observedCarbGrams + previouslyObservedCarbGrams)
                    }
                    
                }

            }
        }
        // the last previously entered interval should be carbAbsorption
        if runningEndDate < self.endDate {
            //add a fasting interval from the runningEndDate and self.endDate
            let glucoseEffect = self.glucose.filterDateRange(runningEndDate, self.endDate)
            let insulinEffect = self.insulinEffect?.filterDateRange(runningEndDate, self.endDate)
            let basalEffect = self.basalEffect?.filterDateRange(runningEndDate, self.endDate)
            estimationIntervals.append(EstimationInterval(startDate: runningEndDate, endDate: self.endDate, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
        }
    }
}

// dm61 parameter estimation wip, new class July 15 collect all wip
class EstimationInterval {
    var startDate: Date
    var endDate: Date
    var glucose: [GlucoseValue]? //** should replace with deltaBG
    var insulinEffect: [GlucoseEffect]? //** should replace with deltaBGi
    var basalEffect: [GlucoseEffect]? //** should replace with delatBGb
    var enteredCarbs: HKQuantity?
    var observedCarbs: HKQuantity?
    var estimatedMultipliers: EstimatedMultipliers?
    var estimatedMultipliersSubIntervals: [EstimatedMultipliers] = []
    var estimationIntervalType: EstimationIntervalType
    
    let unit = HKUnit.milligramsPerDeciliter
    let velocityUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
    
    init(startDate: Date, endDate: Date, type: EstimationIntervalType, glucose: [GlucoseValue], insulinEffect: [GlucoseEffect]?, basalEffect: [GlucoseEffect]? = nil, enteredCarbs: HKQuantity? = nil, observedCarbs: HKQuantity? = nil) {
        self.startDate = startDate
        self.endDate = endDate
        self.estimationIntervalType = type
        self.insulinEffect = insulinEffect
        self.glucose = glucose
        self.basalEffect = basalEffect
        self.enteredCarbs = enteredCarbs
        self.observedCarbs = observedCarbs
    }
    
    func estimateParameters() {

        switch self.estimationIntervalType {
            
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
        
        guard
            let glucose = self.glucose?.filterDateRange(start, end),
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
        
        guard
            let glucose = self.glucose?.filterDateRange(start, end),
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

struct EstimationIntervalType: OptionSet {
    let rawValue: Int
    
    static let carbAbsorption = EstimationIntervalType(rawValue: 1 << 0)
    static let fasting = EstimationIntervalType(rawValue: 1 << 1)
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

/// filterDataRange for [GlucoseValue]
extension Collection where Iterator.Element == GlucoseValue {
    func filterDateRange(_ startDate: Date?, _ endDate: Date?) -> [Iterator.Element] {
        return filter { (value) -> Bool in
            if let startDate = startDate, value.endDate < startDate {
                return false
            }
            
            if let endDate = endDate, value.startDate > endDate {
                return false
            }
            
            return true
        }
    }
}

extension ParameterEstimation {
    /// Generates a diagnostic report about the current state
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .medium
        dateFormatter.dateStyle = .medium
        /*
        let userCalendar = Calendar.current
        var defaultDateComponents = DateComponents()
        var defaultDate = Date()
        defaultDateComponents.year = 1000
        if let date = userCalendar.date(from: defaultDateComponents) {
            defaultDate = date
        }*/
        
        var report: [String] = [
            "## State of Parameter Estimation",
            estimationIntervals.reduce(into: "", { (entries, entry) in
                entries.append("\n ---------- \n \(dateFormatter.string(from: entry.startDate)), \(dateFormatter.string(from: entry.endDate)), \(entry.estimationIntervalType), \(String(describing: entry.enteredCarbs?.doubleValue(for: .gram()))), \(String(describing: entry.observedCarbs?.doubleValue(for: .gram()))), \(String(describing: entry.estimatedMultipliers?.insulinSensitivityMultiplier)), \(String(describing: entry.estimatedMultipliers?.carbRatioMultiplier)),\(String(describing: entry.estimatedMultipliers?.carbSensitivityMultiplier)), \(String(describing: entry.estimatedMultipliers?.basalMultiplier))"
            )}),
            "",
        ]
        report.append("")
        completion(report.joined(separator: "\n"))
    }
    
}

