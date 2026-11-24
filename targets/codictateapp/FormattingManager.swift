import Foundation
import UIKit

enum FormattingModelNotification {
    static let ensure = Notification.Name("codictate.formatting.ensureModel")
    static let progress = Notification.Name("codictate.formatting.progress")
    static let ready = Notification.Name("codictate.formatting.ready")
    static let failed = Notification.Name("codictate.formatting.failed")
    /// A formatting setting changed in the App Group (React Native or the keyboard). The Expo
    /// module forwards it to React Native as `onFormattingSettingsChange`.
    static let settingsChanged = Notification.Name("codictate.formatting.settingsChanged")
}

final class FormattingManager {
    static let shared = FormattingManager()

    private let bridge = S1MiniBridge()
    private var observerInstalled = false
    private let groupID = KeyboardDictationBridge.suiteName

    private init() {}

    var modelPath: String? { FormattingConfiguration.modelPath }

    var modelIsReady: Bool {
        FormattingConfiguration.modelIsReady(suite: UserDefaults(suiteName: groupID))
    }

    func installObserver() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.bridge.unloadModel() }
        NotificationCenter.default.addObserver(
            forName: FormattingModelNotification.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let suite = UserDefaults(suiteName: self?.groupID ?? ""),
                  (suite.string(forKey: FormattingConfiguration.modelKey) ?? "off") == "off"
            else { return }
            self?.bridge.unloadModel()
        }
        NotificationCenter.default.addObserver(
            forName: FormattingModelNotification.ensure, object: nil, queue: .main
        ) { _ in
            ModelManager.shared.ensureFormattingModel(
                onProgress: { progress in
                    NotificationCenter.default.post(name: FormattingModelNotification.progress, object: nil, userInfo: ["progress": progress])
                },
                onComplete: { result in
                    switch result {
                    case .success(let path):
                        NotificationCenter.default.post(name: FormattingModelNotification.ready, object: nil, userInfo: ["path": path])
                    case .failure(let error):
                        NotificationCenter.default.post(name: FormattingModelNotification.failed, object: nil, userInfo: ["error": error.localizedDescription])
                    }
                }
            )
        }
    }

    func formatIfEligible(_ transcript: String, languageId: String, suite: UserDefaults) async -> String {
        let selected = FormattingModel(rawValue: suite.string(forKey: FormattingConfiguration.modelKey) ?? "") ?? .off
        guard selected == .s1Mini, modelIsReady,
              S1MiniFormatter.ineligibilityReason(transcript, languageId: languageId) == nil,
              let modelPath else { return transcript }

        let style = FormattingStyle(rawValue: suite.string(forKey: FormattingConfiguration.styleKey) ?? "") ?? .semiFormal
        let context = FormattingContext(rawValue: suite.string(forKey: FormattingConfiguration.contextKey) ?? "") ?? .general

        do {
            return try await S1MiniFormatter(bridge: bridge)
                .format(transcript, modelPath: modelPath, style: style, context: context)
        } catch {
            NSLog("[FormattingManager] Preserving raw transcript after failure: \(error.localizedDescription)")
            return transcript
        }
    }
}
