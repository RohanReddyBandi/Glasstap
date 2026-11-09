import os

/// A value behind an `os_unfair_lock`. `withLockIfAvailable` never blocks, which makes it
/// safe to call from the real-time audio thread.
final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(_ value: Value) {
        self.value = value
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body(&value)
    }

    @discardableResult
    func withLockIfAvailable<Result>(_ body: (inout Value) -> Result) -> Result? {
        guard os_unfair_lock_trylock(lock) else { return nil }
        defer { os_unfair_lock_unlock(lock) }
        return body(&value)
    }
}
