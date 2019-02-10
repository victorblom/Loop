//
//  CarbCorrection.swift
//  Loop
//
//  Created by Dragan Maksimovic on 2/10/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit

// dm61 TO DO: clean-up getting necessary effects from LoopDataManager
// dm61 TO DO: remove force unwraps

/**
 Carb Correction description comments
 */
class CarbCorrection {
    
    /// Car correction variables: effects
    public var insulinEffect: [GlucoseEffect]?
    public var carbEffect: [GlucoseEffect]?
    public var carbEffectFutureFood: [GlucoseEffect]?
    public var glucoseMomentumEffect: [GlucoseEffect]?
    public var standardRetrospectiveGlucoseEffect: [GlucoseEffect]?
    public var retrospectiveGlucoseEffect: [GlucoseEffect]?
    public var zeroTempEffect: [GlucoseEffect]?
    
    public var suggestedCarbCorrection: Int?
    
    public var insulinCounteractionEffects: [GlucoseEffectVelocity]?
    
    public var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?
    
    public var glucose: GlucoseValue?
    
    /**
     Carb correction math parameters:
     - currentDiscrepancyGain: Standard retrospective correction gain
     - persistentDiscrepancyGain: Gain for persistent long-term modeling errors, must be greater than or equal to currentDiscrepancyGain
     - correctionTimeConstant: How fast integral effect accumulates in response to persistent errors
     - differentialGain: Differential effect gain
     - delta: Glucose sampling time interval (5 min)
     - maximumCorrectionEffectDuration: Maximum duration of the correction effect in glucose prediction
     */
    static let currentDiscrepancyGain: Double = 1.0
    static let persistentDiscrepancyGain: Double = 5.0
    static let correctionTimeConstant: TimeInterval = TimeInterval(minutes: 90.0)
    static let differentialGain: Double = 2.0
    static let delta: TimeInterval = TimeInterval(minutes: 5.0)
    static let maximumCorrectionEffectDuration: TimeInterval = TimeInterval(minutes: 240.0)
    
    /// Initialize computed integral retrospective correction parameters
    static let integralForget: Double = exp( -delta.minutes / correctionTimeConstant.minutes )
    static let integralGain: Double = ((1 - integralForget) / integralForget) *
        (persistentDiscrepancyGain - currentDiscrepancyGain)
    static let proportionalGain: Double = currentDiscrepancyGain - integralGain
    
    /// All math is performed with glucose expressed in mg/dL
    private let unit = HKUnit.milligramsPerDeciliter
    
    /// State variables reported in diagnostic issue report
    private var recentDiscrepancyValues: [Double] = []
    private var integralCorrectionEffectDuration: TimeInterval?
    private var proportionalCorrection: Double = 0.0
    private var integralCorrection: Double = 0.0
    private var differentialCorrection: Double = 0.0
    private var currentDate: Date = Date()
    private var ircStatus: String = "-"
    
    let carbCorrectionAbsorptionTime: TimeInterval
    
    let basalRateSchedule: BasalRateSchedule? = UserDefaults.appGroup.basalRateSchedule
    let carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup.carbRatioSchedule
    let insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup.insulinModelSettings
    let insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup.insulinSensitivitySchedule
    let settings: LoopSettings = UserDefaults.appGroup.loopSettings ?? LoopSettings()
    
    /**
     Initialize integral retrospective correction settings based on current values of user settings
     
     - Parameters:
     - settings: User settings
     - insulinSensitivity: User insulin sensitivity schedule
     - basalRates: User basal rate schedule
     
     - Returns: Integral Retrospective Correction customized with controller parameters and user settings
     */
    init(_ carbCorrectionAbsorptionTime: TimeInterval) {
        self.carbCorrectionAbsorptionTime = carbCorrectionAbsorptionTime
    }
    
    /**
     Calculates carb correction
     
     - Parameters:
     - fix glucose: Most recent glucose
     - fix retrospectiveGlucoseDiscrepanciesSummed: Timeline of past discepancies
     
     - Returns:
     - fix totalRetrospectiveCorrection: Overall glucose effect
     */
    
