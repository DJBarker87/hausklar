import MapKit
import XCTest
@testable import HausKlar

final class FitnessAnalysisContractTests: XCTestCase {
    func testActivityPaceUsesRegisteredSummaryKeyThenSafeDistanceFallback() throws {
        let registered=FitnessActivityMetric(
            metricKey:"running.average_pace_s_per_km",label:"Average pace",
            valueNumber:302,valueText:nil,valueBool:nil,unitKey:"s/km",
            origin:"recorded",quality:"measured"
        )
        XCTAssertEqual(
            FitnessDisplay.averagePaceSecondsPerKilometre(
                summaryMetrics:[registered],distanceMetres:10_000,durationSeconds:3_600
            ),
            302
        )
        XCTAssertEqual(
            FitnessDisplay.averagePaceSecondsPerKilometre(
                summaryMetrics:[],distanceMetres:10_000,durationSeconds:3_050
            ),
            305
        )
    }

    func testOnlyRetainedManualFitSourceCanOfferReanalysis() {
        let healthKit=FitnessActivitySource(
            id:"healthkit",sourceType:"healthkit",provider:"apple_health",
            deviceName:"Apple Watch",status:"accepted",attachedAt:nil,
            isPrimary:true,dataQuality:"measured"
        )
        let retainedFit=FitnessActivitySource(
            id:"fit",sourceType:"manual_fit",provider:"garmin",
            deviceName:"Forerunner 970",status:"accepted",attachedAt:nil,
            isPrimary:true,dataQuality:"measured"
        )

        XCTAssertFalse(healthKit.hasRetainedFitFile)
        XCTAssertTrue(retainedFit.hasRetainedFitFile)
    }

    func testActivityDetailMapsRegisteredMetricAndQualityKeysToPlainLabels() {
        XCTAssertEqual(
            FitnessDisplay.summaryMetricTitle("running.average_pace_s_per_km"),
            "Average pace"
        )
        XCTAssertEqual(
            FitnessDisplay.qualityFindingTitle("heart_rate_dropout"),
            "Heart-rate coverage"
        )
        XCTAssertEqual(
            FitnessDisplay.analysisLimitTitle("heart_rate_decoupling"),
            "Pace-to-heart-rate drift"
        )
    }

    func testAllRegisteredGenericChartShapesHaveDistinctKeys() {
        XCTAssertEqual(FitnessAnalysisChartType.allCases.count,9)
        XCTAssertEqual(Set(FitnessAnalysisChartType.allCases.map(\.rawValue)).count,9)
        XCTAssertTrue(FitnessAnalysisChartType.allCases.contains(.calendarHeatmap))
        XCTAssertTrue(FitnessAnalysisChartType.allCases.contains(.rangeBand))
    }

    func testUnknownAndIncompatibleKeysAreRejectedBeforeNetworkRequest() {
        let registry = fixtureRegistry()
        var query = fixtureQuery()
        query.measureKey = "raw_sql"
        XCTAssertEqual(
            FitnessAnalysisQueryValidator.problem(with: query,registry: registry),
            "Choose an available measure."
        )

        query = fixtureQuery()
        query.dimensionKey = "source.sensor.secret"
        XCTAssertEqual(
            FitnessAnalysisQueryValidator.problem(with: query,registry: registry),
            "Choose an available grouping."
        )

        query = fixtureQuery()
        query.chartTypeKey = .scatter
        XCTAssertEqual(
            FitnessAnalysisQueryValidator.problem(with: query,registry: registry),
            "That chart is not available for this measure."
        )
    }

    func testQueryBoundsAndRegisteredFilterValuesAreEnforced() {
        let registry = fixtureRegistry()
        var query = fixtureQuery()
        query.dateRange = FitnessAnalysisDateRange(start: "2023-01-01",end: "2026-01-01")
        XCTAssertNotNil(FitnessAnalysisQueryValidator.problem(with: query,registry: registry))

        query = fixtureQuery()
        query.filters[0].value = .string("not-a-registered-sport")
        XCTAssertEqual(
            FitnessAnalysisQueryValidator.problem(with: query,registry: registry),
            "Choose an available sport value."
        )
    }

