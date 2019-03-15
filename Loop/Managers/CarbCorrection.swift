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


/**
 Carb Correction description comments
 */
class CarbCorrection {
    
    /// Carb correction variables: effects
    public var insulinEffect: [GlucoseEffect]?
    public var carbEffect: [GlucoseEffect]?
    public var carbEffectFutureFood: [GlucoseEffect]?
    public var glucoseMomentumEffect: [GlucoseEffect]?
    public var zeroTempEffect: [GlucoseEffect]?
    public var retrospectiveGlucoseEffect: [GlucoseEffect]?
    public var insulinCounteractionEffects: [GlucoseEffectVelocity]?
    
    var suggestedCarbCorrection: Int?
    var glucose: GlucoseValue?
    
    /**
     Carb correction math parameters:
     -
     */
    private let carbCorrectionThreshold: Int = 3 // do not bother with carb correction notifications below this value, only display badge
    private let carbCorrectionFactor: Double = 1.1 // increase correction carbs by 10% to avoid repeated notifications in case the user accepts the recommendation as is
    private let expireCarbsThreshold: Double = 0.7 // absorption rate below this fraction of modeled carb absorption triggers warning about slow carb absorption
    private let carbCorrectionSkipFraction: Double = 0.4 // suggested carb correction calculated to bring bg above suspendThreshold after carbCorrectionSkipFraction of carbCorrectionAbsorptionTime
    private let snoozeTime: TimeInterval = .minutes(19)
    
    /// All math is performed with glucose expressed in mg/dL
    private let unit = HKUnit.milligramsPerDeciliter
    
    private let carbCorrectionAbsorptionTime: TimeInterval
    
    /// Variables for diagnostic report
    private var carbCorrectionStatus: String = "-"
    private var carbCorrection: Double = 0.0
    private var carbCorrectionExpiredCarbs: Double = 0.0
    private var carbCorrectionExcessInsulin: Double = 0.0
    private var timeToLow: TimeInterval = TimeInterval.minutes(0.0)
    private var timeToLowExpiredCarbs: TimeInterval = TimeInterval.minutes(0.0)
    private var timeToLowExcessInsulin: TimeInterval = TimeInterval.minutes(0.0)
    private var carbCorrectionNotification: CarbCorrectionNotification
    private var counteraction: Counteraction?
    private var modeledCarbEffectValue: Double?
    private var currentAbsorbingFraction: Double = 0.0
    private var averageAbsorbingFraction: Double = 0.0
    private var slowAbsorbingCheck: String = "No"
    private var excessInsulinAction: String = "No"
    private var usingRetrospection: String = "No"
    private var predictedGlucoseUnexpiredCarbs: [GlucoseValue] = []
    private var lastNotificationDate: Date
    private var timeSinceLastNotification: TimeInterval = TimeInterval.minutes(0.0)
    
    /**
     Initialize
     
     - Parameters:
     - settings: User settings
     - insulinSensitivity: User insulin sensitivity schedule
     
     - Returns: Integral Retrospective Correction customized with controller parameters and user settings
     */
    init(_ carbCorrectionAbsorptionTime: TimeInterval) {
        self.carbCorrectionAbsorptionTime = carbCorrectionAbsorptionTime
        self.carbCorrectionNotification.grams = 0
        self.carbCorrectionNotification.lowPredictedIn = .minutes(0.0)
        self.carbCorrectionNotification.gramsRemaining = 0
        self.carbCorrectionNotification.type = .noCorrection
        self.lastNotificationDate = Date().addingTimeInterval(-snoozeTime)
    }
    
    /**
     Calculates carb correction
     
     - Parameters:
     - glucose: Most recent glucose
     
     - Returns:
     - suggested carb correction, if needed
     */
    
