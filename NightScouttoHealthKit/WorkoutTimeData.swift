import Foundation
import SwiftData

@Model
class WorkoutTimeData {
    var id: UUID
    var predictionTimestamp: Date
    var lastWorkoutEndTime: Date?
    var workoutType: String? // "Walking" or "Running"
    var timeDifferenceMinutes: Double? // Minutes from workout end to prediction
    var activeKilocalories: Double? // Calories burned in the workout
    var workoutDurationMinutes: Double? // Duration of the workout in minutes
    
    init(predictionTimestamp: Date, 
         lastWorkoutEndTime: Date? = nil,
         workoutType: String? = nil,
         timeDifferenceMinutes: Double? = nil,
         activeKilocalories: Double? = nil,
         workoutDurationMinutes: Double? = nil) {
        self.id = UUID()
        self.predictionTimestamp = predictionTimestamp
        self.lastWorkoutEndTime = lastWorkoutEndTime
        self.workoutType = workoutType
        self.timeDifferenceMinutes = timeDifferenceMinutes
        self.activeKilocalories = activeKilocalories
        self.workoutDurationMinutes = workoutDurationMinutes
    }
    
    // Helper method to format time difference for display
    var formattedTimeDifference: String {
        guard let minutes = timeDifferenceMinutes else { return "No recent workout" }
        
        if minutes < 60 {
            return String(format: "%.1f min ago", minutes)
        } else {
            let hours = minutes / 60
            return String(format: "%.1f hours ago", hours)
        }
    }
    
    // Helper method to format calories
    var formattedCalories: String {
        guard let calories = activeKilocalories else { return "N/A" }
        return String(format: "%.1f kcal", calories)
    }
}
