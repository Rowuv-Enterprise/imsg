import Foundation
import IMsgCore

extension RPCServer {
  func handleSendMultipart(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      ["parts", "effect_id", "effectId", "effect", "subject"]
    )
    let params = try RPCParameters(
      params, method: "send.multipart", supportedKeys: supportedKeys)
    guard let rawParts = try params.objectArray("parts") else {
      throw RPCError.invalidParams("parts is required")
    }
    guard !rawParts.isEmpty, rawParts.count <= 20 else {
      throw RPCError.invalidParams("parts must contain between 1 and 20 parts")
    }

    var parts: [[String: Any]] = []
    var files: [(index: Int, path: String)] = []
    parts.reserveCapacity(rawParts.count)
    for (index, rawPart) in rawParts.enumerated() {
      if let key = rawPart.keys.sorted().first(where: {
        ["attachment", "mention"].contains($0)
      }) {
        throw RPCError.invalidParams("\(key) parts are not supported")
      }
      if rawPart["file"] != nil {
        let part = try RPCParameters(
          rawPart,
          method: "send.multipart parts[\(index)]",
          supportedKeys: ["file"]
        )
        guard let file = try part.string("file"), !file.isEmpty else {
          throw RPCError.invalidParams("parts[\(index)].file must be a non-empty string")
        }
        files.append((index: index, path: file))
        parts.append([:])
        continue
      }
      let part = try RPCParameters(
        rawPart,
        method: "send.multipart parts[\(index)]",
        supportedKeys: ["text", "text_formatting", "textFormatting", "mentions"]
      )
      guard let text = try part.string("text"), !text.isEmpty else {
        throw RPCError.invalidParams("parts[\(index)].text must be a non-empty string")
      }
      var bridgePart: [String: Any] = ["text": text]
      if let formatting = try part.objectArray(
        "text_formatting", aliases: ["textFormatting"])
      {
        bridgePart["textFormatting"] = formatting
      }
      if let rawMentions = try part.objectArray("mentions") {
        bridgePart["mentions"] = try Self.multipartMentions(
          rawMentions, textLength: text.utf16.count, partIndex: index)
      }
      parts.append(bridgePart)
    }
    guard files.count <= Self.multipartFileLimit else {
      throw RPCError.invalidParams(
        "parts must contain at most \(Self.multipartFileLimit) file parts")
    }

    let effect = try params.string("effect_id", aliases: ["effectId", "effect"])
    let subject = try params.string("subject")
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = ["chatGuid": chatGUID, "parts": parts]
    if let effect, !effect.isEmpty {
      bridgeParams["effectId"] = ExpressiveSendEffect.expand(effect)
    }
    if let subject, !subject.isEmpty {
      bridgeParams["subject"] = subject
    }

    let verification = try await bridgeSendVerificationBaseline()
    if !files.isEmpty {
      try await requireRichAttachmentCapability(requiresMetadata: true)
      for file in files {
        do {
          let staged = try stageAttachment((file.path as NSString).expandingTildeInPath)
          parts[file.index] = ["filePath": staged]
        } catch {
          throw DeliveryFailure(
            disposition: .notStarted,
            transport: .bridgeV2,
            operation: BridgeAction.sendMultipart.rawValue,
            detail: "An attachment could not be staged before bridge dispatch."
          )
        }
      }
      bridgeParams["parts"] = parts
    }
    let data = try await invokeBridge(action: .sendMultipart, params: bridgeParams)
    var result = try await verifiedBridgeSendResponse(
      data,
      params: params,
      chatGUID: chatGUID,
      action: .sendMultipart,
      database: verification.database,
      baselineRowID: verification.rowID
    )
    result["ok"] = true
    result["parts_count"] = parts.count
    respond(id: id, result: result)
  }

  static let multipartFileLimit = 10

  /// A mention is a UTF-16 range of one text part and the address it names.
  /// Anything else in the object, or a range outside the part, is refused here
  /// so the bridge never sees a mention it would silently drop.
  static func multipartMentions(
    _ rawMentions: [[String: Any]], textLength: Int, partIndex: Int
  ) throws -> [[String: Any]] {
    try rawMentions.enumerated().map { (offset, rawMention) -> [String: Any] in
      let name = "send.multipart parts[\(partIndex)].mentions[\(offset)]"
      let mention = try RPCParameters(
        rawMention, method: name, supportedKeys: ["start", "length", "address"])
      guard
        let start = try mention.integer("start"), let length = try mention.integer("length"),
        start >= 0, length > 0, start <= textLength, length <= textLength - start
      else {
        throw RPCError.invalidParams("\(name) must be a range inside the part's text")
      }
      guard let address = try mention.string("address"), !address.isEmpty, address.count <= 254
      else {
        throw RPCError.invalidParams("\(name).address must be a non-empty string")
      }
      return ["start": start, "length": length, "address": address]
    }
  }
}