    func testSavedDefinitionContainsKeysAndWindowButNoFilterValuesOrQueryLanguage() throws {
        let registry = fixtureRegistry()
        let query = fixtureQuery()
        let payload = try XCTUnwrap(
            FitnessAnalysisQueryValidator.savedPayload(name: "Weekly distance",query: query,registry: registry)
        )
        XCTAssertEqual(payload.filterKeys,["sport"])
        XCTAssertEqual(payload.dateWindowDays,31)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(payload),as: UTF8.self)
        XCTAssertTrue(json.contains("\"filter_keys\":[\"sport\"]"))
        XCTAssertFalse(json.contains("\"filters\""))
        XCTAssertFalse(json.contains("\"value\":\"running\""))
        XCTAssertFalse(json.lowercased().contains("select "))
        XCTAssertFalse(json.lowercased().contains("sql"))
    }

    func testCorrelationalDisclosureIsExplicitlyNonCausal() {
        let copy = FitnessAnalysisClassification.correlational.explanation.lowercased()
        XCTAssertTrue(copy.contains("association"))
        XCTAssertTrue(copy.contains("does not show"))
        XCTAssertTrue(copy.contains("caused"))
    }

    func testMissingValuesAndScatterPointsWithoutXAreNotPlottable() {
        let missing = point(x: .double(1),xValue: 1,value: nil)
        let missingX = point(x: nil,xValue: nil,value: 4)
        let complete = point(x: .double(2),xValue: 2,value: 4)
        XCTAssertFalse(missing.isPlottable)
        XCTAssertFalse(missing.isScatterPlottable)
        XCTAssertTrue(missingX.isPlottable)
        XCTAssertFalse(missingX.isScatterPlottable)
        XCTAssertTrue(complete.isPlottable)
        XCTAssertTrue(complete.isScatterPlottable)
    }

    func testQueuedResultDecodesWithFullMetadataEnvelope() throws {
        let json = """
        {
          "id":"result-1","status":"queued","job_id":"job-1","poll_after_ms":1500,
          "title":"Sleep and running","description":"Registered comparison",
          "dimension_key":"week","measure_key":"running.distance_m","chart_type_key":"line",
          "unit_key":"m","series":[],
          "metadata":{"period":{"start":"2026-01-01","end":"2026-01-31","label":"January"},
            "sample_size":8,"missing_count":2,"missing_rate":0.2,
            "source_quality":["mixed"],"measurement_quality":["recorded"],
            "canonical_policy":"canonical activities","duplicate_policy":"duplicates excluded",
            "classification":"correlational"},
          "summary":null,"difference":null,"limitations":[]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(FitnessAnalysisQueryResult.self,from: Data(json.utf8))
        XCTAssertEqual(result.id,"result-1")
        XCTAssertEqual(result.status,.queued)
        XCTAssertEqual(result.jobId,"job-1")
        XCTAssertEqual(result.metadata.sampleSize,8)
        XCTAssertEqual(result.metadata.classification,.correlational)
    }

    private func fixtureRegistry() -> FitnessAnalysisRegistry {
        FitnessAnalysisRegistry(
            dimensions: [
                .init(key: "week",label: "Week",valueType: "date",description: nil),
                .init(key: "sport",label: "Sport",valueType: "category",description: nil),
            ],
            measures: [
                .init(
                    key: "running.distance_m",label: "Distance",description: nil,unitKey: "m",
                    supportedDimensions: ["week"],chartTypes: [.line,.bar],allowedFilterKeys: ["sport"],
                    comparisonForms: ["previous_period"],defaultChartType: .line,
                    classification: .descriptive,minimumSampleSize: 1
                ),
            ],
            chartTypes: FitnessAnalysisChartType.allCases.map {
                .init(key: $0,label: $0.fallbackLabel)
            },
            filters: [
                .init(
                    key: "sport",label: "Sport",valueType: "registered_key",operators: [.equal,.containsAny],
                    values: [.init(key: "running",label: "Running")],maxValues: 2
                ),
            ],
            comparisons: [.init(key: "previous_period",label: "Previous period",description: nil)],
            limits: .init(maxWindowDays: 366,maxOutputPoints: 200,maxFilters: 4,heavyPollIntervalMs: 2_000),
            defaultQueries: []
        )
    }

    private func fixtureQuery() -> FitnessAnalysisQueryRequest {
        FitnessAnalysisQueryRequest(
            measureKey: "running.distance_m",dimensionKey: "week",chartTypeKey: .line,
            dateRange: .init(start: "2026-01-01",end: "2026-01-31"),
            filters: [.init(key: "sport",operator: .equal,value: .string("running"))],
            comparisonKey: "previous_period",maxPoints: 100
        )
    }

    private func point(x: JSONValue?,xValue: Double?,value: Double?) -> FitnessAnalysisPoint {
        FitnessAnalysisPoint(
            key: UUID().uuidString,label: "Point",x: x,xValue: xValue,value: value,
            low: nil,high: nil,sampleSize: nil,missingRate: nil,quality: nil
        )
    }
}

final class FitnessActivityPresentationTests: XCTestCase {
    func testRouteRejectsInvalidCoordinatesAndUsesAppleBasemapWithoutLocationTracking() {
        XCTAssertNil(FitnessLocalRouteSample(latitude:91,longitude:0))
        XCTAssertNil(FitnessLocalRouteSample(latitude:0,longitude:181))
        XCTAssertNil(FitnessLocalRouteSample(latitude:.infinity,longitude:0))
        XCTAssertTrue(FitnessLocalRoutePrivacyPolicy.usesAppleMapsBasemap)
        XCTAssertFalse(FitnessLocalRoutePrivacyPolicy.requestsUserLocation)
        XCTAssertFalse(FitnessLocalRoutePrivacyPolicy.usesThirdPartyMapSDK)
    }

    func testLocalRouteProjectionRemovesConsecutiveDuplicatePositions() throws {
        let first=try sample(latitude:51.5,longitude:-0.12,offsetMs:0)
        let duplicate=try sample(latitude:51.5,longitude:-0.12,offsetMs:1_000)
        let finish=try sample(latitude:51.51,longitude:-0.11,offsetMs:2_000)

        let projection=FitnessLocalRouteProjection(samples:[first,duplicate,finish])

        XCTAssertEqual(projection.samples,[first,finish])
        XCTAssertEqual(projection.points.count,2)
    }

    func testLocalRouteProjectionIsNorthUpAndPreservesCoordinateAspect() throws {
        let projection=FitnessLocalRouteProjection(samples:[
            try sample(latitude:0,longitude:0),
            try sample(latitude:1,longitude:0),
            try sample(latitude:1,longitude:1),
        ])

        XCTAssertLessThan(projection.points[1].y,projection.points[0].y)
        let latitudeSpan=abs(projection.points[1].y-projection.points[0].y)
        let longitudeSpan=abs(projection.points[2].x-projection.points[1].x)
        XCTAssertEqual(latitudeSpan,longitudeSpan,accuracy:0.001)
    }

    func testLocalRouteProjectionUnwrapsTheDateLine() throws {
        let projection=FitnessLocalRouteProjection(samples:[
            try sample(latitude:0,longitude:179.9),
            try sample(latitude:0,longitude:-179.9),
            try sample(latitude:0,longitude:-179.8),
        ])

        XCTAssertLessThan(projection.points[0].x,projection.points[1].x)
        XCTAssertLessThan(projection.points[1].x,projection.points[2].x)
    }

    func testRouteAndChartSelectionUseNearestSharedTimestamp() throws {
        let projection=FitnessLocalRouteProjection(samples:[
            try sample(latitude:51.50,longitude:-0.12,offsetMs:0),
            try sample(latitude:51.51,longitude:-0.11,offsetMs:1_000),
            try sample(latitude:51.52,longitude:-0.10,offsetMs:2_000),
        ])

        XCTAssertEqual(projection.selectedIndex(nearest:1_400),1)
        XCTAssertEqual(projection.selectedIndex(nearest:1_600),2)
        XCTAssertEqual(projection.selectableIndex(nearest:0),0)
    }

    func testRouteTapCanResolveToNearestTimestampedPosition() throws {
        let projection=FitnessLocalRouteProjection(samples:[
            try sample(latitude:0,longitude:0,offsetMs:nil),
            try sample(latitude:0,longitude:1,offsetMs:1_000),
            try sample(latitude:0,longitude:2,offsetMs:nil),
        ])
        let rendered=projection.canvasPoints(
            in:CGSize(width:300,height:200),padding:24
        )

        let visualIndex=try XCTUnwrap(
            projection.nearestIndex(
                to:rendered[2],in:CGSize(width:300,height:200),padding:24
            )
        )
        XCTAssertEqual(visualIndex,2)
        XCTAssertEqual(projection.selectableIndex(nearest:visualIndex),1)
        XCTAssertEqual(
            projection.nearestIndex(to: try sample(latitude: 0, longitude: 1.8).coordinate),
            2
        )
    }

    func testAppleMapViewportAlwaysHasUsableCameraBounds() throws {
        let samples = [
            try sample(latitude: 51.501, longitude: -0.142),
            try sample(latitude: 51.501, longitude: -0.142),
        ]

        let rect = FitnessAppleRouteViewport.visibleMapRect(for: samples)

        XCTAssertFalse(rect.isNull)
        XCTAssertGreaterThanOrEqual(rect.width, FitnessAppleRouteViewport.minimumMapPointSpan)
        XCTAssertGreaterThanOrEqual(rect.height, FitnessAppleRouteViewport.minimumMapPointSpan)
    }

    func testRouteAccessibilitySummaryDescribesShapeAndSelectionWithoutCoordinates() throws {
        let projection=FitnessLocalRouteProjection(samples:[
            try sample(latitude:0,longitude:0,offsetMs:0),
            try sample(latitude:0.01,longitude:0.01,offsetMs:1_000),
            try sample(latitude:0.02,longitude:0.02,offsetMs:2_000),
        ])

        let summary=projection.accessibilitySummary(selectedIndex:1)
        XCTAssertTrue(summary.contains("north-east"))
        XCTAssertTrue(summary.contains("50 percent"))
        XCTAssertFalse(summary.lowercased().contains("latitude"))
        XCTAssertFalse(summary.lowercased().contains("longitude"))
    }

    func testRouteAccessibilitySummaryRecognisesLoopedRoute() throws {
        let projection=FitnessLocalRouteProjection(samples:[
            try sample(latitude:51.5,longitude:-0.12),
            try sample(latitude:51.51,longitude:-0.12),
            try sample(latitude:51.51,longitude:-0.11),
            try sample(latitude:51.5,longitude:-0.12),
        ])

        XCTAssertTrue(projection.endpointsAreClose)
        XCTAssertTrue(
            projection.accessibilitySummary(selectedIndex:nil)
                .contains("Start and finish are close together")
        )
    }

    func testActivityDetailPrimaryOrderLeadsWithRouteMetricsSplitsAndCharts() {
        XCTAssertEqual(
            FitnessActivityPresentationPolicy.primarySections,
            [.route,.headlineMetrics,.splits,.charts,.moreStats,.context,.insights]
        )
    }

    func testRunActivityDefaultsToRecordedLapsAndStackedCoreGraphs() {
        XCTAssertTrue(FitnessActivityPresentationPolicy.isRun("trail_running"))
        XCTAssertEqual(
            FitnessActivityPresentationPolicy.preferredIntervalGroup(
                available: ["kilometre", "source_lap", "interval"]
            ),
            "source_lap"
        )

        let groups = FitnessActivityPresentationPolicy.runChartGroups([
            "power_w", "heart_rate_bpm", "cadence_spm", "pace_s_per_km",
            "altitude_m", "vertical_oscillation_mm",
        ])
        XCTAssertEqual(
            groups.primary,
            ["pace_s_per_km", "heart_rate_bpm", "altitude_m", "cadence_spm"]
        )
        XCTAssertEqual(groups.additional, ["power_w", "vertical_oscillation_mm"])
    }

    func testRecordedLapKeepsElapsedAndMovingTimeAndUsesMovingTimeForPace() {
        let lap = FitnessActivityInterval(
            id: "lap-1",
            parentIntervalId: nil,
            sequence: 0,
            intervalKind: "source_lap",
            origin: "source",
            startOffsetMs: 0,
            endOffsetMs: 620_000,
            startDistanceM: 0,
            endDistanceM: 2_000,
            label: "Lap 1",
            metrics: [
                "elapsed_duration_s": .double(620),
                "timer_duration_s": .double(600),
                "elevation.change_m": .double(-3),
                "elevation.gain_m": .double(12),
                "heart_rate.average_bpm": .double(146),
                "heart_rate.maximum_bpm": .double(162),
                "power.average_w": .double(278),
            ],
            metricsJson: nil
        )

        XCTAssertEqual(FitnessActivityIntervalPresentation.elapsedDuration(lap), 620)
        XCTAssertEqual(FitnessActivityIntervalPresentation.timerDuration(lap), 600)
        XCTAssertEqual(FitnessActivityIntervalPresentation.pace(lap), 300)
        XCTAssertEqual(FitnessActivityIntervalPresentation.elevation(lap), -3)
        XCTAssertEqual(FitnessActivityIntervalPresentation.averageHeartRate(lap), 146)
        XCTAssertEqual(FitnessActivityIntervalPresentation.maximumHeartRate(lap), 162)
        XCTAssertEqual(FitnessActivityIntervalPresentation.averagePower(lap), 278)
    }

    func testLocalRouteRenderingBudgetPreservesBothEndpointsInStableOrder() {
        let indices=FitnessActivityPresentationPolicy.routeSampleIndices(
            count:20_000,maximum:2_000
        )

        XCTAssertEqual(indices.count,2_000)
        XCTAssertEqual(indices.first,0)
        XCTAssertEqual(indices.last,19_999)
        XCTAssertEqual(indices,indices.sorted())
        XCTAssertEqual(Set(indices).count,indices.count)
    }

    func testSportPickerPolicyDeduplicatesKeysCaseInsensitivelyInStableOrder() {
        let values=[
            FitnessRegisteredSport(key:"running",displayName:"Running"),
            FitnessRegisteredSport(key:"RUNNING",displayName:"Run duplicate"),
            FitnessRegisteredSport(key:"cycling",displayName:"Cycling"),
        ]

        XCTAssertEqual(
            FitnessActivityPresentationPolicy.uniqueSports(values).map(\.displayName),
            ["Running","Cycling"]
        )
    }

    func testActivityHighlightsAndRecordsAreSemanticallyDeduplicated() {
        let findings=[
            FitnessAnalysisFinding(
                key:"pace",title:"Even pace",summary:"Steady throughout",
                status:nil,value:nil,unitKey:nil,quality:nil,confidence:nil,
                calculationVersion:nil,evidence:nil
            ),
            FitnessAnalysisFinding(
                key:"PACE",title:"Duplicate",summary:"Duplicate",
                status:nil,value:nil,unitKey:nil,quality:nil,confidence:nil,
                calculationVersion:nil,evidence:nil
            ),
        ]
        let records=[
            FitnessActivityRecord(
                id:"record-1",recordKey:"5k",label:"Fastest 5K",value:"20:00",
                achievedAtOffsetMs:nil,isPersonalBest:true
            ),
            FitnessActivityRecord(
                id:"record-2",recordKey:"5K",label:"Duplicate",value:"20:00",
                achievedAtOffsetMs:nil,isPersonalBest:true
            ),
        ]

        XCTAssertEqual(
            FitnessActivityPresentationPolicy.uniqueAnalysisFindings(findings).count,1
        )
        XCTAssertEqual(FitnessActivityPresentationPolicy.uniqueRecords(records).count,1)
    }

    func testDataNotesAndSourcesAreSemanticallyDeduplicated() throws {
        let decoder=JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let findings=try decoder.decode(
            [FitnessDataQualityFinding].self,
            from:Data("""
            [
              {"id":"one","key":"gps_spike","severity":"warning","message":"raw one","start_offset_ms":100,"end_offset_ms":200},
              {"id":"two","key":"gps_spike","severity":"warning","message":"raw duplicate wording","start_offset_ms":100,"end_offset_ms":200}
            ]
            """.utf8)
        )
        let sources=[
            FitnessActivitySource(
                id:"one",sourceType:"healthkit",provider:"apple_health",
                deviceName:"Apple Watch",status:nil,attachedAt:nil,
                isPrimary:true,dataQuality:nil
            ),
            FitnessActivitySource(
                id:"two",sourceType:"healthkit",provider:"healthkit",
                deviceName:"Apple Watch",status:nil,attachedAt:nil,
                isPrimary:false,dataQuality:nil
            ),
        ]

        XCTAssertEqual(
            FitnessActivityPresentationPolicy.uniqueQualityFindings(findings).count,1
        )
        XCTAssertEqual(FitnessActivityPresentationPolicy.uniqueSources(sources).count,1)
        XCTAssertEqual(
            FitnessActivityPresentationPolicy.qualityMessage(findings[0]),
            "Part of the recorded route jumps unexpectedly."
        )
    }

    func testPrimaryErrorCopyDoesNotExposeCacheSyncOrProviderDetails() {
        let copy=[
            FitnessActivityPresentationPolicy.historyError(hasActivities:false),
            FitnessActivityPresentationPolicy.historyError(hasActivities:true),
            FitnessActivityPresentationPolicy.detailError,
            FitnessActivityPresentationPolicy.actionError,
        ].joined(separator:" ").lowercased()

        XCTAssertFalse(copy.contains("cache"))
        XCTAssertFalse(copy.contains("sync"))
        XCTAssertFalse(copy.contains("provider"))
        XCTAssertFalse(copy.contains("canonical"))
    }

    private func sample(
        latitude:Double,
        longitude:Double,
        offsetMs:Int? = nil
    ) throws -> FitnessLocalRouteSample {
        try XCTUnwrap(
            FitnessLocalRouteSample(
                latitude:latitude,longitude:longitude,offsetMs:offsetMs
            )
        )
    }
}
