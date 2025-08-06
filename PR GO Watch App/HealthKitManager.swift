import Foundation
import HealthKit
import Combine
import SwiftData

class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()
    let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var heartRate: Double = 0
    @Published var lastInsulinDose: Double = 0
    @Published var lastCarbAmount: Double = 0
    @Published var lastGlucose: Double = 0
    @Published var glucoseTrend: Double = 0

    private var heartRateQuery: HKObserverQuery?
    private var insulinQuery: HKObserverQuery?
    private var carbQuery: HKObserverQuery?
    private var glucoseQuery: HKObserverQuery?
    
    // Cache for recent readings to calculate trends
    private var recentGlucoseReadings: [(value: Double, date: Date)] = []
    private var recentHeartRates: [(value: Double, date: Date)] = []

    init() {
        checkAuthorizationStatus()
    }

    func checkAuthorizationStatus() {
        guard HKHealthStore.isHealthDataAvailable() else {
            self.isAuthorized = false
            return
        }

        let typesToRead = getHealthKitTypes()

        healthStore.getRequestStatusForAuthorization(toShare: [], read: typesToRead) { (status, error) in
            DispatchQueue.main.async {
                self.isAuthorized = (status == .unnecessary)
            }
        }
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            return
        }

        let typesToRead = getHealthKitTypes()

        healthStore.requestAuthorization(toShare: [], read: typesToRead) { (success, error) in
            DispatchQueue.main.async {
                self.isAuthorized = success
                if success {
                    self.startAllHealthQueries()
                }
            }
        }
    }
    
    private func getHealthKitTypes() -> Set<HKObjectType> {
        return [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .insulinDelivery)!,
            HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates)!,
            HKObjectType.quantityType(forIdentifier: .bloodGlucose)!
        ]
    }
    
    private func startAllHealthQueries() {
        print("🔄 Starting comprehensive health queries on Watch")
        startHeartRateQuery()
        startInsulinQuery()
        startCarbQuery()
        startGlucoseQuery()
    }

    func startHeartRateQuery() {
        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!

        if let query = self.heartRateQuery {
            healthStore.stop(query)
        }

        let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] (query, completionHandler, error) in
            self?.fetchLatestHeartRate(completion: {
                completionHandler()
            })
        }
        
        self.heartRateQuery = query
        healthStore.execute(query)
    }

    func fetchLatestHeartRate(completion: @escaping () -> Void) {
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        
        let query = HKSampleQuery(sampleType: heartRateType, predicate: nil, limit: 5, sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            DispatchQueue.main.async {
                guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                    completion()
                    return
                }
                
                let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
                let latestSample = samples[0]
                self.heartRate = latestSample.quantity.doubleValue(for: heartRateUnit)
                
                // Store recent readings for trend calculation
                self.recentHeartRates = samples.map { sample in
                    (value: sample.quantity.doubleValue(for: heartRateUnit), date: sample.startDate)
                }
                
                print("❤️ Fetched Heart Rate: \(self.heartRate) bpm (\(samples.count) samples)")
                completion()
            }
        }
        
        healthStore.execute(query)
    }
    
    // MARK: - Insulin Query Methods
    func startInsulinQuery() {
        guard let insulinType = HKObjectType.quantityType(forIdentifier: .insulinDelivery) else { return }
        
        if let query = self.insulinQuery {
            healthStore.stop(query)
        }
        
        let query = HKObserverQuery(sampleType: insulinType, predicate: nil) { [weak self] (query, completionHandler, error) in
            self?.fetchLatestInsulin(completion: {
                completionHandler()
            })
        }
        
        self.insulinQuery = query
        healthStore.execute(query)
    }
    
    func fetchLatestInsulin(completion: @escaping () -> Void) {
        guard let insulinType = HKQuantityType.quantityType(forIdentifier: .insulinDelivery) else {
            completion()
            return
        }
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.date(byAdding: .hour, value: -6, to: Date()), end: Date(), options: .strictStartDate)
        
        let query = HKSampleQuery(sampleType: insulinType, predicate: predicate, limit: 10, sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            DispatchQueue.main.async {
                guard let samples = samples as? [HKQuantitySample] else {
                    completion()
                    return
                }
                
                let insulinUnit = HKUnit.internationalUnit()
                self.lastInsulinDose = samples.first?.quantity.doubleValue(for: insulinUnit) ?? 0.0
                
                print("💉 Fetched Insulin: \(self.lastInsulinDose) units (\(samples.count) samples in 6h)")
                completion()
            }
        }
        
        healthStore.execute(query)
    }
    
    // MARK: - Carb Query Methods
    func startCarbQuery() {
        guard let carbType = HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates) else { return }
        
        if let query = self.carbQuery {
            healthStore.stop(query)
        }
        
        let query = HKObserverQuery(sampleType: carbType, predicate: nil) { [weak self] (query, completionHandler, error) in
            self?.fetchLatestCarbs(completion: {
                completionHandler()
            })
        }
        
        self.carbQuery = query
        healthStore.execute(query)
    }
    
    func fetchLatestCarbs(completion: @escaping () -> Void) {
        guard let carbType = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates) else {
            completion()
            return
        }
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.date(byAdding: .hour, value: -4, to: Date()), end: Date(), options: .strictStartDate)
        
        let query = HKSampleQuery(sampleType: carbType, predicate: predicate, limit: 10, sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            DispatchQueue.main.async {
                guard let samples = samples as? [HKQuantitySample] else {
                    completion()
                    return
                }
                
                let carbUnit = HKUnit.gram()
                self.lastCarbAmount = samples.first?.quantity.doubleValue(for: carbUnit) ?? 0.0
                
                print("🍞 Fetched Carbs: \(self.lastCarbAmount) grams (\(samples.count) samples in 4h)")
                completion()
            }
        }
        
        healthStore.execute(query)
    }
    
    // MARK: - Glucose Query Methods
    func startGlucoseQuery() {
        guard let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else { return }
        
        if let query = self.glucoseQuery {
            healthStore.stop(query)
        }
        
        let query = HKObserverQuery(sampleType: glucoseType, predicate: nil) { [weak self] (query, completionHandler, error) in
            self?.fetchLatestGlucose(completion: {
                completionHandler()
            })
        }
        
        self.glucoseQuery = query
        healthStore.execute(query)
    }
    
    func fetchLatestGlucose(completion: @escaping () -> Void) {
        guard let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else {
            completion()
            return
        }
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.date(byAdding: .hour, value: -2, to: Date()), end: Date(), options: .strictStartDate)
        
        let query = HKSampleQuery(sampleType: glucoseType, predicate: predicate, limit: 10, sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            DispatchQueue.main.async {
                guard let samples = samples as? [HKQuantitySample] else {
                    completion()
                    return
                }
                
                let glucoseUnit = HKUnit.init(from: "mg/dL")
                if let latestSample = samples.first {
                    self.lastGlucose = latestSample.quantity.doubleValue(for: glucoseUnit)
                    
                    // Store recent readings for trend calculation
                    self.recentGlucoseReadings = samples.map { sample in
                        (value: sample.quantity.doubleValue(for: glucoseUnit), date: sample.startDate)
                    }
                    
                    // Calculate glucose trend
                    self.calculateGlucoseTrend()
                }
                
                print("🩸 Fetched Glucose: \(self.lastGlucose) mg/dL (\(samples.count) samples, trend: \(self.glucoseTrend))")
                completion()
            }
        }
        
        healthStore.execute(query)
    }
    
    // MARK: - Trend Calculations
    private func calculateGlucoseTrend() {
        guard recentGlucoseReadings.count >= 2 else {
            glucoseTrend = 0.0
            return
        }
        
        let sortedReadings = recentGlucoseReadings.sorted { $0.date < $1.date }
        let latest = sortedReadings.last!
        let previous = sortedReadings[sortedReadings.count - 2]
        
        let timeDiff = latest.date.timeIntervalSince(previous.date) / 60.0 // Minutes
        guard timeDiff > 0 else {
            glucoseTrend = 0.0
            return
        }
        
        // mg/dL per minute
        glucoseTrend = (latest.value - previous.value) / timeDiff
    }
    
    // MARK: - Data Access Methods for Background Predictions
    func getComprehensiveHealthData() -> (heartRate: Double, insulin: Double, carbs: Double, glucose: Double, glucoseTrend: Double) {
        return (heartRate: heartRate, insulin: lastInsulinDose, carbs: lastCarbAmount, glucose: lastGlucose, glucoseTrend: glucoseTrend)
    }
}
