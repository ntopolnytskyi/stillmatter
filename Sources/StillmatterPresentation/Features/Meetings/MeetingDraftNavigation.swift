import Combine
import Foundation

/// Owns the lifetime of one draft-protected departure, including recovery after a
/// failed save. The native adapter presents choices; it never chooses a continuation.
@MainActor
public final class MeetingDraftNavigation: ObservableObject {
    public enum Context: Equatable { case selection, workspacePreparation, workspaceChange }
    public enum Recovery: Equatable { case reloadLatest, keepEditing }

    /// Identity of the departure shown by an adapter. Only this module creates tokens.
    public struct Token: Equatable { fileprivate let id = UUID() }
    public struct Prompt: Equatable {
        public enum Kind: Equatable { case decision, saveFailure(String) }
        public let token: Token
        public let context: Context
        public let kind: Kind
    }
    @Published public private(set) var prompt: Prompt?

    private enum Activity { case deciding, saving, failed, reloading }
    private struct Request {
        let token = Token()
        let context: Context
        let continuation: (Bool) -> Void
        var activity = Activity.deciding
    }

    private let detail: MeetingDetailModel
    private var request: Request?
    private var reloadObservation: AnyCancellable?
    public var context: Context? { request?.context }

    init(detail: MeetingDetailModel) { self.detail = detail }

    /// Replacing a destination rejects the old continuation before installing the new one.
    @discardableResult
    func begin(_ context: Context, continuation: @escaping (Bool) -> Void) -> Token {
        cancel()
        let current = Request(context: context, continuation: continuation)
        request = current
        prompt = Prompt(token: current.token, context: context, kind: .decision)
        return current.token
    }

    public func isCurrent(_ prompt: Prompt) -> Bool {
        guard let request, request.token == prompt.token else { return false }
        switch prompt.kind {
        case .decision: return request.activity == .deciding
        case .saveFailure: return request.activity == .failed
        }
    }

    public func resolve(_ decision: MeetingSelectionDecision, for token: Token,
                        completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let current = request, current.token == token, current.activity != .saving, current.activity != .reloading else { return }
        switch decision {
        case .cancel:
            finish(allow: false)
            completion?(.success(()))
        case .discard:
            detail.discardDrafts()
            finish(allow: true)
            completion?(.success(()))
        case .save:
            request?.activity = .saving
            prompt = nil
            detail.saveDirtyDrafts { [weak self] result in
                guard let self, self.request?.token == current.token else { return }
                switch result {
                case .success: self.finish(allow: true)
                case let .failure(error):
                    self.request?.activity = .failed
                    self.prompt = Prompt(token: current.token, context: current.context,
                                         kind: .saveFailure(error.localizedDescription))
                }
                completion?(result)
            }
        }
    }

    /// Reload Latest is an explicit discard only after a fresh successful read.
    /// A failed read rejects this departure and preserves the user's draft.
    public func recover(_ recovery: Recovery, for token: Token) {
        guard let current = request, current.token == token, current.activity == .failed else { return }
        guard recovery == .reloadLatest else { finish(allow: false); return }
        request?.activity = .reloading
        prompt = nil
        // A newer canonical refresh may supersede our read. The explicit reload intent
        // follows its committed result instead of waiting on a canceled callback.
        reloadObservation = detail.$loadState.dropFirst().sink { [weak self] state in
            Task { @MainActor in
                // @Published delivers before storing its value; let the canonical
                // read finish applying before a continuation changes selection.
                guard let self, self.request?.token == current.token else { return }
                switch state {
                case .loaded:
                    self.detail.reloadDraftsAfterConfirmation()
                    self.finish(allow: true)
                case .failed, .unavailable: self.finish(allow: false)
                case .idle, .loading: break
                }
            }
        }
        detail.refreshSelectedDetail()
    }

    func cancel() { finish(allow: false) }

    private func finish(allow: Bool) {
        let continuation = request?.continuation
        request = nil
        prompt = nil
        reloadObservation = nil
        continuation?(allow)
    }
}
