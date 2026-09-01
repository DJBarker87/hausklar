import SwiftUI
import WidgetKit

@main
struct HausKlarWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        FamilyJobsWidget()
        MedicineWidget()
        MedicineDoseLiveActivity()
        NapLiveActivity()
    }
}
