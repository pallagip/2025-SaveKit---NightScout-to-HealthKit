import Foundation
import SwiftData
import UIKit

class CSVExportManager {
    static let shared = CSVExportManager()
    
    private init() {}
    
    func exportPredictions(from modelContext: ModelContext) -> URL? {
        do {
            // Get all predictions
            let descriptor = FetchDescriptor<Prediction>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            let predictions = try modelContext.fetch(descriptor)
            
            // Create CSV content with all metadata fields
            var csvContent = "Timestamp,Prediction Value,Units,Current BG (mmol/L),Stability Status," +
                            "Model Output (0-1),Model Predicted Change (mmol/L),Observed Trend (mmol/L)," +
                            "Model Weight,Trend Weight,Final Predicted Change (mmol/L)\n"
            
            for prediction in predictions {
                let timestamp = prediction.timestamp.ISO8601Format()
                let value = prediction.usedMgdlUnits ? 
                    String(format: "%.0f", prediction.predictionValue * 18.0) : 
                    String(format: "%.1f", prediction.predictionValue)
                let units = prediction.usedMgdlUnits ? "mg/dL" : "mmol/L"
                
                // Format all metadata with consistent decimal places
                let currentBG = String(format: "%.1f", prediction.currentBG)
                let modelOutput = String(format: "%.3f", prediction.modelOutput)
                let modelPredictedChange = String(format: "%.1f", prediction.modelPredictedChange)
                let observedTrend = String(format: "%.1f", prediction.observedTrend)
                let modelWeight = String(format: "%.2f", prediction.modelWeight)
                let trendWeight = String(format: "%.2f", prediction.trendWeight)
                let finalPredictedChange = String(format: "%.1f", prediction.finalPredictedChange)
                
                csvContent.append("\(timestamp),\(value),\(units),\(currentBG),\(prediction.stabilityStatus)," +
                                 "\(modelOutput),\(modelPredictedChange),\(observedTrend)," +
                                 "\(modelWeight),\(trendWeight),\(finalPredictedChange)\n")
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
