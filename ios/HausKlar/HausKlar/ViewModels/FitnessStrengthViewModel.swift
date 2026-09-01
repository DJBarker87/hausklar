import Foundation
import Combine
import SwiftUI
import os

private let fitnessStrengthViewModelLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessStrengthViewModel"
)

@MainActor
final class FitnessStrengthViewModel: FitnessViewModelBase {
    @Published var activeWorkout: FitnessStrengthSession?
    @Published var workoutExercises: [FitnessWorkoutExercise] = []
    @Published var exercises: [FitnessExercise] = []
    @Published var plans: [FitnessPlannedSession] = []
    @Published var plannedExercises: [FitnessPlannedStrengthExercise] = []
    @Published var setups: [String: [FitnessExerciseSetup]] = [:]
    @Published var comparable: [String: [FitnessComparableSet]] = [:]
    @Published var activeIssues: [FitnessBodyIssue] = []
    @Published var latestBodyweight: FitnessBodyMeasurement?
    @Published var suggestions: [FitnessStrengthSuggestion] = []
    @Published var bodyLocations: [FitnessBodyLocation] = FitnessBodyLocation.fallback
    @Published var pendingMutationCount = 0
    @Published var savedWorkouts: [FitnessSavedStrengthWorkout] = []
    @Published var recentSessions: [FitnessStrengthSession] = []

    private let repository: FitnessRepository
    private let service: FitnessStrengthService
    private var detailSessionId: String?
    private var detailPlanId: String?

    init(
        repository: FitnessRepository = .shared,
        service: FitnessStrengthService = .shared
    ) {
        self.repository=repository
        self.service=service
    }

    func load() async {
        await run {
            async let active=repository.activeWorkout()
            async let library=repository.exercises()
            async let plans=repository.plannedSessions()
            async let issues=repository.bodyIssues()
            async let bodyweight=repository.latestCanonicalBodyweight()
            async let pending=repository.pendingStrengthMutationCount()
            async let saved=repository.savedStrengthWorkouts()
            async let recent=repository.recentCompletedStrengthSessions()
            self.activeWorkout=try await active
            self.exercises=try await library
            self.plans=try await plans
            self.activeIssues=try await issues.filter { $0.resolvedAt == nil && $0.status != "resolved" }
            self.latestBodyweight=try await bodyweight
            self.pendingMutationCount=try await pending
            self.savedWorkouts=try await saved
            self.recentSessions=try await recent
            try await reloadActiveDetail()
        }
        async let locations=service.bodyLocations()
        do { suggestions=try await service.suggestions() } catch { suggestions=[] }
        bodyLocations=await locations
    }

    func search(_ query: String) async {
        do {
            exercises=try await withFitnessStore { try await repository.exercises(search: query) }
        }
        catch { errorMessage=error.localizedDescription }
    }