    // carb correction recommendation
    private func updateCarbCorrection() throws {
        
        guard glucoseMomentumEffect != nil else {
            throw LoopError.missingDataError(.momentumEffect)
        }
        
        guard carbEffect != nil else {
            throw LoopError.missingDataError(.carbEffect)
        }
        
        guard insulinEffect != nil else {
            throw LoopError.missingDataError(.insulinEffect)
        }
        
        guard zeroTempEffect != nil else {
            throw LoopError.invalidData(details: "zeroTempEffect not available, updateCarbCorrection failed")
        }
        
        let carbCorrectionThreshold: Int = 4 // do not bother with carb correction notifications below this value, only display badge
        let carbCorrectionFactor: Double = 1.1 // increase correction carbs by 10% to avoid repeated notifications in case the user accepts the recommendation as is
        
        var carbCorrection: Double = 0.0
        var timeToLow: TimeInterval?
        var timeToLowCandidate: TimeInterval?
        var missingCarbGrams: Int = 0
        
        do {
            var effects: PredictionInputEffect = [.carbs, .insulin, .momentum, .standardRetrospection, .zeroTemp]
            (carbCorrection, timeToLow) = try carbsRequired(effects: effects)
            NSLog("myLoop standard retrospection %4.2f in %4.2f minutes", carbCorrection, timeToLow?.minutes ?? -1.0)
            
            var carbs = 0.0
            effects = [.carbs, .insulin, .momentum, .retrospection, .zeroTemp]
            (carbs, timeToLowCandidate) = try carbsRequired(effects: effects)
            NSLog("myLoop integral retrospection %4.2f in %4.2f minutes", carbs, timeToLowCandidate?.minutes ?? -1.0)
            if carbs < carbCorrection {
                carbCorrection = carbs
                timeToLow = timeToLowCandidate
            }
            
            effects = [.futureCarbs, .insulin, .momentum, .zeroTemp]
            (carbs, timeToLowCandidate) = try carbsRequired(effects: effects)
            NSLog("myLoop insulin only %4.2f in %4.2f minutes", carbs, timeToLowCandidate?.minutes ?? -1.0)
            if carbs < carbCorrection {
                carbCorrection = carbs
                timeToLow = timeToLowCandidate
            }
            missingCarbGrams = Int(ceil(carbs))
            
        } catch {
            throw LoopError.invalidData(details: "predictedGlucose failed, updateCarbCorrection failed")
        }
        NSLog("myLoop carb correction final %4.2f in %4.2f minutes", carbCorrection, timeToLow?.minutes ?? -1.0)
        
        if carbCorrection > 0.0 {
            let carbCorrectionGrams = Int(ceil(carbCorrectionFactor * carbCorrection))
            suggestedCarbCorrection = carbCorrectionGrams
            if carbCorrectionGrams >= carbCorrectionThreshold {
                NotificationManager.sendCarbCorrectionNotification(carbCorrectionGrams, timeToLow)
            } else {
                NotificationManager.clearCarbCorrectionNotification()
                NotificationManager.sendCarbCorrectionNotificationBadge(carbCorrectionGrams)
            }
        } else {
            
            suggestedCarbCorrection = 0
            NotificationManager.clearCarbCorrectionNotification()
            
            if let lastDiscrepancy = retrospectiveGlucoseDiscrepanciesSummed?.last {
                let discrepancy = lastDiscrepancy.quantity.doubleValue(for: .milligramsPerDeciliter)
                NSLog("myLoop: discrepancy %4.2f", discrepancy)
                
                // counteraction
                let retrospectiveCounteraction = insulinCounteractionEffects!.filterDateRange(lastDiscrepancy.startDate, lastDiscrepancy.endDate)
                var counteraction: Double = 0
                for insulinCounteraction in retrospectiveCounteraction {
                    counteraction += insulinCounteraction.effect.quantity.doubleValue(for: .milligramsPerDeciliter)
                }
                NSLog("myLoop: counteraction %4.2f", counteraction)
                
                let expectedCarbEffect = counteraction - discrepancy
                let carbEffectThreshold = 1.0
                let warningThreshold = 0.5
                var carbAbsorbingFraction = 1.0
                if expectedCarbEffect > 1.0 {
                    carbAbsorbingFraction = counteraction / expectedCarbEffect
                }
                NSLog("myLoop: absorbing fraction %4.2f", 100 * carbAbsorbingFraction)
                if missingCarbGrams >= carbCorrectionThreshold && expectedCarbEffect > carbEffectThreshold && carbAbsorbingFraction < warningThreshold {
                    NSLog("myLoop: WARNING! (check carbs)")
                    // wip missing carbs warning notification
                    NotificationManager.sendCarbCorrectionNotification(0, nil)
                }
            }
            
        }
        
        return
    }
    
