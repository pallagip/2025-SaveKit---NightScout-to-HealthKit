//
//  NightScoutService.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-09.
//

import Foundation

struct Entry: Codable {
    var date: Date
    let sgv: Double
    let _id: String?
    let device: String?
    let type: String?
    
    // Custom CodingKeys to handle the JSON format from Nightscout
    private enum CodingKeys: String, CodingKey {
        case date = "date"
        case sgv = "sgv"
        case _id = "_id"
        case device = "device"
        case type = "type"
    }
    
    // Custom initializer to handle the date formats from Nightscout
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Handle date - Nightscout might return milliseconds since epoch
        if let dateMillis = try? container.decode(Double.self, forKey: .date) {
            // Convert milliseconds to seconds for Date
            self.date = Date(timeIntervalSince1970: dateMillis / 1000.0)
        } else if let dateString = try? container.decode(String.self, forKey: .date) {
            // If date is provided as ISO string, use DateFormatter
            let formatter = ISO8601DateFormatter()
            guard let parsedDate = formatter.date(from: dateString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .date,
                    in: container,
                    debugDescription: "Date string doesn't match expected format"
                )
            }
            self.date = parsedDate
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.date,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing date value"
                )
            )
        }
        
        // Handle sgv - could be Double or Int in the API
        if let sgvDouble = try? container.decode(Double.self, forKey: .sgv) {
            self.sgv = sgvDouble
        } else if let sgvInt = try? container.decode(Int.self, forKey: .sgv) {
            self.sgv = Double(sgvInt)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.sgv,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing sgv value"
                )
            )
        }
        
        // Handle _id, device, and type
        self._id = try? container.decode(String.self, forKey: ._id)
        self.device = try? container.decode(String.self, forKey: .device)
        self.type = try? container.decode(String.self, forKey: .type)
    }
}

struct Treatment: Codable {
    let date: Date
    let amount: Double?
    let carbs: Double?
    let insulin: Double?
    let eventType: String?
    let _id: String // NightScout treatment ID
    let enteredBy: String?
    
    // Custom CodingKeys to handle the JSON format from Nightscout
    private enum CodingKeys: String, CodingKey {
        case date = "date"
        case amount = "amount"
        case carbs = "carbs" 
        case insulin = "insulin"
        case eventType = "eventType"
        case _id = "_id"
        case enteredBy = "enteredBy"
    }
    
    // Custom initializer to handle the date formats from Nightscout
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Handle date - similar to Entry struct
        if let dateMillis = try? container.decode(Double.self, forKey: .date) {
            self.date = Date(timeIntervalSince1970: dateMillis / 1000.0)
        } else if let dateString = try? container.decode(String.self, forKey: .date) {
            let formatter = ISO8601DateFormatter()
            guard let parsedDate = formatter.date(from: dateString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .date,
                    in: container,
                    debugDescription: "Date string doesn't match expected format"
                )
            }
            self.date = parsedDate
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.date,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing date value"
                )
            )
        }
        
        // Handle optional fields
        self.amount = try? container.decode(Double.self, forKey: .amount)
        self.carbs = try? container.decode(Double.self, forKey: .carbs)
        self.insulin = try? container.decode(Double.self, forKey: .insulin)
        self.eventType = try? container.decode(String.self, forKey: .eventType)
        self._id = try container.decode(String.self, forKey: ._id)
        self.enteredBy = try? container.decode(String.self, forKey: .enteredBy)
    }
}

class NightscoutService {
    private let baseURL: URL
    private let apiSecret: String
    private let apiToken: String
    
    init(baseURL: URL, apiSecret: String, apiToken: String) {
        self.baseURL = baseURL
        self.apiSecret = apiSecret
        self.apiToken = apiToken
    }
    
