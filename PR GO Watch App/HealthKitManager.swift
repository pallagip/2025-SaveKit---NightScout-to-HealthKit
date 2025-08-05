import Foundation
import HealthKit
import Combine

class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()
    let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var heartRate: Double = 0

    private var heartRateQuery: HKObserverQuery?

    init() {
        checkAuthorizationStatus()
    }

    func checkAuthorizationStatus() {
        guard HKHealthStore.isHealthDataAvailable() else {
            self.isAuthorized = false
            return
        }

        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!

        healthStore.getRequestStatusForAuthorization(toShare: [], read: [heartRateType]) { (status, error) in
            DispatchQueue.main.async {
                self.isAuthorized = (status == .unnecessary)
            }
        }
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            return
        }

        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!
        ]

        healthStore.requestAuthorization(toShare: [], read: typesToRead) { (success, error) in
            DispatchQueue.main.async {
                self.isAuthorized = success
                if success {
                    self.startHeartRateQuery()
                }
            }
        }
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
        
        let query = HKSampleQuery(sampleType: heartRateType, predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { (query, samples, error) in
            DispatchQueue.main.async {
                guard let sample = samples?.first as? HKQuantitySample else {
                    completion()
                    return
                }
                
                let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
                self.heartRate = sample.quantity.doubleValue(for: heartRateUnit)
                print("❤️ Fetched Heart Rate: \(self.heartRate) bpm")
                completion()
            }
        }
        
        healthStore.execute(query)
    }
}
