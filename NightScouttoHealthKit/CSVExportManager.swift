import Foundation
import SwiftData
import UIKit
import HealthKit

class CSVExportManager {
    static let shared = CSVExportManager()
    
    private init() {}
    
    func exportPredictions(from modelContext: ModelContext) async -> URL? {
        do {
            // First ensure that all predictions have their actual BG values
            try await matchActualValuesBeforeExport(modelContext: modelContext)
            
            // Get all predictions
            let descriptor = FetchDescriptor<Prediction>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            let predictions = try modelContext.fetch(descriptor)
            
            // Create CSV content with all metadata fields - Always use mg/dL for exports
            var csvContent = "Timestamp,Prediction Value (mg/dL),Current BG (mg/dL),Stability Status," +
                            "Model Output (0-1),Model Predicted Change (mg/dL),Observed Trend (mg/dL)," +
                            "Model Weight,Trend Weight,Final Predicted Change (mg/dL)," +
                            "Actual BG (mg/dL),Actual BG Timestamp\n"
            
            for prediction in predictions {
                let timestamp = prediction.timestamp.ISO8601Format()
                
                // Always convert to mg/dL for CSV export using the helper method
                let predictionValue = String(format: "%.0f", prediction.predictionValueInMgdl)
                
                // Convert all BG values to mg/dL for consistency
                let currentBGInMgdl = String(format: "%.0f", prediction.currentBG * 18.0)
                
                // Format all metadata with consistent decimal places
                let modelOutput = String(format: "%.3f", prediction.modelOutput)
                
                // Convert all change/trend values to mg/dL
                let modelPredictedChangeInMgdl = String(format: "%.0f", prediction.modelPredictedChange * 18.0)
                let observedTrendInMgdl = String(format: "%.0f", prediction.observedTrend * 18.0)
                let finalPredictedChangeInMgdl = String(format: "%.0f", prediction.finalPredictedChange * 18.0)
                
                // Weight values (unchanged)
                let modelWeight = String(format: "%.2f", prediction.modelWeight)
                let trendWeight = String(format: "%.2f", prediction.trendWeight)
                
                // Format actual BG data (convert to mg/dL)
                let actualBGInMgdl = String(format: "%.0f", prediction.actualBG * 18.0)
                let actualBGTimestamp = prediction.actualBGTimestamp?.ISO8601Format() ?? ""
                
                // Append row with all values in mg/dL
                csvContent.append("\(timestamp),\(predictionValue),\(currentBGInMgdl),\(prediction.stabilityStatus)," +
                                 "\(modelOutput),\(modelPredictedChangeInMgdl),\(observedTrendInMgdl)," +
                                 "\(modelWeight),\(trendWeight),\(finalPredictedChangeInMgdl)," +
                                 "\(actualBGInMgdl),\(actualBGTimestamp)\n")
            }
            
            // Save to temporary file
            let fileName = "SaveKit_Predictions_\(Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")).csv"
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(fileName)
            
            try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("❌ Error exporting predictions: \(error)")
            return nil
        }
    }
    
    // Match actual HealthKit values before export to ensure data is current
    private func matchActualValuesBeforeExport(modelContext: ModelContext) async throws {
        print("🔄 Preparing CSV export - matching predictions with actual values first...")
        
        // Use the matching service to update all predictions with actual values
        let matchingService = PredictionMatchingService()
        let updatedCount = try await matchingService.matchPredictionsWithActualValues(context: modelContext, days: 7)
        
        print("✅ Pre-export matching complete - updated \(updatedCount) predictions with actual values")
    }
    
    func shareCSV(from url: URL, presenter: UIViewController) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        // Handle iPad presentation
        if let popoverController = activityVC.popoverPresentationController {
            popoverController.sourceView = presenter.view
            popoverController.sourceRect = CGRect(x: presenter.view.bounds.midX, 
                                                 y: presenter.view.bounds.midY, 
                                                 width: 0, height: 0)
            popoverController.permittedArrowDirections = []
        }
        
        presenter.present(activityVC, animated: true)
    }
}
