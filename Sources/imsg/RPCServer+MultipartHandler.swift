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
        ["attachment", "mention", "mentions"].contains($0)
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
        supportedKeys: ["text", "text_formatting", "textFormatting"]
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
}
