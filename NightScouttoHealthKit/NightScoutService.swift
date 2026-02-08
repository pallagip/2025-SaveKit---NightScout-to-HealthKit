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
    // Additional fields as needed
    
    // Custom CodingKeys to handle the JSON format from Nightscout
    private enum CodingKeys: String, CodingKey {
        case date = "date"
        case dateString = "dateString"
        case sgv = "sgv"
    }
    
    // Custom initializer to handle the date formats from Nightscout
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle date - prefer dateString when available (more reliable), otherwise fall back to numeric.
        if let dateString = try? container.decode(String.self, forKey: .dateString) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = iso.date(from: dateString) {
                self.date = parsed
            } else {
                let isoNoFrac = ISO8601DateFormatter()
                isoNoFrac.formatOptions = [.withInternetDateTime]
                guard let parsed = isoNoFrac.date(from: dateString) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .dateString,
                        in: container,
                        debugDescription: "dateString doesn't match expected ISO8601 format"
                    )
                }
                self.date = parsed
            }
        } else if let raw = try? container.decode(Double.self, forKey: .date) {
            // Nightscout commonly uses milliseconds since epoch, but some setups can differ.
            // Use magnitude heuristics to avoid future-dated (or 1970-dated) parsing.
            let seconds: TimeInterval
            if raw > 1.0e14 {
                // Likely microseconds
                seconds = raw / 1_000_000.0
            } else if raw > 1.0e11 {
                // Likely milliseconds
                seconds = raw / 1_000.0
            } else {
                // Likely seconds
                seconds = raw
            }
            self.date = Date(timeIntervalSince1970: seconds)
        } else if let dateString = try? container.decode(String.self, forKey: .date) {
            // Some servers might (incorrectly) return `date` as a string.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = iso.date(from: dateString) {
                self.date = parsed
            } else {
                let isoNoFrac = ISO8601DateFormatter()
                isoNoFrac.formatOptions = [.withInternetDateTime]
                guard let parsed = isoNoFrac.date(from: dateString) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .date,
                        in: container,
                        debugDescription: "Date string doesn't match expected ISO8601 format"
                    )
                }
                self.date = parsed
            }
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.date,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing date/dateString value"
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
    }
    
    // Encodable conformance
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sgv, forKey: .sgv)
        
        // Encode date as milliseconds since 1970
        let millis = date.timeIntervalSince1970 * 1000
        try container.encode(millis, forKey: .date)
        
        // Also encode dateString for compatibility
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateString = iso.string(from: date)
        try container.encode(dateString, forKey: .dateString)
    }
}

struct Treatment: Codable {
    var date: Date
    let amount: Double?
    let carbs: Double?
    let insulin: Double?
    let eventType: String?
    let _id: String // NightScout treatment ID
    let enteredBy: String?
    
    // Custom CodingKeys to handle the JSON format from Nightscout
    private enum CodingKeys: String, CodingKey {
        case date = "date"
        case dateString = "dateString"
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