    // carb correction recommendation
    public func updateCarbCorrection(_ glucose: GlucoseValue) throws -> Int? {

        NSLog("myLoop: +++ updateCarbCorrection +++")
        self.glucose = glucose
        suggestedCarbCorrection = nil
        
        guard glucoseMomentumEffect != nil else {
            NSLog("myLoop: ERROR momentum not available ")
            carbCorrectionStatus = "Error: momentum effects not available"
            throw LoopError.missingDataError(.momentumEffect)
        }
        
        guard carbEffect != nil else {
            NSLog("myLoop: ERROR carb effects not set ")
            carbCorrectionStatus = "Error: carb effects not available"
            throw LoopError.missingDataError(.carbEffect)
        }
        
        guard insulinEffect != nil else {
            NSLog("myLoop: ERROR insulin effects not set ")
            carbCorrectionStatus = "Error: insulin effects not available"
            throw LoopError.missingDataError(.insulinEffect)
        }
        
        guard zeroTempEffect != nil else {
            NSLog("myLoop: ERROR no zero temp effects ")
            carbCorrectionStatus = "Error: zero temp effects not available"
            throw LoopError.invalidData(details: "zeroTempEffect not available, updateCarbCorrection failed")
        }
        
        counteraction = recentInsulinCounteraction()
        guard let currentCounteraction = counteraction?.currentCounteraction, let averageCounteraction = counteraction?.averageCounteraction else {
            carbCorrectionStatus = "Error: calculation of insulin counteraction failed."
            return( suggestedCarbCorrection )
        }
        
        guard let modeledCarbEffect = modeledCarbAbsorption() else {
            carbCorrectionStatus = "Error: calculation of modeled carb absorption failed."
            return( suggestedCarbCorrection )
        }
        modeledCarbEffectValue = modeledCarbEffect
        
        carbCorrection = 0.0
        carbCorrectionExpiredCarbs = 0.0
        timeToLow = TimeInterval.minutes(0.0)
        timeToLowExpiredCarbs = TimeInterval.minutes(0.0)
        
        var useRetrospection: Bool = false
        usingRetrospection = "No"
        if let retroLast = retrospectiveGlucoseEffect?.last?.quantity.doubleValue(for: unit), let retroFirst = retrospectiveGlucoseEffect?.first?.quantity.doubleValue(for: unit) {
            if retroLast > retroFirst {
                useRetrospection = true
                usingRetrospection = "Yes"
            }
        } else {
            carbCorrectionStatus = "Error: retrospective glucose effects not available"
            throw LoopError.invalidData(details: "Could not compute carbs required, updateCarbCorrection failed")
        }
        
        var effects: PredictionInputEffect
        if useRetrospection {
            effects = [.carbs, .insulin, .momentum, .zeroTemp, .retrospection]
        } else {
            effects = [.carbs, .insulin, .momentum, .zeroTemp]
        }
        do {
            (carbCorrection, timeToLow) = try carbsRequired(effects)
            NSLog("myLoop correction: %4.2f g in %4.2f minutes", carbCorrection, timeToLow.minutes)
        } catch {
            carbCorrectionStatus = "Error: glucose prediction failed with effects: \(effects)."
            throw LoopError.invalidData(details: "Could not compute carbs required, updateCarbCorrection failed")
        }
        
        slowAbsorbingCheck = "No"
        excessInsulinAction = "No"
        if modeledCarbEffect > 0.0 {
            currentAbsorbingFraction = currentCounteraction / modeledCarbEffect
            averageAbsorbingFraction = averageCounteraction / modeledCarbEffect
            NSLog("myLoop: current absorbing fraction = %4.2f", currentAbsorbingFraction)
            NSLog("myLoop: average absorbing fraction = %4.2f", averageAbsorbingFraction)
            if (currentAbsorbingFraction < 0.5 * expireCarbsThreshold && averageAbsorbingFraction < expireCarbsThreshold) {
                slowAbsorbingCheck = "Yes"
                if useRetrospection {
                    effects = [.unexpiredCarbs, .insulin, .momentum, .zeroTemp, .retrospection]
                } else {
                    effects = [.unexpiredCarbs, .insulin, .momentum, .zeroTemp]
                }
                do {
                    (carbCorrectionExpiredCarbs, timeToLowExpiredCarbs) = try carbsRequired(effects)
                } catch {
                    carbCorrectionStatus = "Error: glucose prediction failed with effects: \(effects)."
                    throw LoopError.invalidData(details: "Could not compute carbs required when past carbs expired, updateCarbCorrection failed")
                }
                NSLog("myLoop expired carb warning: %4.2f g in %4.2f minutes", carbCorrectionExpiredCarbs, timeToLowExpiredCarbs.minutes)
            }
        } else {
            currentAbsorbingFraction = 0.0
            averageAbsorbingFraction = 0.0
            if (averageCounteraction < 0.0  && currentCounteraction < averageCounteraction  && carbCorrection == 0) {
                excessInsulinAction = "Yes"
                usingRetrospection = "Yes"
                effects = [.carbs, .insulin, .momentum, .retrospection, .zeroTemp]
                do {
                    (carbCorrectionExcessInsulin, timeToLowExcessInsulin) = try carbsRequired(effects)
                } catch {
                    carbCorrectionStatus = "Error: glucose prediction failed with effects: \(effects)."
                    throw LoopError.invalidData(details: "Could not compute carbs required when excess insulin detected, updateCarbCorrection failed")
                }
                NSLog("myLoop Excess insulin action detected, correction: %4.2f g in %4.2f minutes", carbCorrectionExcessInsulin, timeToLowExcessInsulin.minutes)
                carbCorrection = carbCorrectionExcessInsulin
                timeToLow = timeToLowExcessInsulin
            }
        }
        
        carbCorrectionNotification.grams = Int(ceil(carbCorrectionFactor * carbCorrection))
        suggestedCarbCorrection = carbCorrectionNotification.grams
        carbCorrectionNotification.lowPredictedIn = timeToLow
        NSLog("myLoop correction %d g in %4.2f minutes", carbCorrectionNotification.grams, timeToLow.minutes)
        carbCorrectionNotification.gramsRemaining = Int(ceil(carbCorrectionFactor * carbCorrectionExpiredCarbs))
        NSLog("myLoop warning %d g in %4.2f minutes", carbCorrectionNotification.gramsRemaining, timeToLowExpiredCarbs.minutes)
        carbCorrectionNotification.type = .noCorrection
        
        carbCorrectionStatus = "Successfully completed."
        
        // for diagnostic only
        effects = [.unexpiredCarbs]
        predictedGlucoseUnexpiredCarbs = try predictGlucose(using: effects)
        
        timeSinceLastNotification = -lastNotificationDate.timeIntervalSinceNow
        
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
            if timeSinceLastNotification > snoozeTime {
                NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
                    lastNotificationDate = Date()
            } else {
                NotificationManager.sendCarbCorrectionNotificationBadge(carbCorrectionNotification.grams)
            }
            return( suggestedCarbCorrection )
        }
        