    func fetchGlucoseData(minutes: Int = 25) async throws -> [Entry] {
        // Calculate time 'minutes' ago for finding recent entries
        let now = Date()
        let minutesAgo = now.addingTimeInterval(-Double(minutes * 60))
        let millisSinceEpoch = Int(minutesAgo.timeIntervalSince1970 * 1000)
        
        let millisNow = Int(now.timeIntervalSince1970 * 1000)
        
        // Build URL with query parameters
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/entries.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "find[date][$gte]", value: "\(millisSinceEpoch)"),
            URLQueryItem(name: "sort[date]", value: "-1"),
            URLQueryItem(name: "count", value: "5000")
        ]
        
        guard let url = components.url else {
            print("⚠️ Invalid URL construction")
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Set authentication headers
        request.setValue(apiSecret, forHTTPHeaderField: "API-SECRET")
        request.setValue(apiToken, forHTTPHeaderField: "API-TOKEN")
        
        // Log the outgoing request and query parameters
        print("🔍 FETCH REQUEST: \(minutes) minutes since \(millisSinceEpoch) (\(minutesAgo)) up to \(millisNow) (\(now))")
        NetworkLogger.log(request: request)
        
        let startTime = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let endTime = Date()
        
        // Log raw data and response
        print("📦 Raw Response Data: \(String(data: data, encoding: .utf8) ?? "Unable to convert to string")")
        
        // Log the incoming response
        NetworkLogger.log(
            response: response as? HTTPURLResponse,
            data: data,
            error: nil
        )
        
        // Print timing information
        print("⏱️ API Call Duration: \(endTime.timeIntervalSince(startTime)) seconds")
        
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            print("⚠️ HTTP Error: \(String(describing: response))")
            throw URLError(.badServerResponse)
        }
        
        // Create JSON decoder with appropriate strategies
        let decoder = JSONDecoder()
        let allEntries = try decoder.decode([Entry].self, from: data)
        let calendar = Calendar.current
        
        // --- DATA PRIORITIZATION (JUNK SUPPRESSION) ---
        let realEntries = allEntries.filter { 
            let year = calendar.component(.year, from: $0.date)
            return year >= 2024 && year <= 2027 
        }
        
        let junkEntries = allEntries.filter { calendar.component(.year, from: $0.date) == 2081 }
        
        var processedEntries: [Entry] = []
        
        if !realEntries.isEmpty {
            // prioritize real data, discard junk entirely
            print("✅ Real data detected (\(realEntries.count) samples). Discarding \(junkEntries.count) junk entries.")
            processedEntries = realEntries
        } else if !junkEntries.isEmpty {
            // fallback to relative mapping ONLY if no real data exists
            if let absoluteLatestJunkDate = junkEntries.map({ $0.date }).max() {
                print("⏲️ No real data. Falling back to Relative Mapping for \(junkEntries.count) junk samples.")
                processedEntries = junkEntries.map { entry -> Entry in
                    var mutableEntry = entry
                    let intervalFromPeak = entry.date.timeIntervalSince(absoluteLatestJunkDate)
                    mutableEntry.date = now.addingTimeInterval(intervalFromPeak)
                    return mutableEntry
                }
            }
        } else {
            processedEntries = allEntries
        }
        
        // Final cleaning: Ensure descending order and filter future drifts
        let filterCutoff = now.addingTimeInterval(60)
        let finalEntries = processedEntries
            .filter { $0.date <= filterCutoff }
            .sorted(by: { $0.date > $1.date })
        
        if let latest = finalEntries.first {
            let src = calendar.component(.year, from: latest.date) == 2081 ? "JUNK-MAPPED" : "REAL"
            print("📊 Latest Sync Entry: [\(Int(latest.sgv)) mg/dL @ \(latest.date)] Source: \(src)")
        }
        
        return finalEntries
    }
    
    func fetchTreatments(hours: Int = 24) async throws -> [Treatment] {
        // Calculate time 'hours' ago for finding recent treatments
        let now = Date()
        let hoursAgo = now.addingTimeInterval(-Double(hours * 3600))
        let millisSinceEpoch = Int(hoursAgo.timeIntervalSince1970 * 1000)
        
        let millisNow = Int(now.timeIntervalSince1970 * 1000)
        
        // Build URL with query parameters for treatments
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/treatments.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "find[date][$gte]", value: "\(millisSinceEpoch)"),
            URLQueryItem(name: "sort[date]", value: "-1"),
            URLQueryItem(name: "count", value: "1000")  // Get all treatments in timeframe
        ]
        
        guard let url = components.url else {
            print("⚠️ Invalid treatments URL construction")
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Set authentication headers
        request.setValue(apiSecret, forHTTPHeaderField: "API-SECRET")
        request.setValue(apiToken, forHTTPHeaderField: "API-TOKEN")
        
        // Log the outgoing request
        print("🔍 TREATMENTS REQUEST: \(hours) hours of treatment data since \(hoursAgo)")
        NetworkLogger.log(request: request)
        
        let startTime = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let endTime = Date()
        
        // Log raw data and response
        print("📦 Raw Treatments Response Data: \(String(data: data, encoding: .utf8) ?? "Unable to convert to string")")
        
        // Log the incoming response
        NetworkLogger.log(
            response: response as? HTTPURLResponse,
            data: data,
            error: nil
        )
        
        // Print timing information
        print("⏱️ Treatments API Call Duration: \(endTime.timeIntervalSince(startTime)) seconds")
        
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            print("⚠️ Treatments HTTP Error: \(String(describing: response))")
            throw URLError(.badServerResponse)
        }
        
        // Create JSON decoder with appropriate strategies
        let decoder = JSONDecoder()
        let allTreatments = try decoder.decode([Treatment].self, from: data)
        
        // Critical: Filter out future-dated treatments
        let filterCutoff = Date().addingTimeInterval(60)
        let validTreatments = allTreatments.filter { $0.date <= filterCutoff }
        
        if validTreatments.count < allTreatments.count {
            print("✂️ Filtered out \(allTreatments.count - validTreatments.count) future-dated treatments from Nightscout")
        }
        
        return validTreatments
    }
}
