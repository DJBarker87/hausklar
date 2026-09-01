import Foundation

/// A completed response whose body was bounded while URLSession delivered it.
/// Successful file transfers expose `fileURL`; every other transfer exposes
/// `data`. The two are intentionally mutually exclusive. The unchecked bridge
/// exists only for Foundation's immutable-after-delivery `HTTPURLResponse`.
struct BoundedURLSessionResponse: @unchecked Sendable {
    let data: Data?
    let fileURL: URL?
    let response: HTTPURLResponse
}

/// Receives every response chunk through URLSession's delegate API so an
/// untrusted server can never make an async convenience method materialise an
/// unbounded body. The response status selects either the caller's success cap
/// or the small error-body cap before the first byte is accepted.
///
/// `lock` guards the transfer registry and every mutable field of each registered
/// `Transfer`. The terminal delegate callback removes its transfer while holding
/// that lock; an earlier callback must therefore finish first, and a later one
/// finds no capability to mutate. URLSession defines completion as the terminal
/// callback for a task, so the removed transfer can then be closed and its
/// continuation resumed exactly once. That terminal-transition invariant is the
/// basis for this unchecked Sendable conformance.
final class BoundedURLSessionTransportDelegate: AuthenticatedRedirectDelegate,
    URLSessionDataDelegate, @unchecked Sendable
{

    private enum Output {
        case memory
        case file(URL)
    }

    private final class Transfer {
        let output: Output
        let successMaximumBytes: Int
        let errorMaximumBytes: Int
        let continuation: CheckedContinuation<BoundedURLSessionResponse, Error>
        var response: HTTPURLResponse?
        var maximumBytes = 0
        var receivedBytes = 0
        var data = Data()
        var fileHandle: FileHandle?
        var terminalError: Error?

        init(
            output: Output,
            successMaximumBytes: Int,
            errorMaximumBytes: Int,
            continuation: CheckedContinuation<BoundedURLSessionResponse, Error>
        ) {
            self.output = output
            self.successMaximumBytes = successMaximumBytes
            self.errorMaximumBytes = errorMaximumBytes
            self.continuation = continuation
        }
    }

    /// URLSession cancellation can race task installation. `lock` serializes
    /// the task reference and the sticky cancelled bit so exactly the installed
    /// transport task observes cancellation.
    private final class CancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var isCancelled = false

        func install(_ task: URLSessionTask) {
            let shouldCancel = lock.withLock { () -> Bool in
                self.task = task
                return isCancelled
            }
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            let task = lock.withLock { () -> URLSessionTask? in
                isCancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    func response(
        for request: URLRequest,
        in session: URLSession,
        successMaximumBytes: Int,
        errorMaximumBytes: Int
    ) async throws -> BoundedURLSessionResponse {
        try await perform(
            in: session,
            successMaximumBytes: successMaximumBytes,
            errorMaximumBytes: errorMaximumBytes,
            output: .memory,
            makeTask: { $0.dataTask(with: request) }
        )
    }

    func uploadResponse(
        for request: URLRequest,
        fromFile fileURL: URL,
        in session: URLSession,
        successMaximumBytes: Int,
        errorMaximumBytes: Int
    ) async throws -> BoundedURLSessionResponse {
        try await perform(
            in: session,
            successMaximumBytes: successMaximumBytes,
            errorMaximumBytes: errorMaximumBytes,
            output: .memory,
            makeTask: { $0.uploadTask(with: request, fromFile: fileURL) }
        )
    }

    func fileResponse(
        for request: URLRequest,
        to fileURL: URL,
        in session: URLSession,
        successMaximumBytes: Int,
        errorMaximumBytes: Int
    ) async throws -> BoundedURLSessionResponse {
        try await perform(
            in: session,
            successMaximumBytes: successMaximumBytes,
            errorMaximumBytes: errorMaximumBytes,
            output: .file(fileURL),
            makeTask: { $0.dataTask(with: request) }
        )
    }

    private func perform(
        in session: URLSession,
        successMaximumBytes: Int,
        errorMaximumBytes: Int,
        output: Output,
        makeTask: @escaping (URLSession) -> URLSessionDataTask
    ) async throws -> BoundedURLSessionResponse {
        guard successMaximumBytes > 0, errorMaximumBytes > 0 else {
            throw BoundedHTTPPayload.ValidationError.invalidResponse
        }
        let cancellation = CancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = makeTask(session)
                let transfer = Transfer(
                    output: output,
                    successMaximumBytes: successMaximumBytes,
                    errorMaximumBytes: errorMaximumBytes,
                    continuation: continuation
                )
                lock.withLock { transfers[task.taskIdentifier] = transfer }
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition = lock.withLock { () -> URLSession.ResponseDisposition in
            guard let transfer = transfers[dataTask.taskIdentifier] else { return .cancel }
            guard transfer.terminalError == nil,
                let httpResponse = response as? HTTPURLResponse
            else {
                transfer.terminalError = BoundedHTTPPayload.ValidationError.invalidResponse
                return .cancel
            }
            let success = (200...299).contains(httpResponse.statusCode)
            let maximumBytes =
                success
                ? transfer.successMaximumBytes
                : transfer.errorMaximumBytes
            let expectedBytes = httpResponse.expectedContentLength
            guard expectedBytes == NSURLSessionTransferSizeUnknown || expectedBytes >= 0 else {
                transfer.terminalError = BoundedHTTPPayload.ValidationError.invalidResponse
                return .cancel
            }
            guard
                expectedBytes == NSURLSessionTransferSizeUnknown
                    || expectedBytes <= Int64(maximumBytes)
            else {
                transfer.terminalError =
                    BoundedHTTPPayload.ValidationError.declaredSizeExceedsMaximum
                return .cancel
            }

            transfer.response = httpResponse
            transfer.maximumBytes = maximumBytes
            if success, case .file(let fileURL) = transfer.output {
                do {
                    transfer.fileHandle = try FileHandle(forWritingTo: fileURL)
                } catch {
                    transfer.terminalError = error
                    return .cancel
                }
            }
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard let transfer = transfers[dataTask.taskIdentifier],
                transfer.terminalError == nil
            else { return false }
            let (newByteCount, overflow) = transfer.receivedBytes
                .addingReportingOverflow(data.count)
            guard !overflow, newByteCount <= transfer.maximumBytes else {
                transfer.terminalError =
                    BoundedHTTPPayload.ValidationError.actualSizeExceedsMaximum
                return true
            }
            do {
                if let fileHandle = transfer.fileHandle {
                    try fileHandle.write(contentsOf: data)
                } else {
                    transfer.data.append(data)
                }
                transfer.receivedBytes = newByteCount
                return false
            } catch {
                transfer.terminalError = error
                return true
            }
        }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) })
        else { return }

        var completionError = transfer.terminalError ?? error
        if let fileHandle = transfer.fileHandle {
            do {
                try fileHandle.synchronize()
                try fileHandle.close()
            } catch {
                if completionError == nil { completionError = error }
            }
        }
        if let completionError {
            transfer.continuation.resume(throwing: completionError)
            return
        }
        guard let response = transfer.response else {
            transfer.continuation.resume(
                throwing: BoundedHTTPPayload.ValidationError.invalidResponse
            )
            return
        }
        switch transfer.output {
        case .memory:
            transfer.continuation.resume(
                returning: BoundedURLSessionResponse(
                    data: transfer.data,
                    fileURL: nil,
                    response: response
                )
            )
        case .file(let fileURL):
            if (200...299).contains(response.statusCode) {
                transfer.continuation.resume(
                    returning: BoundedURLSessionResponse(
                        data: nil,
                        fileURL: fileURL,
                        response: response
                    )
                )
            } else {
                transfer.continuation.resume(
                    returning: BoundedURLSessionResponse(
                        data: transfer.data,
                        fileURL: nil,
                        response: response
                    )
                )
            }
        }
    }
}
