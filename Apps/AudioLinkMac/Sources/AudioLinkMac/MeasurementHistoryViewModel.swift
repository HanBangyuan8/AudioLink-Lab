import AudioLinkCore
import AudioLinkReporting
import AudioLinkStorage
import Combine
import Foundation

@MainActor
final class MeasurementHistoryViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var deviceSearchText = ""
    @Published var qualityFilter = "all"
    @Published var measurementTypeFilter = "all"
    @Published private(set) var runs: [MeasurementHistoryRunSummary] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedRunIDs: Set<UUID> = []
    @Published private(set) var selectedRun: MeasurementHistoryRun?
    @Published private(set) var selectedSession: MeasurementHistorySession?
    @Published private(set) var comparison: MeasurementRunComparison?
    @Published private(set) var repositoryInfo: MeasurementRepositoryInfo?

    private let repository: any MeasurementRepository
    private let pageSize: Int
    private var loadGeneration: UInt64 = 0

    init(repository: any MeasurementRepository, pageSize: Int = 50) {
        self.repository = repository
        self.pageSize = pageSize
    }

    func reload() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        do {
            async let pageTask = repository.runs(matching: query(offset: 0))
            async let infoTask = repository.repositoryInfo()
            let (page, info) = try await (pageTask, infoTask)
            guard loadGeneration == generation else { return }
            runs = page.runs
            totalCount = page.totalCount
            hasMore = page.hasMore
            repositoryInfo = info
            selectedRunIDs.formIntersection(Set(runs.map(\.id)))
            isLoading = false
        } catch {
            guard loadGeneration == generation else { return }
            isLoading = false
            errorMessage = storageMessage(error)
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await repository.runs(matching: query(offset: runs.count))
            runs.append(contentsOf: page.runs)
            totalCount = page.totalCount
            hasMore = page.hasMore
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = storageMessage(error)
        }
    }

    func openRun(id: UUID) async {
        errorMessage = nil
        do {
            guard let run = try await repository.run(id: id),
                  let session = try await repository.session(id: run.sessionID) else {
                throw MeasurementStorageError.recordNotFound(kind: "run", id: id)
            }
            selectedRun = run
            selectedSession = session
        } catch {
            errorMessage = storageMessage(error)
        }
    }

    func updateSelectedSession(name: String, notes: String) async {
        guard let session = selectedSession else { return }
        do {
            try await repository.updateSession(id: session.id, name: name, notes: notes)
            selectedSession = try await repository.session(id: session.id)
            await reload()
        } catch {
            errorMessage = storageMessage(error)
        }
    }

    func deleteRun(id: UUID) async {
        do {
            try await repository.deleteRun(id: id)
            selectedRunIDs.remove(id)
            if selectedRun?.id == id {
                selectedRun = nil
                selectedSession = nil
            }
            await reload()
        } catch {
            errorMessage = storageMessage(error)
        }
    }

    func deleteSelected() async {
        let ids = Array(selectedRunIDs)
        guard !ids.isEmpty else { return }
        do {
            try await repository.deleteRuns(ids: ids)
            selectedRunIDs.removeAll()
            if let selectedRun, ids.contains(selectedRun.id) {
                self.selectedRun = nil
                selectedSession = nil
            }
            await reload()
        } catch {
            errorMessage = storageMessage(error)
        }
    }

    func clearAll() async {
        do {
            try await repository.deleteAll()
            selectedRunIDs.removeAll()
            selectedRun = nil
            selectedSession = nil
            comparison = nil
            await reload()
        } catch {
            errorMessage = storageMessage(error)
        }
    }

    func compareSelected() async {
        guard selectedRunIDs.count >= 2 else { return }
        do {
            let ordered = runs.map(\.id).filter(selectedRunIDs.contains)
            comparison = try await repository.comparison(runIDs: ordered)
        } catch {
            errorMessage = storageMessage(error)
        }
    }

    func clearComparison() {
        comparison = nil
    }

    func exportSelectedJSON() async throws -> Data {
        let orderedIDs = runs.map(\.id).filter(selectedRunIDs.contains)
        guard !orderedIDs.isEmpty else {
            throw MeasurementStorageError.invalidRecord(message: "No runs are selected for export.")
        }
        var exports: [MeasurementHistorySession] = []
        for id in orderedIDs {
            guard let run = try await repository.run(id: id),
                  let session = try await repository.session(id: run.sessionID) else {
                throw MeasurementStorageError.recordNotFound(kind: "run", id: id)
            }
            exports.append(
                MeasurementHistorySession(
                    id: session.id,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    name: session.name,
                    notes: session.notes,
                    measurementType: session.measurementType,
                    savePolicy: session.savePolicy,
                    configurationPayload: session.configurationPayload,
                    configurationSummary: session.configurationSummary,
                    statistics: session.statistics,
                    repeatedStatistics: session.repeatedStatistics,
                    inputDevice: session.inputDevice,
                    outputDevice: session.outputDevice,
                    appVersion: session.appVersion,
                    algorithmVersion: session.algorithmVersion,
                    runs: [run]
                )
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exports)
    }

    func exportSelectedReport(
        format: ReportExportFormat,
        privacy: ReportPrivacyOptions,
        chapters: ReportChapterSelection,
        destination: URL
    ) async throws -> [URL] {
        let orderedIDs = runs.map(\.id).filter(selectedRunIDs.contains)
        guard let firstID = orderedIDs.first,
              let firstRun = try await repository.run(id: firstID),
              let firstSession = try await repository.session(id: firstRun.sessionID) else {
            throw ReportExportError.noRuns
        }
        var selectedRuns: [MeasurementHistoryRun] = []
        for id in orderedIDs {
            if let run = try await repository.run(id: id), run.sessionID == firstSession.id {
                selectedRuns.append(run)
            }
        }
        guard selectedRuns.count == orderedIDs.count else {
            throw ReportExportError.mixedSessions
        }
        let session = MeasurementHistorySession(
            id: firstSession.id,
            createdAt: firstSession.createdAt,
            updatedAt: firstSession.updatedAt,
            name: firstSession.name,
            notes: firstSession.notes,
            measurementType: firstSession.measurementType,
            savePolicy: firstSession.savePolicy,
            configurationPayload: firstSession.configurationPayload,
            configurationSummary: firstSession.configurationSummary,
            statistics: firstSession.statistics,
            repeatedStatistics: firstSession.repeatedStatistics,
            inputDevice: firstSession.inputDevice,
            outputDevice: firstSession.outputDevice,
            appVersion: firstSession.appVersion,
            algorithmVersion: firstSession.algorithmVersion,
            runs: selectedRuns.isEmpty ? [firstRun] : selectedRuns
        )
        let document = ReportDocumentBuilder.make(session: session, privacy: privacy, chapters: chapters)
        return try await ReportExporter.write(document: document, format: format, to: destination)
    }

    private func query(offset: Int) -> MeasurementHistoryQuery {
        MeasurementHistoryQuery(
            searchText: searchText,
            qualityLevels: MeasurementQualityLevel(rawValue: qualityFilter).map { [$0] } ?? [],
            deviceSearchText: deviceSearchText,
            measurementTypes: StoredMeasurementType(rawValue: measurementTypeFilter).map { [$0] } ?? [],
            pageSize: pageSize,
            offset: offset
        )
    }

    private func storageMessage(_ error: any Error) -> String {
        if let error = error as? MeasurementStorageError { return error.userFacingDescription }
        return "Measurement history could not be updated."
    }
}
