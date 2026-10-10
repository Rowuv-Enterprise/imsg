import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcChatsSetBackgroundStagesBothFilesBeforeBridge() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var staged: [String] = []
  var calls: [(BridgeAction, [String: Any])] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      calls.append((action, params))
      return ["removed": false, "transfer_id": "TRANSFER-1"]
    },
    stageAttachment: { path in
      staged.append(path)
      return "/tmp/staged-\(staged.count)"
    },
    isBridgeReady: { true }
  )

  let prefix = #"{"jsonrpc":"2.0","id":"bg","method":"chats.setBackground","params":{"chat_id":1,"#
  await server.handleLineForTesting(
    prefix + #""file":"/tmp/a/archive","watch_file":"/tmp/a/watch"}}"#)
  await server.handleLineForTesting(prefix + #""file":"/tmp/a/archive"}}"#)

  #expect(staged == ["/tmp/a/archive", "/tmp/a/watch", "/tmp/a/archive"])
  #expect(calls.map(\.0) == [.setChatBackground, .setChatBackground])
  #expect(calls[0].1["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(calls[0].1["filePath"] as? String == "/tmp/staged-1")
  #expect(calls[0].1["watchPath"] as? String == "/tmp/staged-2")
  #expect(calls[1].1["filePath"] as? String == "/tmp/staged-3")
  #expect(calls[1].1["watchPath"] == nil)
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["transfer_id"] as? String == "TRANSFER-1")
}

@Test
func rpcChatsSetBackgroundNeedsAFileAndNeverRemoves() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var calls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, _ in
      calls += 1
      return [:]
    },
    stageAttachment: { _ in "/tmp/staged" },
    isBridgeReady: { true }
  )

  let prefix = #"{"jsonrpc":"2.0","id":"bg","method":"chats.setBackground","params":{"chat_id":1"#
  await server.handleLineForTesting(prefix + "}}")
  await server.handleLineForTesting(prefix + #","file":""}}"#)
  await server.handleLineForTesting(prefix + #","file":"/tmp/a","details":{}}}"#)

  #expect(calls == 0)
  #expect(output.errors.count == 3)
}

@Test
func rpcChatsRemoveBackgroundSendsNoFileAndStagesNothing() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var staged = false
  var calls: [(BridgeAction, [String: Any])] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      calls.append((action, params))
      return ["removed": true, "transfer_id": "TRANSFER-2"]
    },
    stageAttachment: { _ in
      staged = true
      return "/tmp/staged"
    },
    isBridgeReady: { true }
  )

  let prefix =
    #"{"jsonrpc":"2.0","id":"bg","method":"chats.removeBackground","params":{"chat_id":1"#
  await server.handleLineForTesting(prefix + "}}")
  await server.handleLineForTesting(prefix + #","file":"/tmp/a"}}"#)

  #expect(!staged)
  #expect(calls.count == 1)
  #expect(calls[0].0 == .setChatBackground)
  #expect(calls[0].1.count == 1)
  #expect(calls[0].1["chatGuid"] as? String == "iMessage;+;chat123")
  #expect((output.responses.first?["result"] as? [String: Any])?["removed"] as? Bool == true)
  #expect(output.errors.count == 1)
}

@Test
func rpcChatsBackgroundSettersAreMutationsBehindTheirOwnSelector() async throws {
  #expect(rpcRequestLane(for: "chats.setBackground") == .mutation)
  #expect(rpcRequestLane(for: "chats.removeBackground") == .mutation)
  #expect(BridgeAction.setChatBackground.rawValue == "set-chat-background")
  #expect(BridgeAction.setChatBackground.isMutation)

  let store = try CommandTestDatabase.makeStoreForRPC()
  var readOnly = fullRPCStatusBridgeSelectors()
  readOnly["chatBackground"] = true
  var both = readOnly
  both["chatBackgroundSet"] = true
  var found: [[Bool]] = []
  for selectors in [both, readOnly] {
    let output = TestRPCOutput()
    let server = RPCServer(
      store: store,
      verbose: false,
      output: output,
      invokeBridge: { action, _ in
        action == .status ? rpcStatusBridgeSnapshot(selectors: selectors) : [:]
      },
      isBridgeReady: { true }
    )
    await server.handleLineForTesting(#"{"jsonrpc":"2.0","id":"status","method":"status"}"#)
    let methods = rpcStatusMethods(try rpcStatusResult(output))
    found.append(
      ["chats.background", "chats.setBackground", "chats.removeBackground"].map(methods.contains))
  }
  #expect(found == [[true, true, true], [true, false, false]])
}
