import Foundation

/// Stable identifiers for release-critical controls and states.
///
/// Keep these values independent of visible copy so UI automation continues to
/// work when labels are translated or refined.
enum HausKlarAccessibilityID {
    enum Main {
        static let offlineIndicator = "mainOfflineIndicator"
        static let moreLauncher = "mainMoreLauncher"
        static let moreCustomize = "mainMoreCustomize"
        static let moreLists = "mainMoreLists"
        static let moreHouse = "mainMoreHouse"
        static let moreFinance = "mainMoreFinance"
        static let moreFitness = "mainMoreFitness"
        static let moreSettings = "mainMoreSettings"
        static let tabSlotFour = "mainTabSlotFour"
        static let tabSlotFive = "mainTabSlotFive"
        static let tabSave = "mainTabSave"
    }

    enum Login {
        static let screen = "loginScreen"
        static let email = "loginEmail"
        static let password = "loginPassword"
        static let submit = "loginSubmit"
        static let biometricUnlock = "loginBiometricUnlock"
        static let error = "loginError"
        static let biometricError = "loginBiometricError"
        static let recoveryCopies = "loginFitnessRecoveryCopies"
    }

    enum Medicine {
        static let screen = "medicineScreen"
        static let addType = "medicineAddType"
        static let childSelector = "medicineChildSelector"
        static let loading = "medicineLoading"
        static let error = "medicineError"
        static let empty = "medicineEmpty"
        static let warnings = "medicineWarnings"
        static let logOther = "medicineLogOther"
        static let logForm = "medicineLogForm"
        static let medicinePicker = "medicineLogTypePicker"
        static let amount = "medicineLogAmount"
        static let givenAt = "medicineLogGivenAt"
        static let safetyCheck = "medicineSafetyCheck"
        static let submitDose = "medicineSubmitDose"

        static func typeCard(_ id: String) -> String { "medicineType-\(id)" }
        static func reviewDose(_ id: String) -> String { "medicineReview-\(id)" }
        static func history(_ id: String) -> String { "medicineHistory-\(id)" }
        static func recentDose(_ id: String) -> String { "medicineRecentDose-\(id)" }
    }

    enum Photos {
        static let screen = "photosScreen"
        static let openLibrary = "photosOpenLibrary"
        static let loading = "photosLoading"
        static let uploadProgress = "photosUploadProgress"
        static let info = "photosInfo"
        static let error = "photosError"
        static let empty = "photosEmpty"
        static let review = "photosMomentReview"
        static let reviewPerson = "photosMomentPerson"
        static let reviewSave = "photosMomentSave"
        static let detail = "photoDetail"
        static let detailImage = "photoDetailImage"
        static let detailError = "photoDetailError"
        static let detailSave = "photoDetailSave"

        static func photo(_ id: String) -> String { "photo-\(id)" }
    }

    enum Documents {
        static let screen = "documentsScreen"
        static let loading = "documentsLoading"
        static let error = "documentsError"
        static let empty = "documentsEmpty"
        static let pendingUploads = "documentsPendingUploads"
        static let sourceSheet = "documentCaptureSourceSheet"
        static let scan = "documentScan"
        static let preparing = "documentPreparing"
    }

    enum Capture {
        static let screen = "captureScreen"
        static let input = "captureInput"
        static let dictate = "captureDictate"
        static let error = "captureError"
        static let review = "captureReview"
        static let reviewScreen = "captureReviewScreen"
        static let confirm = "captureConfirm"
        static let complete = "captureComplete"
    }

    enum FitnessPhotos {
        static let screen = "fitnessProgressPhotos"
        static let loading = "fitnessProgressPhotosLoading"
        static let error = "fitnessProgressPhotosError"
        static let empty = "fitnessProgressPhotosEmpty"
        static let capture = "fitnessProgressPhotoCapture"
        static let library = "fitnessProgressPhotoLibrary"
        static let camera = "fitnessProgressPhotoCamera"
        static let importError = "fitnessProgressPhotoImportError"
        static let save = "fitnessProgressPhotoSave"

        static func photo(_ id: String) -> String { "fitnessProgressPhoto-\(id)" }
        static func comparisonSelection(_ id: String) -> String {
            "fitnessProgressPhotoCompare-\(id)"
        }
    }

    enum Fitness {
        static let shellLoading = "fitnessShellLoading"
        static let overviewError = "fitnessOverviewActionError"
        static let overviewSuccess = "fitnessOverviewActionSuccess"
    }

    static let releaseCriticalStaticValues: [String] = [
        Main.offlineIndicator,
        Main.moreLauncher,
        Main.moreCustomize,
        Main.moreLists,
        Main.moreHouse,
        Main.moreFinance,
        Main.moreFitness,
        Main.moreSettings,
        Main.tabSlotFour,
        Main.tabSlotFive,
        Main.tabSave,
        Login.screen,
        Login.email,
        Login.password,
        Login.submit,
        Login.biometricUnlock,
        Login.error,
        Login.biometricError,
        Login.recoveryCopies,
        Medicine.screen,
        Medicine.addType,
        Medicine.childSelector,
        Medicine.loading,
        Medicine.error,
        Medicine.empty,
        Medicine.warnings,
        Medicine.logOther,
        Medicine.logForm,
        Medicine.medicinePicker,
        Medicine.amount,
        Medicine.givenAt,
        Medicine.safetyCheck,
        Medicine.submitDose,
        Photos.screen,
        Photos.openLibrary,
        Photos.loading,
        Photos.uploadProgress,
        Photos.info,
        Photos.error,
        Photos.empty,
        Photos.review,
        Photos.reviewPerson,
        Photos.reviewSave,
        Photos.detail,
        Photos.detailImage,
        Photos.detailError,
        Photos.detailSave,
        Documents.screen,
        Documents.loading,
        Documents.error,
        Documents.empty,
        Documents.pendingUploads,
        Documents.sourceSheet,
        Documents.scan,
        Documents.preparing,
        Capture.screen,
        Capture.input,
        Capture.dictate,
        Capture.error,
        Capture.review,
        Capture.reviewScreen,
        Capture.confirm,
        Capture.complete,
        FitnessPhotos.screen,
        FitnessPhotos.loading,
        FitnessPhotos.error,
        FitnessPhotos.empty,
        FitnessPhotos.capture,
        FitnessPhotos.library,
        FitnessPhotos.camera,
        FitnessPhotos.importError,
        FitnessPhotos.save,
        Fitness.shellLoading,
        Fitness.overviewError,
        Fitness.overviewSuccess,
    ]
}