    // carb correction for effects
    private func carbsRequired(effects: PredictionInputEffect) throws -> (Double, TimeInterval?) {
        
        var carbCorrection: Double = 0.0
        var timeToLow: TimeInterval?
        
        // Get settings, otherwise throw error
        guard
            let insulinActionDuration = insulinModelSettings?.model.effectDuration,
            let suspendThreshold = settings.suspendThreshold?.quantity.doubleValue(for: .milligramsPerDeciliter),
            let sensitivity = insulinSensitivitySchedule?.averageValue(),
            let carbRatio = carbRatioSchedule?.averageValue()
            else {
                self.suggestedCarbCorrection = nil
                throw LoopError.invalidData(details: "Settings not available, updateCarbCorrection failed")
        }
        
        let carbCorrectionSkipInterval: TimeInterval = 0.4 * carbCorrectionAbsorptionTime // ignore dips below suspend threshold within the initial skip interval
        
        do {
            let predictedGlucoseForCarbCorrection = try predictGlucose(using: effects)
            if let currentDate = predictedGlucoseForCarbCorrection.first?.startDate {
                let startDate = currentDate.addingTimeInterval(carbCorrectionSkipInterval)
                let endDate = currentDate.addingTimeInterval(insulinActionDuration)
                let predictedLowGlucose = predictedGlucoseForCarbCorrection.filter{ $0.startDate >= startDate && $0.startDate <= endDate && $0.quantity.doubleValue(for: .milligramsPerDeciliter) < suspendThreshold}
                if predictedLowGlucose.count > 0 {
                    for glucose in predictedLowGlucose {
                        let glucoseTime = glucose.startDate.timeIntervalSince(currentDate)
                        let anticipatedAbsorbedFraction = min(1.0, glucoseTime.minutes / carbCorrectionAbsorptionTime.minutes)
                        let requiredCorrection = (( suspendThreshold - glucose.quantity.doubleValue(for: .milligramsPerDeciliter)) / anticipatedAbsorbedFraction) * carbRatio / sensitivity
                        if requiredCorrection > carbCorrection {
                            carbCorrection = requiredCorrection
                        }
                    }
                    if let lowGlucose = predictedGlucoseForCarbCorrection.first( where:
                        {$0.quantity.doubleValue(for: .milligramsPerDeciliter) < suspendThreshold} ) {
                        timeToLow = lowGlucose.startDate.timeIntervalSince(currentDate)
                    }
                }
            }
        }
        catch { throw LoopError.invalidData(details: "predictedGlucose failed, updateCarbCorrection failed")
        }
        
        return (carbCorrection, timeToLow)
    }

    /// - Throws: LoopError.missingDataError
    fileprivate func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
        
        guard let model = insulinModelSettings?.model else {
            throw LoopError.configurationError(.insulinModel)
        }
        
        guard let glucose = self.glucose else {
            throw LoopError.missingDataError(.glucose)
        }
        
        var momentum: [GlucoseEffect] = []
        var effects: [[GlucoseEffect]] = []
        
        if inputs.contains(.carbs), let carbEffect = self.carbEffect {
            effects.append(carbEffect)
        }
        
        if inputs.contains(.futureCarbs), let futureCarbEffect = self.carbEffectFutureFood {
            effects.append(futureCarbEffect)
        }
        
        if inputs.contains(.insulin), let insulinEffect = self.insulinEffect {
            effects.append(insulinEffect)
        }
        
        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }
        
        if inputs.contains(.retrospection) {
            effects.append(self.retrospectiveGlucoseEffect!)
        } else {
            if inputs.contains(.standardRetrospection) {
                effects.append(self.standardRetrospectiveGlucoseEffect!)
            }
        }
        
        if inputs.contains(.zeroTemp) {
            effects.append(self.zeroTempEffect!)
        }
        
        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)
        
        // Dosing requires prediction entries at least as long as the insulin model duration.
        // If our prediction is shorter than that, then extend it here.
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }
        
        return prediction
    }

}
