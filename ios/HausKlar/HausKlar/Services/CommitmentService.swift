import Foundation

struct CommitmentLoadResult<Value: Sendable>: Sendable {
    let value: Value
    let isFromCache: Bool
}

final class CommitmentService: @unchecked Sendable {
    static let shared = CommitmentService()

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func openCommitments(refresh: Bool = false) async throws -> CommitmentLoadResult<[Commitment]> {
        let response: APIClient.ProvenancedGet<[Commitment]> = try await apiClient.getWithProvenance(
            "/commitments/",
            queryItems: [
                URLQueryItem(name: "open_only", value: "true"),
                URLQueryItem(name: "limit", value: "100"),
            ],
            cachePolicy: refresh ? .networkThenStale : .cacheFirst
        )
        let values = response.value
            .filter { $0.status.isOpen }
            .sorted {
                if $0.urgency != $1.urgency { return $0.urgency < $1.urgency }
                return $0.updatedAt < $1.updatedAt
            }
        return CommitmentLoadResult(
            value: values,
            isFromCache: response.provenance == .staleFallback
        )
    }

    func commitment(id: String) async throws -> Commitment {
        try await apiClient.get(
            "/commitments/\(id)",
            cachePolicy: .networkOnly
        )
    }

    func familyMembers() async throws -> [FamilyMemberDTO] {
        try await apiClient.get("/family/members")
    }

    func documentOptions() async throws -> [CommitmentDocumentOption] {
        let values: [CommitmentDocumentOption] = try await apiClient.get(
            "/documents/",
            queryItems: [
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "limit", value: "100"),
            ]
        )
        return values.filter { $0.status != "archived" }
    }

    func aiConsent() async throws -> AIConsentStatusDTO {
        try await apiClient.get("/auth/ai-consent", cachePolicy: .networkOnly)
    }

    func createFromSource(
        kind: CommitmentKind,
        visibility: CommitmentVisibility,
        title: String?,
        reviewedText: String,
        sourceDocumentId: String?,
        sourceLabel: String?,
        providerReference: String?,
        supersedesId: String?,
        requestHermes: Bool,
        aiConsentAllowsHermes: Bool,
        metadata: CommitmentMutationMetadata,
        timezone: String = TimeZone.current.identifier
    ) async throws -> CommitmentFromSourceResponse {
        let response: CommitmentFromSourceResponse = try await apiClient.post(
            "/commitments/from-source",
            body: CommitmentFromSourceRequest(
                id: metadata.id,
                kind: kind,
                visibility: visibility,
                text: reviewedText.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceDocumentId: sourceDocumentId,
                sourceLabel: sourceLabel?.nilIfBlank ?? "Reviewed message",
                providerReference: providerReference?.nilIfBlank,
                title: title?.nilIfBlank,
                useHermes: requestHermes && aiConsentAllowsHermes,
                clientNow: metadata.timestamp,
                timezone: timezone.isEmpty ? "Europe/London" : timezone,
                supersedesId: supersedesId,
                clientId: try apiClient.clientId,
                clientTimestamp: metadata.timestamp
            ),
            operationID: metadata.id
        )
        return response
    }

    func queryFreeWindows(_ query: CommitmentFreeWindowQuery) async throws
        -> CommitmentFreeWindowResponse
    {
        try await apiClient.post("/commitments/free-windows/query", body: query)
    }

    func childcareGaps(
        childId: String,
        from: String,
        to: String,
        timezone: String = TimeZone.current.identifier
    ) async throws -> [CommitmentChildcareGap] {
        try await apiClient.get(
            "/commitments/childcare-gaps",
            queryItems: [
                URLQueryItem(name: "child_id", value: childId),
                URLQueryItem(name: "from", value: from),
                URLQueryItem(name: "to", value: to),
                URLQueryItem(
                    name: "timezone",
                    value: timezone.isEmpty ? "Europe/London" : timezone
                ),
            ],
            cachePolicy: .networkOnly
        )
    }

    func create(
        kind: CommitmentKind,
        visibility: CommitmentVisibility,
        title: String,
        summary: String?,
        sources: [CommitmentSource],
        plan: CommitmentPlan,
        groupKey: String?,
        metadata: CommitmentMutationMetadata
    ) async throws -> Commitment {
        try await apiClient.post(
            "/commitments/",
            body: CommitmentCreateRequest(
                id: metadata.id,
                kind: kind,
                visibility: visibility,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: summary?.nilIfBlank,
                sources: sources,
                plan: plan,
                groupKey: groupKey?.nilIfBlank,
                clientId: try apiClient.clientId,
                clientTimestamp: metadata.timestamp
            ),
            operationID: metadata.id
        )
    }

    func update(
        original: Commitment,
        draft: Commitment,
        mayChangeVisibility: Bool,
        metadata: CommitmentMutationMetadata
    ) async throws -> Commitment {
        try await apiClient.patch(
            "/commitments/\(original.id)",
            body: CommitmentUpdateRequest(
                expectedRevision: original.revision,
                visibility: mayChangeVisibility ? draft.visibility : nil,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: draft.summary?.nilIfBlank,
                sources: draft.sources,
                plan: draft.plan,
                groupKey: draft.groupKey?.nilIfBlank,
                clientId: try apiClient.clientId,
                clientTimestamp: metadata.timestamp
            ),
            operationID: metadata.id
        )
    }

    func completeExternalAction(
        commitment: Commitment,
        metadata: CommitmentMutationMetadata
    ) async throws -> Commitment {
        let outcome = commitment.plan.externalAction?.completionOutcome ?? .other
        return try await apiClient.post(
            "/commitments/\(commitment.id)/external-action/complete",
            body: CommitmentActionCompleteRequest(
                expectedRevision: commitment.revision,
                completed: true,
                outcome: outcome,
                clientId: try apiClient.clientId,
                clientTimestamp: metadata.timestamp
            ),
            operationID: metadata.id
        )
    }

    func confirm(
        _ commitment: Commitment,
        metadata: CommitmentMutationMetadata
    ) async throws -> Commitment {
        try await apiClient.post(
            "/commitments/\(commitment.id)/confirm",
            body: CommitmentConfirmRequest(
                expectedRevision: commitment.revision,
                confirmed: true,
                clientId: try apiClient.clientId,
                clientTimestamp: metadata.timestamp
            ),
            operationID: metadata.id
        )
    }

    func decline(
        _ commitment: Commitment,
        reason: String?,
        metadata: CommitmentMutationMetadata
    ) async throws -> Commitment {
        try await apiClient.post(
            "/commitments/\(commitment.id)/decline",
            body: CommitmentDeclineRequest(
                expectedRevision: commitment.revision,
                reason: reason?.nilIfBlank,
                clientId: try apiClient.clientId,
                clientTimestamp: metadata.timestamp
            ),
            operationID: metadata.id
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
