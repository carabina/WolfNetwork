//
//  API.swift
//  WolfNetwork
//
//  Created by Wolf McNally on 5/2/17.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation
import WolfConcurrency
import WolfApp

extension Notification.Name {
    public static let loggedOut = Notification.Name("loggedOut")
}

open class API<T: AuthorizationProtocol> {
    public typealias AuthorizationType = T

    private let endpoint: Endpoint
    private let authorizationHeaderField: HeaderField

    public var debugPrintRequests = false

    public var authorization: AuthorizationType? {
        didSet {
            if authorization != nil {
                authorization!.save()
            } else {
                AuthorizationType.delete()
            }
        }
    }

    public init(endpoint: Endpoint, authorizationHeaderField: HeaderField = .authorization) {
        self.endpoint = endpoint
        self.authorizationHeaderField = authorizationHeaderField
        guard let authorization = AuthorizationType.load(), authorization.savedVersion == AuthorizationType.currentVersion else { return }
        self.authorization = authorization
    }

    public var hasCredentials: Bool {
        return authorization != nil
    }

    public enum Error: Swift.Error {
        case credentialsRequired
    }

    public var authorizationToken: String {
        get {
            return authorization!.authorizationToken
        }

        set {
            authorization!.authorizationToken = newValue
        }
    }

    private func _newRequest(method: HTTPMethod, scheme: HTTPScheme = .https, path: [Any]? = nil, query: [String: String]? = nil, isAuth: Bool) throws -> URLRequest {
        guard !isAuth || authorization != nil else {
            throw Error.credentialsRequired
        }

        let url = URL(scheme: scheme, host: endpoint.host, basePath: endpoint.basePath, pathComponents: path, query: query)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setClientRequestID()
        request.setMethod(method)
        request.setConnection(.close)
        if isAuth {
            request.setValue(authorizationToken, for: authorizationHeaderField)
        }

        return request
    }

    public func newRequest(method: HTTPMethod, scheme: HTTPScheme = .https, path: [Any]? = nil, query: [String: String]? = nil, isAuth: Bool) throws -> URLRequest {
        let request = try _newRequest(method: method, scheme: scheme, path: path, query: query, isAuth: isAuth)

        if debugPrintRequests {
            request.printRequest()
        }

        return request
    }

    public func newRequest<Body: Encodable>(method: HTTPMethod, scheme: HTTPScheme = .https, path: [Any]? = nil, query: [String: String]? = nil, isAuth: Bool, body: Body) throws -> URLRequest {
        var request = try _newRequest(method: method, scheme: scheme, path: path, query: query, isAuth: isAuth)
        let data = try JSONEncoder().encode(body)
        request.httpBody = data
        request.setContentType(.json, charset: .utf8)
        request.setContentLength(data.count)

        if debugPrintRequests {
            request.printRequest()
        }

        return request
    }

    public func newPromise<T: Decodable, Body: Encodable>(method: HTTPMethod, scheme: HTTPScheme = .https, path: [Any]? = nil, query: [String: String]? = nil, isAuth: Bool = false, body: Body, successStatusCodes: [StatusCode] = [.ok], expectedFailureStatusCodes: [StatusCode] = [], mock: Mock? = nil) -> Promise<T> {
        do {
            let request = try self.newRequest(method: method, scheme: scheme, path: path, query: query, isAuth: isAuth, body: body)
            return HTTP.retrieveData(with: request, successStatusCodes: successStatusCodes, expectedFailureStatusCodes: expectedFailureStatusCodes, mock: mock).then { data in
                return try JSONDecoder().decode(T.self, from: data)
                }.recover { (error, promise) in
                    self.handle(error: error, promise: promise)
            }
        } catch let error {
            return Promise<T>(error: error)
        }
    }

    public func newPromise<T: Decodable>(method: HTTPMethod, scheme: HTTPScheme = .https, path: [Any]? = nil, query: [String: String]? = nil, isAuth: Bool = false, successStatusCodes: [StatusCode] = [.ok], expectedFailureStatusCodes: [StatusCode] = [], mock: Mock? = nil) -> Promise<T> {
        do {
            let request = try self.newRequest(method: method, scheme: scheme, path: path, query: query, isAuth: isAuth)
            return HTTP.retrieveData(with: request, successStatusCodes: successStatusCodes, expectedFailureStatusCodes: expectedFailureStatusCodes, mock: mock).then { data in
                return try JSONDecoder().decode(T.self, from: data)
                }.recover { (error, promise) in
                    self.handle(error: error, promise: promise)
            }
        } catch let error {
            return Promise<T>(error: error)
        }
    }

    public func newPromise<Body: Encodable>(method: HTTPMethod, scheme: HTTPScheme = .https, path: [Any]? = nil, isAuth: Bool = false, body: Body, successStatusCodes: [StatusCode] = [.ok], expectedFailureStatusCodes: [StatusCode] = [], mock: Mock? = nil) -> SuccessPromise {
        do {
            let request = try self.newRequest(method: method, scheme: scheme, path: path, isAuth: isAuth, body: body)
            return HTTP.retrieve(with: request, successStatusCodes: successStatusCodes, expectedFailureStatusCodes: expectedFailureStatusCodes, mock: mock).succeed().recover { (error, promise) in
                self.handle(error: error, promise: promise)
            }
        } catch let error {
            return SuccessPromise(error: error)
        }
    }

    public func newPromise(method: HTTPMethod, scheme: HTTPScheme = .https, path: [Any]? = nil, isAuth: Bool = false, successStatusCodes: [StatusCode] = [.ok], expectedFailureStatusCodes: [StatusCode] = [], mock: Mock? = nil) -> SuccessPromise {
        do {
            let request = try self.newRequest(method: method, scheme: scheme, path: path, isAuth: isAuth)
            return HTTP.retrieve(with: request, successStatusCodes: successStatusCodes, expectedFailureStatusCodes: expectedFailureStatusCodes, mock: mock).succeed().recover { (error, promise) in
                self.handle(error: error, promise: promise)
            }
        } catch let error {
            return SuccessPromise(error: error)
        }
    }

    private func handle<T>(error: Swift.Error, promise: Promise<T>) {
        if error.httpStatusCode == .unauthorized {
            promise.cancel()
            logout()
        } else {
            promise.fail(error)
        }
    }

    public func logout() {
        authorization = nil
        notificationCenter.post(name: .loggedOut, object: self)
    }
}
