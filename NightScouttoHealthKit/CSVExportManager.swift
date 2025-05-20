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
            
            // Create CSV content
            var csvContent = "Timestamp,Prediction Value,Units\n"
            
            for prediction in predictions {
                let timestamp = prediction.timestamp.ISO8601Format()
                let value = prediction.usedMgdlUnits ? 
                    String(format: "%.0f", prediction.predictionValue * 18.0) : 
                    String(format: "%.1f", prediction.predictionValue)
                let units = prediction.usedMgdlUnits ? "mg/dL" : "mmol/L"
                
                csvContent.append("\(timestamp),\(value),\(units)\n")
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
