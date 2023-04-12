import Foundation

@MainActor
final class QueryableManager<Input, Result>: ObservableObject where Input: Sendable, Result: Sendable {
    private let queryConflictPolicy: QueryConflictPolicy
    var storedContinuationState: ContinuationState?

    /// Optional item storing the input value for a query and is used to indicate if the query has started, which usually coincides with a presentation being shown in a ``Puddles/Provider`` or ``Puddles/Navigator``.
    @Published var itemContainer: ItemContainer?

    init(queryConflictPolicy: QueryConflictPolicy) {
        self.queryConflictPolicy = queryConflictPolicy
    }

    func storeContinuation(
        _ newContinuation: CheckedContinuation<Result, Swift.Error>,
        withId id: UUID,
        item: Input
    ) {
        if let storedContinuationState {
            switch queryConflictPolicy {
            case .cancelPreviousQuery:
                logger.warning("Cancelling previous query of »\(Result.self, privacy: .public)« to allow new query.")
                storedContinuationState.continuation.resume(throwing: QueryCancellationError())
                self.storedContinuationState = nil
                self.itemContainer = nil
            case .cancelNewQuery:
                logger.warning("Cancelling new query of »\(Result.self, privacy: .public)« because another query is ongoing.")
                newContinuation.resume(throwing: QueryCancellationError())
                return
            }
        }

        let resolver = QueryResolver<Result> { [weak self] result in
            self?.resumeContinuation(returning: result, queryId: id)
        } errorHandler: { [weak self] error in
            self?.resumeContinuation(throwing: error, queryId: id)
        }

        storedContinuationState = .init(queryId: id, continuation: newContinuation)
        itemContainer = .init(queryId: id, item: item, resolver: resolver)
    }

    private func resumeContinuation(returning result: Result, queryId: UUID) {
        guard itemContainer?.id == queryId else { return }
        storedContinuationState?.continuation.resume(returning: result)
        storedContinuationState = nil
        itemContainer = nil
    }

    private func resumeContinuation(throwing error: Error, queryId: UUID) {
        guard itemContainer?.id == queryId else { return }
        storedContinuationState?.continuation.resume(throwing: error)
        storedContinuationState = nil
        itemContainer = nil
    }

    func autoCancelContinuation(id: UUID, reason: AutoCancelReason) {
        // If the user cancels a query programmatically and immediately starts the next one, we need to prevent the `QueryInternalError.queryAutoCancel` from the `onDisappear` handler of the canceled query to cancel the new query. That's why the presentations store an id
        if storedContinuationState?.queryId == id {
            switch reason {
            case .presentationEnded:
                logger.notice("Cancelling query of »\(Result.self, privacy: .public)« because presentation has terminated.")
            case .taskCancelled:
                logger.notice("Cancelling query of »\(Result.self, privacy: .public)« because the task was cancelled.")
            }

            storedContinuationState?.continuation.resume(throwing: QueryCancellationError())
            storedContinuationState = nil
            itemContainer = nil
        }
    }

    struct ItemContainer: Sendable, Identifiable {
        var id: UUID { queryId }
        let queryId: UUID
        var item: Input
        var resolver: QueryResolver<Result>
    }

    struct ContinuationState: Sendable {
        let queryId: UUID
        var continuation: CheckedContinuation<Result, Swift.Error>
    }

    enum AutoCancelReason {
        case presentationEnded
        case taskCancelled
    }
}
