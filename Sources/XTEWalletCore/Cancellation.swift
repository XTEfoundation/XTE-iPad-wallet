// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// True for errors that only mean "this request/task was cancelled" (Swift task
/// cancellation, or URLSession's NSURLErrorCancelled -999, whose text is "cancelled").
/// These are not sync failures and must never be shown to the user.
public func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let u = error as? URLError, u.code == .cancelled { return true }
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
}
