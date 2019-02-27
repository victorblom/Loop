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
    public var insulinCounteractionEffects: [GlucoseEffectVelocity]?

    public var retrospectiveGlucoseDiscrepancies: [GlucoseEffect]?
    public var retrospectiveGlucoseDiscrepanciesSummed: [GlucoseChange]?
    
    var suggestedCarbCorrection: Int?
    var glucose: GlucoseValue?
    
    /**
     Carb correction math parameters:
     -
     */
    let carbCorrectionSkipFraction: Double = 0.4
    let delta: TimeInterval = TimeInterval(minutes: 5.0)
    let carbCorrectionThreshold: Int = 2 // do not bother with carb correction notifications below this value, only display badge
    let carbCorrectionFactor: Double = 1.1 // increase correction carbs by 10% to avoid repeated notifications in case the user accepts the recommendation as is
    let expireCarbsThreshold: Double = 0.25 // absorption rate below this fraction of modeled carb absorption triggers expiration of past carbs
    
    /// All math is performed with glucose expressed in mg/dL
    private let unit = HKUnit.milligramsPerDeciliter
    
    /// State variables reported in diagnostic issue report
    private var carbCorrectionStatus: String = "-"
    
    let carbCorrectionAbsorptionTime: TimeInterval
    
    /**
     Initialize
     
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
     
     - Returns:
     - suggested carb correction, if needed
     */
    
    // carb correction recommendation
    public func updateCarbCorrection(_ glucose: GlucoseValue) throws -> Int? {

        NSLog("myLoop: +++ CarbCorrectionClass +++")
        self.glucose = glucose
        suggestedCarbCorrection = nil
        
        guard glucoseMomentumEffect != nil else {
            NSLog("myLoop: ERROR momentum not set ")
            throw LoopError.missingDataError(.momentumEffect)
        }
        
        guard carbEffect != nil else {
            NSLog("myLoop: ERROR carb effects not set ")
            throw LoopError.missingDataError(.carbEffect)
        }
        
        guard insulinEffect != nil else {
            NSLog("myLoop: ERROR insulin effects not set ")
            throw LoopError.missingDataError(.insulinEffect)
        }
        
        guard zeroTempEffect != nil else {
            NSLog("myLoop: ERROR no zero temp effects ")
            throw LoopError.invalidData(details: "zeroTempEffect not available, updateCarbCorrection failed")
        }
        
        let counteraction = recentInsulinCounteraction()
        guard let currentCounteraction = counteraction.currentCounteraction, let averageCounteraction = counteraction.averageCounteraction else {
            return( suggestedCarbCorrection )
        }
        
        guard let modeledCarbEffect = modeledCarbAbsorption() else {
            return( suggestedCarbCorrection )
        }
        
        var carbCorrection: Double = 0.0
        var carbCorrectionExpiredCarbs: Double = 0.0
        var timeToLow: TimeInterval = TimeInterval.minutes(0.0)
        var timeToLowExpiredCarbs: TimeInterval = TimeInterval.minutes(0.0)
        
        var carbCorrectionNotification: CarbCorrectionNotification
        
        var effects: PredictionInputEffect = [.carbs, .insulin, .momentum, .zeroTemp]
        do {
            (carbCorrection, timeToLow) = try carbsRequired(effects: effects)
        } catch {
            throw LoopError.invalidData(details: "Could not compute carbs required, updateCarbCorrection failed")
        }
        
        if modeledCarbEffect > 0.0 {
            let currentAbsorbingFraction = currentCounteraction / modeledCarbEffect
            let averageAbsorbingFraction = averageCounteraction / modeledCarbEffect
            NSLog("myLoop: current absorbing fraction = %4.2f", currentAbsorbingFraction)
            NSLog("myLoop: average absorbing fraction = %4.2f", averageAbsorbingFraction)
            if (currentAbsorbingFraction < expireCarbsThreshold && averageAbsorbingFraction < 2 * expireCarbsThreshold) {
                effects = [.unexpiredCarbs, .insulin, .momentum, .zeroTemp]
                do {
                    (carbCorrectionExpiredCarbs, timeToLowExpiredCarbs) = try carbsRequired(effects: effects)
                } catch {
                    throw LoopError.invalidData(details: "Could not compute carbs required when past carbs expired, updateCarbCorrection failed")
                }
                NSLog("myLoop: carb correction with expired carbs = %4.2f", carbCorrectionExpiredCarbs)
            }
        }
        
        carbCorrectionNotification.grams = Int(ceil(carbCorrectionFactor * carbCorrection))
        suggestedCarbCorrection = carbCorrectionNotification.grams
        carbCorrectionNotification.lowPredictedIn = timeToLow
        NSLog("myLoop correction %d in %4.2f minutes", carbCorrectionNotification.grams, timeToLow.minutes)
        carbCorrectionNotification.gramsRemaining = Int(ceil(carbCorrectionFactor * carbCorrectionExpiredCarbs))
        NSLog("myLoop warning %d in %4.2f minutes", carbCorrectionNotification.gramsRemaining, timeToLowExpiredCarbs.minutes)
        carbCorrectionNotification.type = .noCorrection
        
        // no correction needed
        if ( carbCorrectionNotification.grams == 0 && carbCorrectionNotification.gramsRemaining < carbCorrectionThreshold) {
            NotificationManager.clearCarbCorrectionNotification()
            return( suggestedCarbCorrection )
        }
        
        // badge correction only
        if (carbCorrectionNotification.grams > carbCorrectionThreshold &&
            carbCorrectionNotification.grams < carbCorrectionThreshold &&
            carbCorrectionNotification.gramsRemaining < carbCorrectionThreshold) {
            carbCorrectionNotification.type = .correction
            NotificationManager.clearCarbCorrectionNotification()
            NotificationManager.sendCarbCorrectionNotificationBadge(carbCorrectionNotification.grams)
            return( suggestedCarbCorrection )
        }
        
        // carb correction notification, no warning
        if ( carbCorrectionNotification.grams >= carbCorrectionThreshold && carbCorrectionNotification.gramsRemaining < carbCorrectionThreshold) {
            carbCorrectionNotification.type = .correction
            NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
            return( suggestedCarbCorrection )
        }
        
        // warning slow absorbing carbs
        if ( carbCorrectionNotification.grams < carbCorrectionThreshold && carbCorrectionNotification.gramsRemaining >= carbCorrectionThreshold) {
            carbCorrectionNotification.type = .warning
            NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
            return( suggestedCarbCorrection )
        }

        // correction notification and warning
        if ( carbCorrectionNotification.grams >= carbCorrectionThreshold && carbCorrectionNotification.gramsRemaining >= carbCorrectionThreshold) {
            carbCorrectionNotification.type = .correctionWarning
            NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
            return( suggestedCarbCorrection )
        }
        
        // we should never get to this point
        return( suggestedCarbCorrection )
    }
    
    // suggested carb correction for glucose prediction based on effects
    private func carbsRequired(effects: PredictionInputEffect) throws -> (Double, TimeInterval) {
        
        var carbCorrection: Double = 0.0
        var timeToLow: TimeInterval = TimeInterval.minutes(0.0)
        
        let carbRatioSchedule: CarbRatioSchedule? = UserDefaults.appGroup.carbRatioSchedule
        let insulinSensitivitySchedule: InsulinSensitivitySchedule? = UserDefaults.appGroup.insulinSensitivitySchedule
        let insulinModelSettings: InsulinModelSettings? = UserDefaults.appGroup.insulinModelSettings
        let settings: LoopSettings = UserDefaults.appGroup.loopSettings ?? LoopSettings()
        
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
        
        let carbCorrectionSkipInterval: TimeInterval = self.carbCorrectionSkipFraction * carbCorrectionAbsorptionTime // ignore dips below suspend threshold within the initial skip interval
        
        let predictedGlucoseForCarbCorrection = try predictGlucose(using: effects)
        guard let currentDate = predictedGlucoseForCarbCorrection.first?.startDate else {
            throw LoopError.invalidData(details: "Glucose prediction failed, updateCarbCorrection failed")
        }
        
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

        return (carbCorrection, timeToLow)
    }

    /// - Throws: LoopError.missingDataError
    fileprivate func predictGlucose(using inputs: PredictionInputEffect) throws -> [GlucoseValue] {
        
        guard let model = UserDefaults.appGroup.insulinModelSettings?.model else {
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
        
        if inputs.contains(.unexpiredCarbs), let futureCarbEffect = self.carbEffectFutureFood {
            effects.append(futureCarbEffect)
        }
        
        if inputs.contains(.insulin), let insulinEffect = self.insulinEffect {
            effects.append(insulinEffect)
        }
        
        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }
        
        if inputs.contains(.zeroTemp) {
            effects.append(self.zeroTempEffect!)
        }
        
        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)
        
        // If prediction is shorter than insulin model duration, extend it here.
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }
        
        return prediction
    }
    
    // get modeled carb absorption
    fileprivate func modeledCarbAbsorption() -> Double? {
        let effects: PredictionInputEffect = [.carbs]

        var modeledCarbOnlyGlucose: [GlucoseValue]?
        var modeledCarbEffect: Double?
        
        do {
            modeledCarbOnlyGlucose = try predictGlucose(using: effects)
        }
        catch {
            return( modeledCarbEffect )
        }
        
        guard let predictionCount = modeledCarbOnlyGlucose?.count else {
            return( modeledCarbEffect )
        }
        
        guard predictionCount >= 3 else {
            return( modeledCarbEffect )
        }
        
        guard let glucose1 = modeledCarbOnlyGlucose?[1].quantity.doubleValue(for: unit), let glucose2 = modeledCarbOnlyGlucose?[2].quantity.doubleValue(for: unit) else {
            return( modeledCarbEffect )
        }
        
        modeledCarbEffect = glucose2 - glucose1
        NSLog("myLoop: modeled carb effect %4.2f", modeledCarbEffect!)
        
        return( modeledCarbEffect )
    }
  
    // counteraction
    fileprivate func recentInsulinCounteraction() -> Counteraction {
        
        var counteraction: Counteraction
        
        guard let latestGlucoseDate = glucose?.startDate else {
            return( counteraction )
        }
        
        guard let counterActions = insulinCounteractionEffects?.filterDateRange(latestGlucoseDate.addingTimeInterval(.minutes(-20)), latestGlucoseDate) else {
            return( counteraction )
        }
        
        let counteractionValues = counterActions.map( { $0.effect.quantity.doubleValue(for: unit) } )
        let counteractionTimes = counterActions.map( { $0.effect.startDate.timeIntervalSince(latestGlucoseDate).minutes } )
        for counteractionValue in counteractionValues {
            NSLog("myLoop: counteraction %4.2f", counteractionValue)
        }
        for counteractionTime in counteractionTimes {
            NSLog("myLoop: counteraction time %4.2f", counteractionTime)
        }

        guard counteractionValues.count > 2 else {
            return( counteraction )
        }
        
        let insulinCounteractionFit = linearRegression(counteractionTimes, counteractionValues)
        counteraction.currentCounteraction = insulinCounteractionFit(0.0)
        counteraction.averageCounteraction = average( counteractionValues )
        NSLog("myLoop: current counteraction: %4.2f", counteraction.currentCounteraction!)
        NSLog("myLoop: average counteraction: %4.2f", counteraction.averageCounteraction!)
        
        return( counteraction )
    }
    
    fileprivate func average(_ input: [Double]) -> Double {
        return input.reduce(0, +) / Double(input.count)
    }
    
    fileprivate func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        return zip(a,b).map(*)
    }
    
    fileprivate func linearRegression(_ xs: [Double], _ ys: [Double]) -> (Double) -> Double {
        let sum1 = average(multiply(ys, xs)) - average(xs) * average(ys)
        let sum2 = average(multiply(xs, xs)) - pow(average(xs), 2)
        let slope = sum1 / sum2
        let intercept = average(ys) - slope * average(xs)
        return { x in intercept + slope * x }
    }

}

struct CarbCorrectionNotificationOption: OptionSet {
    let rawValue: Int
    
    static let noCorrection = CarbCorrectionNotificationOption(rawValue: 1 << 0)
    static let correction = CarbCorrectionNotificationOption(rawValue: 1 << 1)
    static let warning = CarbCorrectionNotificationOption(rawValue: 1 << 2)
    static let correctionWarning = CarbCorrectionNotificationOption(rawValue: 1 << 3)
}

typealias CarbCorrectionNotification = (grams: Int, lowPredictedIn: TimeInterval, gramsRemaining: Int, type: CarbCorrectionNotificationOption)

typealias Counteraction = (currentCounteraction: Double?, averageCounteraction: Double?)
