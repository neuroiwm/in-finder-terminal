import Foundation

final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func call(_ action: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: action)
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
