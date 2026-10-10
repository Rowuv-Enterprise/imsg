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

/// How Messages sees the Focus of `address`: IMHandleAvailabilityManager's
/// value for that handle, read once. With `fetch`, Messages is first asked to
/// update the value; that is one request, never an observation that outlives
/// this call, so the value read here can be the one from before the update.
static NSDictionary *focusStatusForAddress(NSString *address, BOOL fetch) {
    @try {
        Class managerClass = NSClassFromString(@"IMHandleAvailabilityManager");
        if (![managerClass respondsToSelector:@selector(sharedInstance)]) {
            return @{@"focus_supported": @NO};
        }
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));
        SEL readSel = NSSelectorFromString(@"availabilityForHandle:");
        if (![manager respondsToSelector:readSel]) return @{@"focus_supported": @NO};
        IMAccount *account = activeIMessageAccount();
        id handle = [account respondsToSelector:@selector(imHandleWithID:)]
            ? [account imHandleWithID:address]
            : nil;
        if (!handle) return @{@"focus_supported": @YES, @"focus_handle": @NO};
        BOOL fetchStarted = NO;
        if (fetch) {
            SEL fetchSel = NSSelectorFromString(@"fetchUpdatedStatusForHandle:completion:");
            if (![manager respondsToSelector:fetchSel]) {
                fetchSel = NSSelectorFromString(@"_fetchUpdatedStatusForHandle:completion:");
            }
            if ([manager respondsToSelector:fetchSel]) {
                void (^done)(void) = ^{};
                ((void (*)(id, SEL, id, id))objc_msgSend)(manager, fetchSel, handle, done);
                fetchStarted = YES;
            }
        }
        NSInteger value = ((NSInteger (*)(id, SEL, id))objc_msgSend)(manager, readSel, handle);
        return @{
            @"focus_supported": @YES,
            @"focus_handle": @YES,
            @"focus_status": @(value),
            @"focus_fetch_started": @(fetchStarted)
        };
    } @catch (NSException *ex) {
        return @{@"focus_supported": @YES, @"focus_error": ex.reason ?: @"focus read failed"};
    }
}

/// The names of the Objective-C properties of `cls` and its superclasses below
/// NSObject. Names only: a caller learns the shape of an object, never a value.
static NSArray<NSString *> *propertyNamesOfClass(Class cls) {
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (Class current = cls; current && current != [NSObject class];
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(current, &count);
        for (unsigned int i = 0; i < count && names.count < 200; i++) {
            const char *name = property_getName(properties[i]);
            if (name) [names addObject:[NSString stringWithUTF8String:name]];
        }
        free(properties);
    }
    return [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

/// Whether `address` shares its location with this account, as Messages
/// already knows it: IMFMFSession's own answers, read once. Nothing here asks
/// Find My to track, refresh, start or stop anything. When the handle does
/// share, the class of the location object and the names of its properties
/// are returned, never a coordinate or any other value.
static NSDictionary *locationSharingForAddress(NSString *address) {
    @try {
        Class sessionClass = NSClassFromString(@"IMFMFSession");
        if (![sessionClass respondsToSelector:@selector(sharedInstance)]) {
            return @{@"location_supported": @NO,
                     @"location_error": @"IMFMFSession is not available"};
        }
        id session = ((id (*)(id, SEL))objc_msgSend)(sessionClass, @selector(sharedInstance));
        SEL sharingSel = NSSelectorFromString(@"handleIsSharingLocationWithMe:");
        if (!session || ![session respondsToSelector:sharingSel]) {
            return @{@"location_supported": @NO,
                     @"location_error": @"Find My has no session in this process"};
        }
        NSMutableDictionary *result = [@{@"location_supported": @YES} mutableCopy];
        SEL stateSel = NSSelectorFromString(@"fmfProvisionedState");
        if ([session respondsToSelector:stateSel]) {
            NSUInteger state = ((NSUInteger (*)(id, SEL))objc_msgSend)(session, stateSel);
            result[@"location_provisioned"] = @(state);
        }
        IMAccount *account = activeIMessageAccount();
        id handle = [account respondsToSelector:@selector(imHandleWithID:)]
            ? [account imHandleWithID:address]
            : nil;
        result[@"location_handle"] = @(handle != nil);
        if (!handle) return result;
        BOOL sharing = ((BOOL (*)(id, SEL, id))objc_msgSend)(session, sharingSel, handle);
        result[@"location_sharing"] = @(sharing);
        SEL locationSel = NSSelectorFromString(@"findMyLocationForHandle:");
        if (sharing && [session respondsToSelector:locationSel]) {
            id location = ((id (*)(id, SEL, id))objc_msgSend)(session, locationSel, handle);
            if (location) {
                result[@"location_class"] = NSStringFromClass([location class]);
                result[@"location_keys"] = propertyNamesOfClass([location class]);
            }
        }
        return result;
    } @catch (NSException *ex) {
        return @{@"location_supported": @YES,
                 @"location_error": ex.reason ?: @"location read failed"};
    }
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
    if ([params[@"focus"] boolValue]) {
        [result addEntriesFromDictionary:
            focusStatusForAddress(address, [params[@"focusFetch"] boolValue])];
    }
    if ([params[@"location"] boolValue]) {
        [result addEntriesFromDictionary:locationSharingForAddress(address)];
    }
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