        // warning slow absorbing carbs
        if ( carbCorrectionNotification.grams < carbCorrectionThreshold && carbCorrectionNotification.gramsRemaining >= carbCorrectionThreshold) {
            carbCorrectionNotification.type = .warning
            if timeSinceLastNotification > snoozeTime {
                NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
                lastNotificationDate = Date()
            }
            return( suggestedCarbCorrection )
        }

        // correction notification and warning
        if ( carbCorrectionNotification.grams >= carbCorrectionThreshold && carbCorrectionNotification.gramsRemaining >= carbCorrectionThreshold) {
            carbCorrectionNotification.type = .correctionWarning
            if timeSinceLastNotification > snoozeTime {
                NotificationManager.sendCarbCorrectionNotification(carbCorrectionNotification)
                lastNotificationDate = Date()
            } else {
                NotificationManager.sendCarbCorrectionNotificationBadge(carbCorrectionNotification.grams)
            }
            return( suggestedCarbCorrection )
        }
        
        // we should never get to this point
        return( suggestedCarbCorrection )
    }
    
    // suggested carb correction for glucose prediction based on effects
    private func carbsRequired(_ effects: PredictionInputEffect) throws -> (Double, TimeInterval) {
        
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
        
        if inputs.contains(.retrospection), let retrospectionEffect = self.retrospectiveGlucoseEffect {
            effects.append(retrospectionEffect)
        }
        
        if inputs.contains(.momentum), let momentumEffect = self.glucoseMomentumEffect {
            momentum = momentumEffect
        }
        
        if inputs.contains(.zeroTemp) {
            effects.append(self.zeroTempEffect!)
        }
        
        var prediction = LoopMath.predictGlucose(startingAt: glucose, momentum: momentum, effects: effects)
        
        let finalDate = glucose.startDate.addingTimeInterval(model.effectDuration)
        if let last = prediction.last, last.startDate < finalDate {
            prediction.append(PredictedGlucoseValue(startDate: finalDate, quantity: last.quantity))
        }
        
        return prediction
    }
    
    // get modeled carb absorption
    fileprivate func modeledCarbAbsorption() -> Double? {
        let effects: PredictionInputEffect = [.carbs]
        var predictedGlucose: [GlucoseValue]?
        var modeledCarbEffect: Double?
        
        do {
            predictedGlucose = try predictGlucose(using: effects)
        }
        catch {
            return( modeledCarbEffect )
        }
        
        guard let modeledCarbOnlyGlucose = predictedGlucose else {
            return( modeledCarbEffect )
        }
        
        if modeledCarbOnlyGlucose.count < 2 {
            return( modeledCarbEffect )
        }
        
        if modeledCarbOnlyGlucose.count == 2 {
            let glucose1 = modeledCarbOnlyGlucose[0].quantity.doubleValue(for: unit)
            let glucose2 = modeledCarbOnlyGlucose[1].quantity.doubleValue(for: unit)
            modeledCarbEffect = glucose2 - glucose1
        } else {
            let glucose1 = modeledCarbOnlyGlucose[1].quantity.doubleValue(for: unit)
            let glucose2 = modeledCarbOnlyGlucose[2].quantity.doubleValue(for: unit)
            modeledCarbEffect = glucose2 - glucose1
        }
        
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

extension CarbCorrection {
    /// Generates a diagnostic report about the current state
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateDiagnosticReport(_ completion: @escaping (_ report: String) -> Void) {
        var report: [String] = [
            "## Carb Correction Notification",
            "",
            "Status: \(carbCorrectionStatus)",
            "Current glucose [mg/dL]: \(String(describing: glucose?.quantity.doubleValue(for: unit)))",
            "Current glucose date: \(String(describing: glucose?.startDate))",
            "timeSinceLastNotification [min]: \(timeSinceLastNotification.minutes)",
            "Suggested carb correction [g]: \(String(describing: carbCorrectionNotification.grams))",
            "Low predicted in [min]: \(String(describing: carbCorrectionNotification.lowPredictedIn.minutes))",
            "Slow absorbing carbs remaining [g]: \(String(describing: carbCorrectionNotification.gramsRemaining))",
            "Carb correction type: \(String(describing: carbCorrectionNotification.type))",
            "Recent insulin counteraction [mg/dL/5min]: \(String(describing: counteraction))",
            "Modeled carb effect [mg/dL/5min]: \(String(describing: modeledCarbEffectValue))",
            "currentAbsorbingFraction: \(currentAbsorbingFraction)",
            "averageAbsorbingFraction: \(averageAbsorbingFraction)",
            "Check slow carb absorption: \(slowAbsorbingCheck)",
            "Check excess insulin action: \(excessInsulinAction)",
            "Using retrospection: \(usingRetrospection)",
            "carbCorrectionThreshold [g]: \(carbCorrectionThreshold)",
            "expireCarbsThreshold fraction: \(expireCarbsThreshold)",
            "carbCorrectionSkipFraction: \(carbCorrectionSkipFraction)",
            "carbCorrectionAbsorptionTime [min]: \(carbCorrectionAbsorptionTime.minutes)",
            "snoozeTime [min]: \(snoozeTime.minutes)",
            "----------------------------",
            "Predicted glucose from unexpired carbs: \(String(describing: predictedGlucoseUnexpiredCarbs))"
        ]
        report.append("")
        completion(report.joined(separator: "\n"))
    }
    
}
