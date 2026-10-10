static NSAttributedString *buildAttachmentAttributed(NSString *transferGuid,
                                                     NSString *filename,
                                                     NSInteger partIndex);

/// Same refusals as handleSendAttachment, so a file part cannot reach a path
/// the single-attachment send would have refused.
static NSString *multipartFilePathError(NSString *filePath) {
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:filePath error:nil];
    if (!attrs) return [NSString stringWithFormat:@"File not found: %@", filePath];
    if ([attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
        return @"Symlinked attachment paths are not allowed";
    }
    if (pathHasSymlinkComponent(filePath)) return @"Attachment path traverses a symlink";
    return nil;
}

/// Mark `{start, length, address}` ranges of one text part as confirmed
/// mentions of `address`. A range outside the part is skipped, as formatting
/// ranges are.
static void applyMentionAttributes(NSMutableAttributedString *attr, NSArray *mentions) {
    for (id raw in mentions) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *startNum = raw[@"start"];
        NSNumber *lengthNum = raw[@"length"];
        NSString *address = raw[@"address"];
        if (![startNum isKindOfClass:[NSNumber class]]) continue;
        if (![lengthNum isKindOfClass:[NSNumber class]]) continue;
        if (![address isKindOfClass:[NSString class]] || address.length == 0) continue;
        NSInteger start = startNum.integerValue;
        NSInteger length = lengthNum.integerValue;
        if (start < 0 || length <= 0) continue;
        if ((NSUInteger)(start + length) > attr.length) continue;
        [attr addAttribute:@"__kIMMentionConfirmedMention" value:address
                     range:NSMakeRange((NSUInteger)start, (NSUInteger)length)];
    }
}

static NSDictionary *handleSendMultipart(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSArray *parts = params[@"parts"];
    NSString *effectId = params[@"effectId"];
    NSString *subject = params[@"subject"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (![parts isKindOfClass:[NSArray class]] || parts.count == 0) {
        return errorResponse(requestId, @"Missing or empty parts array");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    NSMutableArray<NSString *> *transferGuids = [NSMutableArray array];
    NSMutableArray *transfers = [NSMutableArray array];
    NSInteger partIndex = 0;
    @try {
        for (NSDictionary *part in parts) {
            if (![part isKindOfClass:[NSDictionary class]]) continue;
            NSString *filePath = part[@"filePath"];
            if ([filePath isKindOfClass:[NSString class]] && filePath.length) {
                NSString *pathErr = multipartFilePathError(filePath);
                if (pathErr) return errorResponse(requestId, pathErr);
                NSURL *fileURL = [NSURL fileURLWithPath:filePath];
                NSString *filename = [fileURL lastPathComponent];
                NSString *prepErr = nil;
                IMFileTransfer *transfer = prepareOutgoingTransfer(
                    fileURL, filename, chatGuid, IMsgOutgoingTransferKindAttachment,
                    nil, NULL, &prepErr);
                if (!transfer) {
                    return errorResponse(requestId,
                        prepErr.length ? prepErr : @"Could not register attachment transfer");
                }
                NSString *transferGuid = [transfer guid];
                if (!transferGuid.length) {
                    return errorResponse(requestId, @"Transfer registered without guid");
                }
                [body appendAttributedString:buildAttachmentAttributed(transferGuid, filename,
                                                                       partIndex)];
                [transferGuids addObject:transferGuid];
                [transfers addObject:transfer];
                partIndex++;
                continue;
            }
            NSString *text = part[@"text"];
            if (!text.length) continue;
            NSArray *partFormatting = part[@"textFormatting"];
            NSArray *mentions = part[@"mentions"];
            BOOL formatted = [partFormatting isKindOfClass:[NSArray class]]
                && partFormatting.count > 0;
            BOOL mentioned = [mentions isKindOfClass:[NSArray class]] && mentions.count > 0;
            NSAttributedString *seg;
            if (formatted || mentioned) {
                NSMutableAttributedString *rich = buildFormattedAttributed(
                    text, formatted ? partFormatting : nil, partIndex);
                if (mentioned) applyMentionAttributes(rich, mentions);
                seg = rich;
            } else {
                seg = buildPlainAttributed(text, partIndex);
            }
            [body appendAttributedString:seg];
            partIndex++;
        }
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-multipart failed: %@", exception.reason]);
    }
    if (body.length == 0) {
        return errorResponse(requestId, @"No usable parts");
    }

    NSAttributedString *subjectAttr = subject.length
        ? buildPlainAttributed(subject, 0)
        : nil;
    long long associatedType = selectedMessageGuid.length ? 100 : 0;

    @try {
        id parentMessage = nil;
        id parentItem = nil;
        NSString *threadIdentifier = nil;
        if (selectedMessageGuid.length) {
            threadIdentifier = deriveThreadIdentifier(chat, selectedMessageGuid,
                                                      &parentMessage,
                                                      &parentItem);
            debugLog(@"handleSendMultipart: parent=%@ threadId=%@",
                     selectedMessageGuid, threadIdentifier ?: @"(none)");
        } else {
            clearThreadContextForChat(chat, nil);
        }
        id imMessage = buildIMMessage(body, subjectAttr, effectId, threadIdentifier,
                                      parentItem,
                                      selectedMessageGuid, associatedType,
                                      NSMakeRange(0, body.length),
                                      nil, transferGuids, NO, NO, nil);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct multipart IMMessage");
        }
        if (parentMessage
            && [imMessage respondsToSelector:@selector(setThreadOriginator:)]) {
            [imMessage performSelector:@selector(setThreadOriginator:)
                            withObject:parentMessage];
        }
        if (threadIdentifier
            && [imMessage respondsToSelector:@selector(setThreadIdentifier:)]) {
            [imMessage performSelector:@selector(setThreadIdentifier:)
                            withObject:threadIdentifier];
        }
        for (IMFileTransfer *transfer in transfers) {
            NSString *registerErr = nil;
            if (!registerPreparedTransfer(transfer, &registerErr)) {
                return errorResponse(requestId,
                    registerErr.length ? registerErr : @"Could not register attachment transfer");
            }
        }
        dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        NSString *guid = outgoingMessageGuid(imMessage);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"transferGuids": transferGuids,
            @"parts_count": @(partIndex)
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-multipart failed: %@", exception.reason]);
    }
}

/// Build an attachment-bearing attributed string. The placeholder is an OBJ
/// replacement character (￼) tagged with the IMCore attachment attributes
/// (`__kIMFileTransferGUIDAttributeName`, `__kIMFilenameAttributeName`,
/// `__kIMMessagePartAttributeName`, `__kIMBaseWritingDirectionAttributeName`).
/// Without these attributes Messages.app sends an empty-body message and never
/// links the attachment row in chat.db.
static NSAttributedString *buildAttachmentAttributed(NSString *transferGuid,
                                                     NSString *filename,
                                                     NSInteger partIndex) {
    NSDictionary *attrs = @{
        @"__kIMBaseWritingDirectionAttributeName": @"-1",
        @"__kIMFileTransferGUIDAttributeName": transferGuid ?: @"",
        @"__kIMFilenameAttributeName": filename ?: @"",
        @"__kIMMessagePartAttributeName": @(partIndex),
    };
    return [[NSAttributedString alloc] initWithString:@"￼" attributes:attrs];
}

static void setIntegerProperty(id object, SEL selector, NSInteger value) {
    if (!object || ![object respondsToSelector:selector]) return;
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:selector];
    [inv setTarget:object];
    [inv setArgument:&value atIndex:2];
    [inv invoke];
}