    func start(
        title: String,
        plan: FitnessPlannedSession?,
        readiness: Int?,energy: Int?,soreness: Int?,motivation: Int?,
        bodyweight: FitnessBodyweightChoice
    ) async -> Bool {
        var succeeded=false
        await run {
            activeWorkout=try await repository.startWorkout(
                title: title,planId: plan?.id,readiness: readiness,energy: energy,
                soreness: soreness,motivation: motivation,bodyweight: bodyweight
            )
            try await reloadActiveDetail()
            pendingMutationCount=try await repository.pendingStrengthMutationCount()
            succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func start(
        savedWorkout: FitnessSavedStrengthWorkout,
        readiness: Int?,energy: Int?,soreness: Int?,motivation: Int?,
        bodyweight: FitnessBodyweightChoice
    ) async -> Bool {
        var succeeded=false
        await run {
            let plan=try await repository.createPlan(from: savedWorkout)
            activeWorkout=try await repository.startWorkout(
                title: plan.title,planId: plan.id,readiness: readiness,energy: energy,
                soreness: soreness,motivation: motivation,bodyweight: bodyweight
            )
            plans=try await repository.plannedSessions()
            try await reloadActiveDetail()
            succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func start(
        previousSession: FitnessStrengthSession,
        readiness: Int?,energy: Int?,soreness: Int?,motivation: Int?,
        bodyweight: FitnessBodyweightChoice
    ) async -> Bool {
        var succeeded=false
        await run {
            let plan=try await repository.copyCompletedSessionToPlan(previousSession)
            activeWorkout=try await repository.startWorkout(
                title: plan.title,planId: plan.id,readiness: readiness,energy: energy,
                soreness: soreness,motivation: motivation,bodyweight: bodyweight
            )
            plans=try await repository.plannedSessions()
            try await reloadActiveDetail()
            succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func createAndOptionallyAdd(name: String,category: String,mode: FitnessLoadMode) async -> Bool {
        var succeeded=false
        await run {
            let exercise=try await repository.createExercise(name: name,category: category,loadMode: mode)
            exercises=try await repository.exercises()
            if let activeWorkout {
                _=try await repository.addExercise(exercise.id,to: activeWorkout.id)
                try await reloadActiveDetail()
            }
            succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func addExercise(_ exercise: FitnessExercise,setupId: String? = nil) async -> Bool {
        guard let activeWorkout else { return false }
        var succeeded=false
        await run {
            _=try await repository.addExercise(exercise.id,to: activeWorkout.id,setupId: setupId)
            try await reloadActiveDetail(); succeeded=true; HapticManager.selection()
        }
        return succeeded
    }

    func substitute(_ current: FitnessSessionExercise,with exercise: FitnessExercise) async -> Bool {
        var succeeded=false
        await run {
            try await repository.substituteExercise(sessionExerciseId: current.id,with: exercise.id)
            comparable.removeValue(forKey: current.id)
            try await reloadActiveDetail(); succeeded=true; HapticManager.selection()
        }
        return succeeded
    }

    func loadSetups(for exerciseId: String) async {
        do {
            setups[exerciseId]=try await withFitnessStore {
                try await repository.setups(for: exerciseId)
            }
        }
        catch { errorMessage=error.localizedDescription }
    }

    func previewExerciseMerge(sourceId: String,targetId: String) async -> FitnessExerciseMergePreview? {
        do {
            errorMessage=nil
            return try await service.previewExerciseMerge(sourceId: sourceId,targetId: targetId)
        } catch {
            errorMessage=error.localizedDescription
            return nil
        }
    }

    func mergeExercises(_ preview: FitnessExerciseMergePreview) async -> Bool {
        var succeeded=false
        await run {
            _=try await service.mergeExercises(sourceId: preview.sourceId,targetId: preview.targetId)
            exercises=try await repository.exercises()
            succeeded=true
            HapticManager.success()
        }
        return succeeded
    }

    func previewSetupMerge(sourceId: String,targetId: String) async -> FitnessExerciseSetupMergePreview? {
        do {
            errorMessage=nil
            return try await service.previewSetupMerge(sourceId: sourceId,targetId: targetId)
        } catch {
            errorMessage=error.localizedDescription
            return nil
        }
    }

    func mergeSetups(_ preview: FitnessExerciseSetupMergePreview,exerciseId: String) async -> Bool {
        var succeeded=false
        await run {
            _=try await service.mergeSetups(sourceId: preview.sourceId,targetId: preview.targetId)
            setups[exerciseId]=try await repository.setups(for: exerciseId)
            succeeded=true
            HapticManager.success()
        }
        return succeeded
    }

    func saveSet(to exercise: FitnessSessionExercise,draft: FitnessStrengthSetDraft) async -> Bool {
        guard let activeWorkout else { return false }
        var succeeded=false
        await run {
            _=try await repository.saveSet(to: exercise.id,sessionId: activeWorkout.id,draft: draft)
            try await reloadActiveDetail(); succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func updateSet(
        group: FitnessSetGroup, component: FitnessSetComponent,
        draft: FitnessStrengthSetDraft
    ) async -> Bool {
        guard let activeWorkout else { return false }
        var succeeded=false
        await run {
            _=try await repository.updateSet(
                group: group, component: component, sessionId: activeWorkout.id, draft: draft
            )
            try await reloadActiveDetail(); succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func workoutExportText(for session: FitnessStrengthSession) async -> String? {
        do {
            let exercises = session.id == activeWorkout?.id
                ? workoutExercises
                : try await withFitnessStore { try await repository.workoutExercises(sessionId: session.id) }
            return FitnessStrengthTextExport.text(session: session,exercises: exercises)
        } catch {
            errorMessage=error.localizedDescription
            return nil
        }
    }

    func addComponent(
        to group: FitnessSetGroup,structure: FitnessSetStructure,draft: FitnessStrengthSetDraft
    ) async -> Bool {
        var succeeded=false
        await run {
            _=try await repository.addComponent(to: group.id,structure: structure,draft: draft)
            try await reloadActiveDetail(); succeeded=true; HapticManager.selection()
        }
        return succeeded
    }

    func skip(_ group: FitnessSetGroup) async {
        await run { try await repository.skipSet(groupId: group.id); try await reloadActiveDetail() }
    }

    func changeSetup(for exercise: FitnessSessionExercise,to setup: FitnessExerciseSetup) async -> Bool {
        var succeeded=false
        await run {
            try await repository.changeSetup(sessionExerciseId: exercise.id,setupId: setup.id)
            comparable.removeValue(forKey: exercise.id)
            try await reloadActiveDetail(); succeeded=true
        }
        return succeeded
    }

    func moveExercises(from offsets: IndexSet,to destination: Int) async {
        var reordered=workoutExercises
        reordered.move(fromOffsets: offsets,toOffset: destination)
        await run {
            try await repository.reorderSessionExercises(
                sessionId: try requireWorkout().id,orderedIds: reordered.map(\.id)
            )
            workoutExercises=reordered
        }
    }

    func startRest(seconds: Int) async {
        guard let activeWorkout else { return }
        await run {
            try await service.startRestTimer(sessionId: activeWorkout.id,seconds: seconds)
            self.activeWorkout=try await repository.activeWorkout()
        }
    }

    func clearRest() async {
        guard let activeWorkout else { return }
        await run {
            try await service.clearRestTimer(sessionId: activeWorkout.id)
            self.activeWorkout=try await repository.activeWorkout()
        }
    }

    func addLateReadiness(_ value: Int) async {
        guard let activeWorkout else { return }
        await run {
            try await repository.addLateReadiness(value,sessionId: activeWorkout.id)
            self.activeWorkout=try await repository.activeWorkout()
        }
    }

    func finish(
        rpe: Double?,performance: Int?,matchedPlanKey: String?,note: String?,issue: NewBodyIssue?
    ) async -> Bool {
        guard let activeWorkout else { return false }
        var succeeded=false
        await run {
            try await repository.finishWorkout(
                sessionId: activeWorkout.id,rpe: rpe,performance: performance,
                note: note,matchedPlanKey: matchedPlanKey,issue: issue
            )
            await clearRestTimerAfterClosingSession(
                activeWorkout.id,
                completedAction: "Workout saved"
            )
            self.activeWorkout=nil; workoutExercises=[]; plannedExercises=[]
            succeeded=true; HapticManager.success()
        }
        return succeeded
    }

    func abandon() async {
        guard let activeWorkout else { return }
        await run {
            try await repository.abandonWorkout(sessionId: activeWorkout.id)
            await clearRestTimerAfterClosingSession(
                activeWorkout.id,
                completedAction: "Workout abandoned"
            )
            self.activeWorkout=nil; workoutExercises=[]; plannedExercises=[]
        }
    }

    private func clearRestTimerAfterClosingSession(
        _ sessionId: String,
        completedAction: String
    ) async {
        do {
            try await service.clearRestTimer(sessionId: sessionId)
        } catch {
            // Finishing/abandoning is already durable at this point. Do not
            // misreport that successful mutation as failed, but make the stale
            // notification risk explicit so the user is never surprised.
            errorMessage = "\(completedAction), but its rest notification could not be cleared. You can dismiss it if it appears."
            fitnessStrengthViewModelLogger.error(
                "A closed workout retained its rest-notification cleanup: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func target(for group: FitnessSetGroup) -> FitnessPlannedStrengthSet? {
        guard let id=group.plannedSetId else { return nil }
        return plannedExercises.lazy.flatMap(\.sets).first { $0.id == id }
    }

    func suggestion(for exercise: FitnessSessionExercise) -> FitnessStrengthSuggestion? {
        suggestions.first { $0.exerciseId == exercise.exerciseId }
            ?? FitnessStrengthSemantics.localSuggestion(
                exercise: exercise,comparable: comparable[exercise.id] ?? []
            )
    }

    func plannedSubstitutionIds(for exercise: FitnessSessionExercise) -> [String] {
        guard let plannedExerciseId=exercise.plannedExerciseId else { return [] }
        return plannedExercises.first { $0.id == plannedExerciseId }?.substitutionExerciseIds ?? []
    }

    private func reloadActiveDetail() async throws {
        guard let activeWorkout else {
            workoutExercises=[]; plannedExercises=[]; comparable=[:]; setups=[:]
            detailSessionId=nil; detailPlanId=nil
            return
        }
        if detailSessionId != activeWorkout.id {
            comparable=[:]
            setups=[:]
            plannedExercises=[]
            detailPlanId=nil
            detailSessionId=activeWorkout.id
        }
        workoutExercises=try await repository.workoutExercises(sessionId: activeWorkout.id)
        if let planId=activeWorkout.plannedSessionId {
            if detailPlanId != planId {
                plannedExercises=try await repository.plannedStrengthExercises(planId: planId)
                detailPlanId=planId
            }
        } else {
            plannedExercises=[]
            detailPlanId=nil
        }
        let visibleItemIDs=Set(workoutExercises.map(\.id))
        comparable=comparable.filter { visibleItemIDs.contains($0.key) }
        let visibleExerciseIDs=Set(workoutExercises.map(\.exercise.exerciseId))
        setups=setups.filter { visibleExerciseIDs.contains($0.key) }
        for item in workoutExercises where comparable[item.id] == nil {
            comparable[item.id]=try await repository.comparableSets(for: item.exercise)
        }
        for exerciseId in visibleExerciseIDs where setups[exerciseId] == nil {
            setups[exerciseId]=try await repository.setups(for: exerciseId)
        }
        pendingMutationCount=try await repository.pendingStrengthMutationCount()
    }

    private func requireWorkout() throws -> FitnessStrengthSession {
        guard let activeWorkout else { throw FitnessRepositoryError.noActiveWorkout }
        return activeWorkout
    }
}
