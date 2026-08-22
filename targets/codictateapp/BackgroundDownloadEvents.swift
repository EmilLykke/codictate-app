import Foundation

/// The completion handler iOS hands the app when it relaunches or wakes it to finish a
/// Speech Model download that completed while the app was not running.
///
/// Exactly one background URLSession runs in this process,
/// `app.codictate.modeldownload.host`, owned by `ModelManager` and attached from
/// `KeyboardHostRecorder.bootstrap()`. The Expo module deliberately owns none: iOS wakes a
/// terminated app for a background download without initialising React Native, so a
/// session attached from the module's `OnCreate` would never be recreated, its finished
/// bytes would never be filed and its handler would never be answered. Answering none is
/// how an app stops being relaunched for its own downloads.
///
/// Every method runs on the main queue: `UIApplicationDelegate` calls arrive there, the
/// notification observer is registered with `queue: .main`, and the coordinator posts from
/// `DispatchQueue.main`. No lock, and none to be added without moving all three.
final class BackgroundDownloadEvents {

    static let shared = BackgroundDownloadEvents()

    /// The Speech Model download session. `ModelManager` configures its coordinator with
    /// this exact string, so the two cannot drift. Anything else belongs to another
    /// library and goes to Expo's own subscribers.
    static let sessionIdentifier = "app.codictate.modeldownload.host"

    private var pending: (() -> Void)?
    private var finishedBeforeHandover = false
    private var observerInstalled = false

    private init() {}

    static func owns(sessionIdentifier identifier: String) -> Bool {
        identifier == sessionIdentifier
    }

    /// Called once from `KeyboardHostRecorder.bootstrap()`, before the session is
    /// attached, so no replay can finish unobserved.
    func installObserver() {
        guard !observerInstalled else { return }
        observerInstalled = true

        NotificationCenter.default.addObserver(
            forName: ModelDownloadNotification.backgroundEventsFinished,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let identifier = note.userInfo?["identifier"] as? String,
                  Self.owns(sessionIdentifier: identifier) else { return }
            self?.sessionFinishedEvents()
        }
    }

    /// Stores what iOS passed to
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    ///
    /// `bootstrap()` attaches the session from `didFinishLaunching`, which runs before
    /// this, so the replay can finish before iOS hands the handler over. A replay that
    /// already finished is answered immediately rather than waiting for a second one that
    /// will never come.
    func store(completionHandler: @escaping () -> Void) {
        if finishedBeforeHandover {
            finishedBeforeHandover = false
            completionHandler()
            return
        }
        pending = completionHandler
    }

    // MARK: - Private

    private func sessionFinishedEvents() {
        guard let handler = pending else {
            finishedBeforeHandover = true
            return
        }
        pending = nil
        handler()
    }
}
