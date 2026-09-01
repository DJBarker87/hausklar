import XCTest
@testable import HausKlar

final class HealthRecordDTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - Vaccinations

    func testDecodesVaccinationsContract() throws {
        let json = """
        {
          "child_id": "c1", "child_name": "Child Two", "age_months": 48.0,
          "vaccinations": [
            {
              "key": "6in1_1", "name": "6-in-1 (1st dose)", "due_age_label": "8 weeks",
              "due_date": "2022-03-01", "status": "given", "given_on": "2022-03-03"
            },
            {
              "key": "mmr_2", "name": "MMR (2nd dose)", "due_age_label": "3 years 4 months",
              "due_date": null, "status": "upcoming", "given_on": null
            }
          ],
          "disclaimer": "Follow the NHS schedule."
        }
        """
        let response = try decoder.decode(VaccinationsResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.vaccinations.count, 2)
        let given = response.vaccinations[0]
        XCTAssertEqual(given.id, "6in1_1")
        XCTAssertEqual(given.status, .given)
        XCTAssertEqual(given.givenOn, "2022-03-03")
        XCTAssertNil(given.isStandard) // Older-server compatibility.

        let upcoming = response.vaccinations[1]
        XCTAssertNil(upcoming.dueDate)
        XCTAssertNil(upcoming.dueDateDisplay)
        XCTAssertNil(upcoming.givenOn)
        XCTAssertEqual(upcoming.status, .upcoming)
    }

    func testDecodesAdditionalVaccination() throws {
        let json = """
        {
          "key": "custom:abc", "name": "Chickenpox",
          "due_age_label": "Additional vaccination", "due_date": null,
          "status": "given", "given_on": "2026-07-16", "is_standard": false
        }
        """
        let item = try decoder.decode(VaccinationItemDTO.self, from: Data(json.utf8))
        XCTAssertTrue(item.isAdditional)
        XCTAssertEqual(item.name, "Chickenpox")
        XCTAssertEqual(item.givenOn, "2026-07-16")
    }

    @MainActor
    func testIllnessEndOfDayIsInclusive() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let input = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 16, hour: 12
        )))
        let result = try XCTUnwrap(HealthRecordViewModel.inclusiveEndOfDay(
            for: input,
            calendar: calendar
        ))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 16)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }

    func testDecodesCoherentIllnessEpisodeTimeline() throws {
        let json = """
        {
          "illness": {
            "id": "ill-1", "child_id": "c1",
            "started_at": "2026-08-08T18:00:00Z", "ended_at": null,
            "notes": "Fever and cough",
            "created_at": "2026-08-08T18:00:00Z", "updated_at": "2026-08-08T18:00:00Z"
          },
          "temperature_readings": [{
            "id": "temp-1", "child_id": "c1", "illness_id": "ill-1",
            "value_celsius": 38.4, "recorded_at": "2026-08-08T20:00:00Z",
            "notes": "Before bed", "created_at": "2026-08-08T20:00:00Z"
          }],
          "medicine_doses": [{
            "id": "dose-1", "child_id": "c1", "medicine_type_id": "med-1",
            "given_at": "2026-08-08T20:05:00Z", "dose_amount": "5 ml",
            "notes": "With water", "medicine_name_display": "Calpol", "color": "#5856D6"
          }],
          "next_dose_times": [{
            "medicine_type_id": "med-1", "medicine_name": "Calpol",
            "next_safe_at": "2026-08-09T00:05:00Z", "is_safe_now": false,
            "default_dose_amount": "5 ml", "color": "#5856D6",
            "last_given_at": "2026-08-08T20:05:00Z"
          }]
        }
        """

        let detail = try decoder.decode(IllnessDetailDTO.self, from: Data(json.utf8))

        XCTAssertEqual(detail.illness.notes, "Fever and cough")
        XCTAssertEqual(detail.temperatureReadings.first?.valueCelsius, 38.4)
        XCTAssertEqual(detail.temperatureReadings.first?.notes, "Before bed")
        XCTAssertEqual(detail.medicineDoses.first?.medicineNameDisplay, "Calpol")
        XCTAssertEqual(detail.medicineDoses.first?.doseAmount, "5 ml")
        XCTAssertEqual(detail.medicineDoses.first?.notes, "With water")
        XCTAssertEqual(detail.nextDoseTimes.first?.isSafeNow, false)
    }

    func testDecodesDogVaccinationRecord() throws {
        let json = """
        {
          "id": "dv1", "vaccine_name": "Leptospirosis",
          "given_on": "2026-07-16", "next_due_on": "2027-07-16",
          "notes": "Annual booster", "created_at": "2026-07-16T10:00:00Z",
          "updated_at": "2026-07-16T10:00:00Z"
        }
        """
        let record = try decoder.decode(DogVaccinationDTO.self, from: Data(json.utf8))
        XCTAssertEqual(record.vaccineName, "Leptospirosis")
        XCTAssertEqual(record.nextDueOn, "2027-07-16")
    }

    // MARK: - Growth centiles

    func testDecodesGrowthCentilesContract() throws {
        let json = """
        {
          "child_id": "c1", "child_name": "Child One", "sex": "male",
          "measurements": [
            {
              "date": "2026-06-01", "age_months": 74.2,
              "height_cm": 120.5, "weight_kg": 22.0,
              "height_centile": 55.0, "weight_centile": 48.0
            }
          ],
          "weight_reference": [
            {"age_months": 72, "p2": 17.0, "p9": 18.5, "p25": 20.0, "p50": 22.0, "p75": 24.5, "p91": 27.0, "p98": 30.0}
          ],
          "height_reference": [
            {"age_months": 72, "p2": 110.0, "p9": 113.0, "p25": 116.0, "p50": 120.0, "p75": 124.0, "p91": 127.0, "p98": 130.0}
          ],
          "disclaimer": "WHO/UK reference data.",
          "note": null
        }
        """
        let response = try decoder.decode(GrowthCentilesResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.sex, "male")
        XCTAssertEqual(response.measurements.count, 1)
        XCTAssertEqual(response.measurements[0].heightCentile, 55.0)
        XCTAssertEqual(response.measurements[0].ageMonths, 74.2)
        XCTAssertEqual(response.weightReference.first?.p50, 22.0)
        XCTAssertEqual(response.heightReference.first?.p98, 130.0)
        XCTAssertNil(response.note)
    }

    func testDecodesGrowthCentilesWithNullSexAndCentiles() throws {
        let json = """
        {
          "child_id": "c1", "child_name": "Child One", "sex": null,
          "measurements": [
            {"date": "2026-06-01", "age_months": null, "height_cm": null, "weight_kg": 20.0,
             "height_centile": null, "weight_centile": null}
          ],
          "weight_reference": [], "height_reference": [],
          "disclaimer": "WHO reference.",
          "note": "Set this child's sex to compute centiles."
        }
        """
        let response = try decoder.decode(GrowthCentilesResponseDTO.self, from: Data(json.utf8))

        XCTAssertNil(response.sex)
        XCTAssertEqual(response.note, "Set this child's sex to compute centiles.")
        XCTAssertNil(response.measurements[0].ageMonths)
        XCTAssertNil(response.measurements[0].heightCentile)
        XCTAssertEqual(response.measurements[0].weightKg, 20.0)
    }

    // MARK: - GP summary

    func testDecodesSummaryContract() throws {
        let json = """
        {
          "child_id": "c1", "child_name": "Child Two",
          "since": "2026-04-13", "until": "2026-07-12",
          "illnesses": [
            {"id": "ill-1", "started_at": "2026-05-01T09:00:00+00:00", "ended_at": "2026-05-04T09:00:00+00:00", "notes": "Chickenpox"},
            {"id": "ill-2", "started_at": "2026-07-10T09:00:00+00:00", "ended_at": null, "notes": null}
          ],
          "temperatures": [
            {"recorded_at": "2026-05-01T20:00:00+00:00", "value_celsius": 38.4}
          ],
          "medicine_doses": [
            {"given_at": "2026-05-01T20:05:00+00:00", "name": "Calpol", "dose_amount": "5ml"},
            {"given_at": "2026-05-02T08:00:00+00:00", "name": "Ibuprofen", "dose_amount": null}
          ],
          "report": "Child Two had chickenpox in early May.",
          "disclaimer": "Share with your GP; not medical advice."
        }
        """
        let response = try decoder.decode(SummaryResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.since, "2026-04-13")
        XCTAssertEqual(response.until, "2026-07-12")
        XCTAssertEqual(response.illnesses.count, 2)
        XCTAssertEqual(response.illnesses[0].notes, "Chickenpox")
        XCTAssertNil(response.illnesses[1].endedAt)
        XCTAssertNil(response.illnesses[1].notes)
        XCTAssertEqual(response.temperatures[0].valueCelsius, 38.4)
        XCTAssertEqual(response.medicineDoses[0].doseAmount, "5ml")
        XCTAssertNil(response.medicineDoses[1].doseAmount)
        XCTAssertEqual(response.report, "Child Two had chickenpox in early May.")
    }

    func testDecodesSummaryIllnessWithoutId() throws {
        // The id is treated as optional so an omitted id still yields a stable identity.
        let json = """
        {"started_at": "2026-05-01T09:00:00+00:00", "ended_at": null, "notes": "Cold"}
        """
        let illness = try decoder.decode(SummaryIllnessDTO.self, from: Data(json.utf8))
        XCTAssertNil(illness.id)
        XCTAssertEqual(illness.identity, "2026-05-01T09:00:00+00:00")
    }

    func testCentileOrdinalLabel() {
        XCTAssertEqual(GrowthCentilesSection.centileLabel(50), "50th")
        XCTAssertEqual(GrowthCentilesSection.centileLabel(1), "1st")
        XCTAssertEqual(GrowthCentilesSection.centileLabel(2), "2nd")
        XCTAssertEqual(GrowthCentilesSection.centileLabel(3), "3rd")
        XCTAssertEqual(GrowthCentilesSection.centileLabel(91), "91st")
        XCTAssertEqual(GrowthCentilesSection.centileLabel(11), "11th")
    }
}
