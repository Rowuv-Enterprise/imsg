import Foundation
import IMsgCore

extension RPCServer {
  func handleHandlesCheck(params: [String: Any], id: Any?) async throws {
    let params = try RPCParameters(
      params,
      method: "handles.check",
      supportedKeys: ["address", "alias_type", "service", "refresh"]
    )
    let address = try params.string("address") ?? ""
    guard !address.isEmpty else {
      throw RPCError.invalidParams("address is required")
    }

    let aliasType =
      (try params.string("alias_type") ?? (address.contains("@") ? "email" : "phone"))
      .lowercased()
    guard aliasType == "phone" || aliasType == "email" else {
      throw RPCError.invalidParams("alias_type must be phone or email")
    }

    let service = try params.string("service") ?? "iMessage"
    guard service.caseInsensitiveCompare("iMessage") == .orderedSame else {
      throw RPCError.invalidParams("handles.check only supports service iMessage")
    }

    let refresh = try params.boolean("refresh") ?? false

    let data = try await invokeBridge(
      action: .checkImessageAvailability,
      params: [
        "address": address,
        "aliasType": aliasType,
        "refresh": refresh,
      ])

    var result: [String: Any] = ["ok": true]
    result["address"] = data["address"] as? String ?? address
    result["alias_type"] = data["alias_type"] as? String ?? aliasType
    if let destination = data["destination"] as? String, !destination.isEmpty {
      result["destination"] = destination
    }
    if let idStatus = data["id_status"] as? NSNumber {
      result["id_status"] = idStatus.intValue
    }
    if let available = data["available"] as? Bool {
      result["available"] = available
    }
    if let refreshStarted = data["refresh_started"] as? Bool {
      result["refresh_started"] = refreshStarted
    }
    if let refreshStatus = data["refresh_status"] as? NSNumber {
      result["refresh_status"] = refreshStatus.intValue
    }
    result["service"] = "iMessage"
    respond(id: id, result: result)
  }
}