        // Handle date - prefer dateString when available.
        if let dateString = try? container.decode(String.self, forKey: .dateString) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = iso.date(from: dateString) {
                self.date = parsed
            } else {
                let isoNoFrac = ISO8601DateFormatter()
                isoNoFrac.formatOptions = [.withInternetDateTime]
                guard let parsed = isoNoFrac.date(from: dateString) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .dateString,
                        in: container,
                        debugDescription: "dateString doesn't match expected ISO8601 format"
                    )
                }
                self.date = parsed
            }
        } else if let raw = try? container.decode(Double.self, forKey: .date) {
            let seconds: TimeInterval
            if raw > 1.0e14 {
                seconds = raw / 1_000_000.0
            } else if raw > 1.0e11 {
                seconds = raw / 1_000.0
            } else {
                seconds = raw
            }
            self.date = Date(timeIntervalSince1970: seconds)
        } else if let dateString = try? container.decode(String.self, forKey: .date) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = iso.date(from: dateString) {
                self.date = parsed
            } else {
                let isoNoFrac = ISO8601DateFormatter()
                isoNoFrac.formatOptions = [.withInternetDateTime]
                guard let parsed = isoNoFrac.date(from: dateString) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .date,
                        in: container,
                        debugDescription: "Date string doesn't match expected ISO8601 format"
                    )
                }
                self.date = parsed
            }
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.date,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing date/dateString value"
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
    
    // Encodable conformance
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_id, forKey: ._id)
        try container.encodeIfPresent(amount, forKey: .amount)
        try container.encodeIfPresent(carbs, forKey: .carbs)
        try container.encodeIfPresent(insulin, forKey: .insulin)
        try container.encodeIfPresent(eventType, forKey: .eventType)
        try container.encodeIfPresent(enteredBy, forKey: .enteredBy)
        
        // Encode date as milliseconds since 1970
        let millis = date.timeIntervalSince1970 * 1000
        try container.encode(millis, forKey: .date)
        
        // Also encode dateString for compatibility
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateString = iso.string(from: date)
        try container.encode(dateString, forKey: .dateString)
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
        
        // Build URL with query parameters
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/entries.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "find[date][$gte]", value: "\(millisSinceEpoch)"),
            URLQueryItem(name: "sort$desc", value: "date"),
            URLQueryItem(name: "count", value: "1000")  // Increased from default (usually 10) to ensure we get all entries
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
        print("🔍 FETCH REQUEST: \(minutes) minutes of data since \(minutesAgo)")
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
        var entries = try decoder.decode([Entry].self, from: data)
        
        // Automatic Time Correction for future-dated data (e.g. 2081 issue)

        let oneYearInSeconds: TimeInterval = 365 * 24 * 3600
        let oneYearFuture = now.addingTimeInterval(oneYearInSeconds)
        
        // Check if the latest entry (first in list) is significantly in the future
        if let latestEntry = entries.first, latestEntry.date > oneYearFuture {
            print("⚠️ DETECTED FAR-FUTURE DATA: Latest entry is \(latestEntry.date)")
            print("🔄 Applying automatic time shift to align usage with current time...")
            
            // Calculate shift needed to bring the latest entry to "now"
            // We use the very first entry as the anchor since the API sorts by date desc
            let timeShift = now.timeIntervalSince(latestEntry.date)
            
            for i in 0..<entries.count {
                entries[i].date = entries[i].date.addingTimeInterval(timeShift)
            }
            
            if let newLatest = entries.first {
                print("✅ Time correction applied. Latest entry is now: \(newLatest.date)")
            }
        }
        
        // Final sanity check: Filter out any remaining future entries (> 1 hour)
        // This handles cases where data might be erratic or the shift wasn't perfect
        return entries.filter { entry in
            let oneHourFromNow = Date().addingTimeInterval(3600)
            if entry.date > oneHourFromNow {
                print("⚠️ Ignoring entry that is still future-dated after correction: \(entry.date)")
                return false
            }
            return true
        }
    }
    
    func fetchTreatments(hours: Int = 24) async throws -> [Treatment] {
        // Calculate time 'hours' ago for finding recent treatments
        let now = Date()
        let hoursAgo = now.addingTimeInterval(-Double(hours * 3600))
        let millisSinceEpoch = Int(hoursAgo.timeIntervalSince1970 * 1000)
        
        // Build URL with query parameters for treatments
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/treatments.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "find[date][$gte]", value: "\(millisSinceEpoch)"),
            URLQueryItem(name: "sort$desc", value: "date"),
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
        var treatments = try decoder.decode([Treatment].self, from: data)
        
        // Automatic Time Correction for future-dated treatments

        let oneYearInSeconds: TimeInterval = 365 * 24 * 3600
        let oneYearFuture = now.addingTimeInterval(oneYearInSeconds)
        
        if let latestTreatment = treatments.first, latestTreatment.date > oneYearFuture {
            print("⚠️ DETECTED FAR-FUTURE TREATMENTS: Latest is \(latestTreatment.date)")
            print("🔄 Applying automatic time shift to treatments...")
            
            let timeShift = now.timeIntervalSince(latestTreatment.date)
            
            for i in 0..<treatments.count {
                treatments[i].date = treatments[i].date.addingTimeInterval(timeShift)
            }
             
            if let newLatest = treatments.first {
                print("✅ Treatment time correction applied. Latest is now: \(newLatest.date)")
            }
        }
        
        return treatments.filter { treatment in
            let oneHourFromNow = Date().addingTimeInterval(3600)
            if treatment.date > oneHourFromNow {
                print("⚠️ Ignoring treatment that is still future-dated after correction: \(treatment.date)")
                return false
            }
            return true
        }
    }
}
