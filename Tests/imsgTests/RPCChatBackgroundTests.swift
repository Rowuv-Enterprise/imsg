import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func rpcChatsBackgroundIsAReadThatNeedsItsBridgeSelector() async throws {
  #expect(kSupportedRPCMethods.contains("chats.background"))
  #expect(rpcRequestLane(for: "chats.background") == .read)
  #expect(BridgeAction.chatBackground.rawValue == "chat-background")
  #expect(!BridgeAction.chatBackground.isMutation)

  let store = try CommandTestDatabase.makeStoreForRPC()
  var withSelector = fullRPCStatusBridgeSelectors()
  withSelector["chatBackground"] = true
  var found: [Bool] = []
  for selectors in [withSelector, fullRPCStatusBridgeSelectors()] {
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
    found.append(rpcStatusMethods(try rpcStatusResult(output)).contains("chats.background"))
  }
  #expect(found == [true, false])
}

@Test
func rpcChatsBackgroundResolvesTheChatAndReturnsWhatTheBridgeRead() async throws {
  let store = try CommandTestDatabase.makeStoreForRPC()
  let output = TestRPCOutput()
  var calls: [(BridgeAction, [String: Any])] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { action, params in
      calls.append((action, params))
      return [
        "supported": true, "guid": NSNull(), "has_details": true,
        "details_class": "__NSDictionaryI", "details_keys": ["version": "__NSCFNumber"],
      ]
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"bg","method":"chats.background","params":{"chat_id":1}}"#)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"bad","method":"chats.background","params":{"chat_id":1,"file":"/tmp/a.png"}}"#
  )

  #expect(calls.count == 1)
  #expect(calls[0].0 == .chatBackground)
  #expect(calls[0].1["chatGuid"] as? String == "iMessage;+;chat123")
  #expect(calls[0].1.count == 1)
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["ok"] as? Bool == true)
  #expect(result?["supported"] as? Bool == true)
  #expect(result?["details_class"] as? String == "__NSDictionaryI")
  #expect((result?["details_keys"] as? [String: String])?["version"] == "__NSCFNumber")
  #expect(output.errors.count == 1)
}
