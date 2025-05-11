//
//  NetworkLogger.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-11.
//

import Foundation

class NetworkLogger {
    static func log(request: URLRequest) {
        print("\n📤 OUTGOING REQUEST 📤\n")
        defer { print("\n------------------- END -------------------\n") }
        
        let urlAsString = request.url?.absoluteString ?? ""
        let urlComponents = URLComponents(string: urlAsString)
        let method = request.httpMethod != nil ? "\(request.httpMethod ?? "")" : ""
        let path = "\(urlComponents?.path ?? "")"
        
        var output = """
        URL: \(urlAsString)
        Method: \(method)
        Path: \(path)
        Headers:
        """
        
        // Log headers
        if let headers = request.allHTTPHeaderFields {
            for (key, value) in headers {
                output += "\n\(key): \(value)"
            }
        }
        
        // Log body if present
        if let body = request.httpBody,
           let bodyString = String(data: body, encoding: .utf8) {
            output += "\n\nRequest Body:\n\(bodyString)"
        }
        
        print(output)
    }
    
    static func log(response: HTTPURLResponse?, data: Data?, error: Error?) {
        print("\n📥 INCOMING RESPONSE 📥\n")
        defer { print("\n------------------- END -------------------\n") }
        
        var output = ""
        
        // Log response status
        if let response = response {
            output += "Status Code: \(response.statusCode)\n"
            
            // Log response headers
            output += "\nHeaders:\n"
            for (key, value) in response.allHeaderFields {
                output += "\(key): \(value)\n"
            }
        }
        
        // Log response body
        if let data = data,
           let jsonString = String(data: data, encoding: .utf8) {
            output += "\nResponse Body:\n\(jsonString)"
        }
        
        // Log error if present
        if let error = error {
            output += "\nError: \(error.localizedDescription)"
        }
        
        print(output)
    }
}


