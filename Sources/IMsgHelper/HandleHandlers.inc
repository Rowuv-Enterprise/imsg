/// What Apple answered to lookups this process started: destination ->
/// @[status, date]. Status is Apple's value, or -1 when the answer carried no
/// status for the destination. Read and written on the main queue only.
static NSMutableDictionary<NSString *, NSArray *> *gIDStatusLookups = nil;
static const NSTimeInterval kIDStatusLookupMaxAge = 60.0;

/// The answer of a lookup younger than kIDStatusLookupMaxAge, or nil.
static NSNumber *recentIDStatusLookup(NSString *destination) {
    NSArray *entry = gIDStatusLookups[destination];
    if (entry.count != 2) return nil;
    if (-[(NSDate *)entry[1] timeIntervalSinceNow] > kIDStatusLookupMaxAge) {
        [gIDStatusLookups removeObjectForKey:destination];
        return nil;
    }
    return entry[0];
}

/// Ask Apple whether `destination` is registered for iMessage. The answer
/// arrives later in a block and is kept for the next check. The caller never
/// waits here: handlers run on Messages' main run loop.
static BOOL startIDStatusLookup(id ctrl, NSString *destination) {
    SEL sel = @selector(forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:);
    if (![ctrl respondsToSelector:sel]) return NO;
    void (^block)(NSDictionary *) = ^(NSDictionary *statuses) {
        id value = nil;
        if ([statuses isKindOfClass:[NSDictionary class]]) {
            value = statuses[destination] ?: statuses.allValues.firstObject;
        }
        NSNumber *answered = [value isKindOfClass:[NSNumber class]] ? value : @(-1);
        if (!gIDStatusLookups) gIDStatusLookups = [NSMutableDictionary dictionary];
        gIDStatusLookups[destination] = @[answered, [NSDate date]];
    };
    ((BOOL (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
        ctrl, sel, @[destination], @"com.apple.madrid", @"imsg-bridge",
        dispatch_get_main_queue(), block);
    return YES;
}

static NSDictionary *handleCheckIMessageAvailability(NSInteger requestId, NSDictionary *params) {
    NSString *address = params[@"address"];
    NSString *aliasType = params[@"aliasType"] ?: @"phone";
    BOOL refresh = [params[@"refresh"] boolValue];
    if (!address.length) return errorResponse(requestId, @"Missing address");
    Class q = NSClassFromString(@"IDSIDQueryController");
    if (!q) return errorResponse(requestId, @"IDSIDQueryController unavailable");
    id ctrl = nil;
    @try {
        if ([q respondsToSelector:@selector(sharedInstance)]) {
            ctrl = ((id (*)(id, SEL))objc_msgSend)(q, @selector(sharedInstance));
        } else if ([q respondsToSelector:@selector(sharedController)]) {
            ctrl = ((id (*)(id, SEL))objc_msgSend)(q, @selector(sharedController));
        }
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"controller unavailable");
    }
    if (!ctrl) return errorResponse(requestId, @"controller nil");

    NSString *destination = address;
    if ([aliasType isEqualToString:@"phone"]) {
        if (![destination hasPrefix:@"tel:"]) destination = [@"tel:" stringByAppendingString:destination];
    } else if ([aliasType isEqualToString:@"email"]) {
        if (![destination hasPrefix:@"mailto:"]) destination = [@"mailto:" stringByAppendingString:destination];
    }

    NSInteger status = 0;
    @try {
        SEL privateSel = @selector(_currentIDStatusForDestination:service:listenerID:);
        if ([ctrl respondsToSelector:privateSel]) {
            status = ((NSInteger (*)(id, SEL, id, id, id))objc_msgSend)(
                ctrl, privateSel, destination, @"com.apple.madrid", @"imsg-bridge");
        } else {
            SEL sel = @selector(currentIDStatusForDestination:service:);
            if ([ctrl respondsToSelector:sel]) {
                id result = [ctrl performSelector:sel withObject:destination withObject:nil];
                if ([result isKindOfClass:[NSNumber class]]) {
                    status = [(NSNumber *)result integerValue];
                }
            }
        }
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"availability check failed");
    }

    // A lookup is started only when Messages holds no answer and none was
    // asked for in the last minute, so one address is one question to Apple.
    NSNumber *looked = recentIDStatusLookup(destination);
    BOOL refreshStarted = NO;
    if (status != 1 && status != 2) {
        if (looked.integerValue == 1 || looked.integerValue == 2) {
            status = looked.integerValue;
        } else if (refresh && !looked) {
            @try {
                refreshStarted = startIDStatusLookup(ctrl, destination);
            } @catch (NSException *ex) {
                return errorResponse(requestId, ex.reason ?: @"availability lookup failed");
            }
        }
    }

    NSMutableDictionary *result = [@{
        @"address": address,
        @"alias_type": aliasType,
        @"destination": destination,
        @"id_status": @(status),
        @"available": @(status == 1),
        @"refresh_started": @(refreshStarted)
    } mutableCopy];
    if (looked) result[@"refresh_status"] = looked;
    return successResponse(requestId, result);
}

static NSDictionary *handleDownloadPurgedAttachment(NSInteger requestId, NSDictionary *params) {
    NSString *attachmentGuid = params[@"attachmentGuid"];
    if (!attachmentGuid.length) return errorResponse(requestId, @"Missing attachmentGuid");
    Class ftcClass = NSClassFromString(@"IMFileTransferCenter");
    id ftc = ftcClass ? [ftcClass performSelector:@selector(sharedInstance)] : nil;
    if (!ftc) return errorResponse(requestId, @"FileTransferCenter unavailable");

    SEL sel = @selector(acceptTransfer:);
    if (![ftc respondsToSelector:sel]) {
        return errorResponse(requestId, @"acceptTransfer: not available");
    }
    @try {
        [ftc performSelector:sel withObject:attachmentGuid];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"attachmentGuid": attachmentGuid, @"queued": @YES});
}

