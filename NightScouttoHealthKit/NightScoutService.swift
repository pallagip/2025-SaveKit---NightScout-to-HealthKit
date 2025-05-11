//
//  NightScoutService.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-09.
//

import Foundation

struct Entry: Codable {
    let date: Date
    let sgv: Double
    // Additional fields as needed
    
    // Custom CodingKeys to handle the JSON format from Nightscout
    private enum CodingKeys: String, CodingKey {
        case date = "date"  // or "dateString" depending on the API
        case sgv = "sgv"
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
    }
}

struct Treatment: Codable {
    let date: Date
    let amount: Double
    // Add carbs, insulin type, etc., as needed
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
    
    func fetchGlucoseData(minutes: Int = 10) async throws -> [Entry] {
        // Calculate time 'minutes' ago for finding recent entries
        let now = Date()
        let minutesAgo = now.addingTimeInterval(-Double(minutes * 60))
        let millisSinceEpoch = Int(minutesAgo.timeIntervalSince1970 * 1000)
        
        // Build URL with query parameters
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/entries.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "find[date][$gte]", value: "\(millisSinceEpoch)"),
            URLQueryItem(name: "sort$desc", value: "date")
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
        return try decoder.decode([Entry].self, from: data)
    }
}
