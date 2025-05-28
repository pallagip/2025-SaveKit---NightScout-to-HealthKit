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
            
            // Create CSV content with simplified fields - Always use mg/dL for exports
            // Removed the requested columns from CSV export
            var csvContent = "Timestamp,Prediction Value (mg/dL),Current BG (mg/dL),Stability Status," +
                            "Actual BG (mg/dL),Actual BG Timestamp\n"
            
            for prediction in predictions {
                let timestamp = prediction.timestamp.ISO8601Format()
                
                // Always convert to mg/dL for CSV export using the helper method
                let predictionValue = String(format: "%.0f", prediction.predictionValueInMgdl)
                
                // Convert all BG values to mg/dL for consistency
                let currentBGInMgdl = String(format: "%.0f", prediction.currentBG * 18.0)
                
                // Format actual BG data (convert to mg/dL) or display 'NA' if missing
                let actualBGInMgdl = prediction.actualBG > 0 ? String(format: "%.0f", prediction.actualBG * 18.0) : "NA"
                let actualBGTimestamp = prediction.actualBGTimestamp?.ISO8601Format() ?? "NA"
                
                // Append row with simplified values in mg/dL
                csvContent.append("\(timestamp),\(predictionValue),\(currentBGInMgdl),\(prediction.stabilityStatus)," +
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
        
        // Instead of clearing actual BG values which causes memory issues,
        // we'll use a completely new approach to get proper matching
        
        // Create a special matching service just for the export process
        let exportMatchingService = ExportPredictionMatchingService()
        
        // This will find valid future readings without clearing existing values
        let updatedCount = try await exportMatchingService.matchPredictionsForExport(context: modelContext)
        
        print("✅ Export matching complete - found \(updatedCount) valid future readings for predictions")
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
