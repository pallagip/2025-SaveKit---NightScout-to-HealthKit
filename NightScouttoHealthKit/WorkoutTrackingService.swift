import Foundation
import HealthKit
import SwiftData

@MainActor class WorkoutTrackingService {
    private let healthStore = HKHealthStore()
    
    enum WorkoutTrackingError: Error {
        case healthKitNotAvailable
        case noWorkoutFound
        case dataFetchFailed(Error)
    }
    
    /// Fetches the last walking or running workout within the specified time window
    /// - Parameter hoursBack: Maximum hours to look back (default: 5 hours)
    /// - Returns: WorkoutData containing workout information and calories burned
    func fetchLastWalkingOrRunningWorkout(hoursBack: Double = 5.0) async throws -> (workout: HKWorkout, calories: Double)? {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WorkoutTrackingError.healthKitNotAvailable
        }
        
        let workoutType = HKObjectType.workoutType()
        let caloriesType = HKQuantityType(.activeEnergyBurned)
        
        // Request authorization if needed
        let typesToRead: Set<HKObjectType> = [workoutType, caloriesType]
        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
        
        // Create time predicate for the last 5 hours
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .hour, value: -Int(hoursBack), to: endDate)!
        let timePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictEndDate)
        
        // Create workout type predicate for walking and running
        let walkingPredicate = HKQuery.predicateForWorkouts(with: .walking)
        let runningPredicate = HKQuery.predicateForWorkouts(with: .running)
        let workoutTypePredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [walkingPredicate, runningPredicate])
        
        // Combine predicates
        let combinedPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [timePredicate, workoutTypePredicate])
        
        // Create sort descriptor to get the most recent workout
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: combinedPredicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { query, samples, error in
                
                if let error = error {
                    continuation.resume(throwing: WorkoutTrackingError.dataFetchFailed(error))
                    return
                }
                
                guard let workout = samples?.first as? HKWorkout else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Fetch calories for this specific workout
                Task {
                    do {
                        let calories = try await self.fetchCaloriesForWorkout(workout)
                        continuation.resume(returning: (workout: workout, calories: calories))
                    } catch {
                        print("⚠️ Failed to fetch calories for workout: \(error)")
                        // Return workout with 0 calories if calorie fetch fails
                        continuation.resume(returning: (workout: workout, calories: 0.0))
                    }
                }
            }
            
            healthStore.execute(query)
        }
    }
    
    /// Fetches active calories burned for a specific workout
    private func fetchCaloriesForWorkout(_ workout: HKWorkout) async throws -> Double {
        let caloriesType = HKQuantityType(.activeEnergyBurned)
        
        // Create predicate for samples that overlap with the workout timeframe
        let workoutPredicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: caloriesType,
                predicate: workoutPredicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { query, samples, error in
                
                if let error = error {
                    continuation.resume(throwing: WorkoutTrackingError.dataFetchFailed(error))
                    return
                }
                
                guard let calorieSamples = samples as? [HKQuantitySample] else {
                    continuation.resume(returning: 0.0)
                    return
                }
                
                // Sum up all calorie samples during the workout
                let totalCalories = calorieSamples.reduce(0.0) { total, sample in
                    return total + sample.quantity.doubleValue(for: HKUnit.kilocalorie())
                }
                
                continuation.resume(returning: totalCalories)
            }
            
            healthStore.execute(query)
        }
    }
    
    /// Creates WorkoutTimeData record for the current prediction
    /// - Parameters:
    ///   - predictionTimestamp: When the predict button was pressed
    ///   - modelContext: SwiftData context for saving
    /// - Returns: WorkoutTimeData record with workout information
    func createWorkoutTimeRecord(predictionTimestamp: Date, modelContext: ModelContext) async -> WorkoutTimeData {
        do {
            if let workoutData = try await fetchLastWalkingOrRunningWorkout() {
                let workout = workoutData.workout
                let calories = workoutData.calories
                
                // Calculate time difference in minutes
                let timeDifferenceSeconds = predictionTimestamp.timeIntervalSince(workout.endDate)
                let timeDifferenceMinutes = timeDifferenceSeconds / 60.0
                
                // Get workout duration in minutes
                let workoutDurationMinutes = workout.duration / 60.0
                
                // Determine workout type string
                let workoutTypeString: String
                switch workout.workoutActivityType {
                case .walking:
                    workoutTypeString = "Walking"
                case .running:
                    workoutTypeString = "Running"
                default:
                    workoutTypeString = "Other"
                }
                
                print("🏃‍♂️ Found recent \(workoutTypeString.lowercased()) workout:")
                print("   End time: \(workout.endDate)")
                print("   Duration: \(String(format: "%.1f", workoutDurationMinutes)) minutes")
                print("   Calories: \(String(format: "%.1f", calories)) kcal")
                print("   Time since workout: \(String(format: "%.1f", timeDifferenceMinutes)) minutes")
                
                let workoutTimeData = WorkoutTimeData(
                    predictionTimestamp: predictionTimestamp,
                    lastWorkoutEndTime: workout.endDate,
                    workoutType: workoutTypeString,
                    timeDifferenceMinutes: timeDifferenceMinutes,
                    activeKilocalories: calories,
                    workoutDurationMinutes: workoutDurationMinutes
                )
                
                modelContext.insert(workoutTimeData)
                try modelContext.save()
                
                return workoutTimeData
                
            } else {
                print("🏃‍♂️ No walking or running workout found in the last 5 hours")
                
                let workoutTimeData = WorkoutTimeData(predictionTimestamp: predictionTimestamp)
                modelContext.insert(workoutTimeData)
                try modelContext.save()
                
                return workoutTimeData
            }
            
        } catch {
            print("❌ Error fetching workout data: \(error)")
            
            let workoutTimeData = WorkoutTimeData(predictionTimestamp: predictionTimestamp)
            modelContext.insert(workoutTimeData)
            
            do {
                try modelContext.save()
            } catch {
                print("❌ Error saving workout data to SwiftData: \(error)")
            }
            
            return workoutTimeData
        }
    }
}
