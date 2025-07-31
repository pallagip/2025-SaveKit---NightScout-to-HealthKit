#!/usr/bin/env swift

//
//  TestModelMetadata.swift
//  Quick script to extract scaling parameters from Core ML models
//

import Foundation
import CoreML

// Change to the project directory
let projectPath = "/Users/mynewmacbook/Documents/2025-SaveKit---NightScout-to-HealthKit/NightScouttoHealthKit"

// Load and inspect each model
let modelNames = ["rangeupto2_tcn", "rangeupto3_tcn", "rangeupto4_tcn", "rangeupto5_tcn", "rangeupto6_tcn"]

for modelName in modelNames {
    print("\n🔍 ===== INSPECTING \(modelName) =====")
    
    let modelPath = "\(projectPath)/\(modelName).mlpackage"
    let modelURL = URL(fileURLWithPath: modelPath)
    
    do {
        let model = try MLModel(contentsOf: modelURL)
        
        // Print basic model info
        let desc = model.modelDescription
        print("📋 Model: \(modelName)")
        
        // Input info
        print("📥 Inputs:")
        for (name, feature) in desc.inputDescriptionsByName {
            print("  - \(name): \(feature.type)")
            if let constraint = feature.multiArrayConstraint {
                print("    Shape: \(constraint.shape)")
                print("    DataType: \(constraint.dataType.rawValue)")
            }
        }
        
        // Output info  
        print("📤 Outputs:")
        for (name, feature) in desc.outputDescriptionsByName {
            print("  - \(name): \(feature.type)")
            if let constraint = feature.multiArrayConstraint {
                print("    Shape: \(constraint.shape)")
                print("    DataType: \(constraint.dataType.rawValue)")
            }
        }
        
        // Metadata
        print("🏷️ Metadata:")
        let metadata = desc.metadata
        if metadata.isEmpty {
            print("  (No metadata found)")
        } else {
            for (key, value) in metadata {
                print("  - \(key): \(value)")
            }
        }
        
        // Look for scaling parameters in user-defined keys
        print("🔍 Looking for scaling parameters...")
        var foundScaling = false
        
        // Check all available metadata keys for scaling-related terms
        for (key, value) in metadata {
            let keyString = String(describing: key)
            let keyLower = keyString.lowercased()
            
            if keyLower.contains("mean") || keyLower.contains("std") || keyLower.contains("scale") {
                print("  ✅ Found potential scaling parameter: \(keyString) = \(value)")
                foundScaling = true
            }
        }
        
        if !foundScaling {
            print("  ❌ No scaling parameters found in metadata")
        }
        
    } catch {
        print("❌ Failed to load \(modelName): \(error)")
    }
}

print("\n🏁 Model inspection complete!")
