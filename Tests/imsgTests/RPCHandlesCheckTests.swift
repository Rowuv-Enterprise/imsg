import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

private func handlesCheckInt64Value(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcHandlesCheckInvokesBridgeAndReturnsAvailability() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      capturedAction = action
      capturedParams = params
      return [
        "address": "+14159369340",
        "alias_type": "phone",
        "destination": "tel:+14159369340",
        "id_status": 3,
        "available": true,
      ]
    },
    isBridgeReady: { true }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","alias_type":"Phone","service":"iMessage"}}"#
  await server.handleLineForTesting(line)

  #expect(capturedAction == .checkImessageAvailability)
  #expect(capturedParams["address"] as? String == "+14159369340")
  #expect(capturedParams["aliasType"] as? String == "phone")
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["address"] as? String == "+14159369340")
  #expect(result?["alias_type"] as? String == "phone")
  #expect(result?["destination"] as? String == "tel:+14159369340")
  #expect(handlesCheckInt64Value(result?["id_status"]) == 3)
  #expect(result?["available"] as? Bool == true)
  #expect(result?["service"] as? String == "iMessage")
}

@Test
func rpcHandlesCheckPassesRefreshAndReportsTheLookup() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var refreshes: [Bool?] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      let refresh = params["refresh"] as? Bool
      refreshes.append(refresh)
      var data: [String: Any] = [
        "address": "+14159369340",
        "alias_type": "phone",
        "destination": "tel:+14159369340",
        "id_status": 0,
        "available": false,
        "refresh_started": refresh == true,
      ]
      if refresh != true { data["refresh_status"] = 2 }
      return data
    },
    isBridgeReady: { true }
  )

  let prefix = #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
  await server.handleLineForTesting(prefix + #""address":"+14159369340","refresh":true}}"#)
  await server.handleLineForTesting(prefix + #""address":"+14159369340"}}"#)
  await server.handleLineForTesting(prefix + #""address":"+14159369340","refresh":"yes"}}"#)

  #expect(refreshes == [true, false])
  let results = output.responses.compactMap { $0["result"] as? [String: Any] }
  #expect(results.map { $0["refresh_started"] as? Bool } == [true, false])
  #expect(results.map { handlesCheckInt64Value($0["refresh_status"]) } == [nil, 2])
  #expect(output.errors.count == 1)
}

@Test
func rpcHandlesCheckReadsFocusOnlyWhenAsked() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var asked: [[Bool?]] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      let focus = params["focus"] as? Bool
      asked.append([focus, params["focusFetch"] as? Bool])
      var data: [String: Any] = [
        "address": "+14159369340", "alias_type": "phone", "id_status": 1, "available": true,
      ]
      if focus == true {
        data["focus_supported"] = true
        data["focus_handle"] = true
        data["focus_status"] = 2
        data["focus_fetch_started"] = params["focusFetch"] as? Bool == true
      }
      return data
    },
    isBridgeReady: { true }
  )

  let prefix = #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
  await server.handleLineForTesting(
    prefix + #""address":"+14159369340","focus":true,"focus_fetch":true}}"#)
  await server.handleLineForTesting(prefix + #""address":"+14159369340","focus":true}}"#)
  await server.handleLineForTesting(prefix + #""address":"+14159369340"}}"#)
  await server.handleLineForTesting(prefix + #""address":"+14159369340","focus_fetch":true}}"#)

  #expect(asked == [[true, true], [true, false], [false, false]])
  let results = output.responses.compactMap { $0["result"] as? [String: Any] }
  #expect(results.map { handlesCheckInt64Value($0["focus_status"]) } == [2, 2, nil])
  #expect(results.map { $0["focus_fetch_started"] as? Bool } == [true, false, nil])
  #expect(output.errors.count == 1)
}

@Test
func rpcHandlesCheckReadsLocationSharingOnlyWhenAsked() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var asked: [Bool?] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      let location = params["location"] as? Bool
      asked.append(location)
      var data: [String: Any] = [
        "address": "+14159369340", "alias_type": "phone", "id_status": 1, "available": true,
      ]
      if location == true {
        data["location_supported"] = true
        data["location_provisioned"] = 2
        data["location_handle"] = true
        data["location_sharing"] = true
        data["location_class"] = "IMFindMyLocation"
        data["location_keys"] = ["latitude", "longitude"]
        data["latitude"] = 48.85
      }
      return data
    },
    isBridgeReady: { true }
  )

  let prefix = #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
  await server.handleLineForTesting(prefix + #""address":"+14159369340","location":true}}"#)
  await server.handleLineForTesting(prefix + #""address":"+14159369340"}}"#)
  await server.handleLineForTesting(prefix + #""address":"+14159369340","location":"yes"}}"#)

  #expect(asked == [true, false])
  let results = output.responses.compactMap { $0["result"] as? [String: Any] }
  #expect(results.map { $0["location_sharing"] as? Bool } == [true, nil])
  #expect(results.map { handlesCheckInt64Value($0["location_provisioned"]) } == [2, nil])
  #expect(results.map { $0["location_class"] as? String } == ["IMFindMyLocation", nil])
  #expect(results.map { $0["location_keys"] as? [String] } == [["latitude", "longitude"], nil])
  #expect(results.allSatisfy { $0["latitude"] == nil })
  #expect(output.errors.count == 1)
}

@Test
func rpcHandlesCheckRequiresAddress() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(handlesCheckInt64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRejectsInvalidAliasType() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","alias_type":"url"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(handlesCheckInt64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRejectsSmsService() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340","service":"sms"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(handlesCheckInt64Value(error?["code"]) == -32602)
}

@Test
func rpcHandlesCheckRequiresReadyBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var bridgeInvoked = false
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      bridgeInvoked = true
      return [:]
    },
    isBridgeReady: { false }
  )

  let line =
    #"{"jsonrpc":"2.0","id":"handle","method":"handles.check","params":{"#
    + #""address":"+14159369340"}}"#
  await server.handleLineForTesting(line)

  #expect(bridgeInvoked == false)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(handlesCheckInt64Value(error?["code"]) == -32003)
}
