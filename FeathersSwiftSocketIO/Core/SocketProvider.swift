//
//  SocketProvider.swift
//  FeathersSwiftSocketIO
//
//  Created by Brendan Conron on 5/16/17.
//  Copyright © 2017 FeathersJS. All rights reserved.
//

import SocketIO
import Foundation
import Result
import Feathers

public final class SocketProvider: RealTimeProvider {

    public let baseURL: URL

    /// SocketIO client configuration object.
    private let configuration: SocketIOClientConfiguration

    /// SocketIO client.
    private let client: SocketIOClient

    /// Socket timeout for `connect` and all emits.
    private let timeout: Int

    /// Socket provider initializer.
    ///
    /// - Parameters:
    ///   - baseURL: Socket url.
    ///   - configuration: Socket configuration object. See `SocketIO` for more details
    /// on the possible options.
    ///   - timeout: Socket timeout.
    public init(baseURL: URL, configuration: SocketIOClientConfiguration, timeout: Int = 5) {
        self.baseURL = baseURL
        self.configuration = configuration
        self.timeout = timeout
        client = SocketIOClient(socketURL: baseURL, config: configuration)
    }

    public func setup(app: Feathers) {
        // Attempt to authenticate using a previously stored token once the client connects.
        client.once("connect") { [weak app = app, weak self] data, ack in
            guard let vSelf = self else { return }
            guard let vApp = app else { return }
            guard let accessToken = vApp.authenticationStorage.accessToken else { return }
            vSelf.emit(to: "authenticate", with: [
                "strategy": vApp.authenticationConfiguration.jwtStrategy,
                "accessToken": accessToken
            ]) { error, response in
                if let _ = error {
                    print("failed to authenticate the client")
                } else {
                    print("successfully authenticated the client")
                }
            }
        }
        client.connect(timeoutAfter: timeout) {
            print("feathers socket failed to connect")
        }
    }

    public func request(endpoint: Endpoint, _ completion: @escaping FeathersCallback) {
        let emitPath = "\(endpoint.path)::\(endpoint.method.socketRequestPath)"
        emit(to: emitPath, with: endpoint.method.socketData, completion)
    }

    public func authenticate(_ path: String, credentials: [String : Any], _ completion: @escaping FeathersCallback) {
        emit(to: "authenticate", with: credentials, completion)
    }

    public func logout(path: String, _ completion: @escaping FeathersCallback) {
        emit(to: "logout", with: [], completion)
    }

    /// Emit data to a given path.
    ///
    /// - Parameters:
    ///   - path: Path to emit on.
    ///   - data: Data to emit.
    ///   - completion: Completion callback.
    private func emit(to path: String, with data: SocketData, _ completion: @escaping FeathersCallback) {
        if client.status == .connecting {
            client.once("connect") { [weak self] data, ack in
                guard let vSelf = self else { return }
                vSelf.client.emitWithAck(path, data).timingOut(after: vSelf.timeout) { data in
                    let result = vSelf.handleResponseData(data: data)
                    completion(result.error, result.value)
                }
            }
        } else {
            client.emitWithAck(path, data).timingOut(after: timeout) { [weak self] data in
                guard let vSelf = self else { return }
                let result = vSelf.handleResponseData(data: data)
                completion(result.error, result.value)
            }
        }
    }

    /// Parse and handle socket response data.
    ///
    /// - Parameter data: Socket response data.
    /// - Returns: Result object with error or response.
    private func handleResponseData(data: [Any]) -> Result<Response, FeathersError> {
        if let noAck = data.first as? String, noAck == "NO ACK" {
            return .failure(.notFound)
        } else if let errorData = data.first as? [String: Any], let code = errorData["code"] as? Int, let error = FeathersError(statusCode: code) {
            return .failure(error)
        } else if let jsonObject = data.last as? [String: Any] {
            if let pagination = parsePagination(data: jsonObject), let data = jsonObject["data"] as? [Any] {
                return .success(Response(pagination: pagination, data: .jsonArray(data)))
            }
            return .success(Response(pagination: nil, data: .jsonObject(jsonObject)))
        } else if let jsonArray = data.last as? [Any] {
            return .success(Response(pagination: nil, data: .jsonArray(jsonArray)))
        }
        return .failure(.unknown)
    }

    /// Parse pagination data if any.
    ///
    /// - Parameter data: Data to parse from.
    /// - Returns: Paginiation object or nil.
    private func parsePagination(data: [String: Any]) -> Pagination? {
        guard
            let limit = data["limit"] as? Int,
            let skip = data["skip"] as? Int,
            let total = data["total"] as? Int else {
                return nil
        }
        return Pagination(total: total, limit: limit, skip: skip)
    }

    // MARK: - RealTimeProvider

    public func on(event: String, callback: @escaping ([String: Any]) -> ()) {
        client.on(event, callback: { data, _ in
            guard let object = data.first as? [String: Any] else { return }
            callback(object)
        })
    }

    public func once(event: String, callback: @escaping ([String : Any]) -> ()) {
        client.once(event, callback: { data, _ in
            guard let object = data.first as? [String: Any] else { return }
            callback(object)
        })
    }

    public func off(event: String) {
        client.off(event)
    }

    // MARK: - Deinit

    deinit {
        client.disconnect()
    }

}

fileprivate extension Service.Method {

    fileprivate var socketRequestPath: String {
        switch self {
        case .find: return "find"
        case .get: return "get"
        case .create: return "create"
        case .update: return "update"
        case .patch: return "patch"
        case .remove: return "removed"
        }
    }

    fileprivate var socketData: [SocketData?] {
        switch self {
        case .find(let parameters):
            return [parameters ?? [:]]
        case .get(let id, let parameters):
            return [id, parameters ?? [:]]
        case .create(let data, let parameters):
            return [data, parameters ?? [:]]
        case .update(let id, let data, let parameters),
             .patch(let id, let data, let parameters):
            return [id ?? nil, data, parameters ?? [:]]
        case .remove(let id, let parameters):
            return [id ?? nil, parameters]
        }
    }
    
}

