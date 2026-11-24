import QuartzCore
import UIKit

// MARK: - State

enum DictationViewState: Equatable {
    case idle
    /// `hasLiveLevel`: the In-keyboard path, whose audio the keyboard hears and can meter.
    /// The Warm and Cold paths record in the Host, so the keyboard has no level for them.
    case recording(hasLiveLevel: Bool)
    case processing(message: String?)
    case result(String)
    case error(String)
}

// MARK: - Delegate

protocol DictationKeyboardViewDelegate: AnyObject {
    func didTapDictate()
    func didInsertText(_ text: String)
    func didTapBackspace()
    /// Backspace held for a while: delete the word before the cursor.
    func didDeleteWordBackward()
    func didTapDismiss()
    /// The model panel is opening: what it lists now.
    func speechModelPanelContent() -> SpeechModelPanelContent
    /// A Speech Model row was picked (the current one included); the panel has closed.
    func didSelectSpeechModel(_ id: String)
    /// S1-mini's switch in the model panel.
    func didToggleFormatting(_ isOn: Bool)
    /// The model panel starts opening or closing; the controller keeps the system's gesture
    /// recognizers from cancelling its touches while it is open.
    func speechModelPanelDidChange(isOpen: Bool)
}

// MARK: - KeyboardKey

/// One key. Typed hundreds of times a day, so it never animates: pressing changes its color
/// instantly, like the system keyboard. Character keys show a callout instead.
final class KeyboardKey: UIControl {
    enum Style {
        case character
        case special
        case space
        /// No fill or shadow at rest (the dismiss key).
        case toolbar
    }

    static let cornerRadius: CGFloat = 6

    let label = UILabel()
    let icon = UIImageView()
    let style: Style
    private let fill = UIView()

    /// Pressing shows the callout above the key rather than recoloring it.
    var showsPreview = false
    /// Where touches land, in the key's coordinates (the dismiss glyph's strip area). Nil:
    /// its bounds; the key area routes near-misses to letter keys itself.
    var touchArea: CGRect?
    /// Shift while on or locked.
    var isEngaged = false {
        didSet {
            guard isEngaged != oldValue else { return }
            refresh()
        }
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        fill.isUserInteractionEnabled = false
        fill.layer.cornerRadius = Self.cornerRadius
        fill.layer.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        pinEdges(fill, to: self)

        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        icon.contentMode = .center
        icon.isHidden = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if style != .toolbar {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.32
            layer.shadowRadius = 0
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if style != .toolbar {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
        }
    }

    func setTitle(_ text: String, size: CGFloat) {
        label.text = text
        label.font = UIFont.systemFont(ofSize: size, weight: .regular)
        label.isHidden = false
        icon.isHidden = true
        accessibilityLabel = text
    }

    func setSymbol(_ name: String, size: CGFloat, accessibilityLabel: String) {
        icon.image = UIImage(
            systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        )
        icon.isHidden = false
        label.isHidden = true
        self.accessibilityLabel = accessibilityLabel
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        touchArea?.contains(point) ?? super.point(inside: point, with: event)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            refresh()
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        isHighlighted = false
    }

    private func refresh() {
        // Outside any animation block: the change is instant.
        fill.backgroundColor = currentFill
        let foreground: UIColor = isEngaged ? .black : (style == .toolbar ? .secondaryLabel : .label)
        label.textColor = foreground
        icon.tintColor = foreground
    }

    private var currentFill: UIColor {
        if isEngaged { return KeyboardPalette.engagedKey }
        let pressed = isHighlighted && !showsPreview
        switch style {
        case .character, .space:
            return pressed ? KeyboardPalette.characterKeyPressed : KeyboardPalette.characterKey
        case .special:
            return pressed ? KeyboardPalette.specialKeyPressed : KeyboardPalette.specialKey
        case .toolbar:
            return pressed ? KeyboardPalette.toolbarPressed : .clear
        }
    }
}

// MARK: - KeyPreview

/// The callout above a pressed character key.
private final class KeyPreview: UIView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = KeyboardPalette.characterKey
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        label.font = UIFont.systemFont(ofSize: 32, weight: .regular)
        label.textColor = .label
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 8).cgPath
    }
}

// MARK: - KeyArea

/// Holds the key rows, edge to edge and from the strip's bottom to the keyboard's. A touch
/// anywhere in it that misses a key (a gap between keys, the margin at either side, the gap
/// under the strip, the inset below the last row) goes to the nearest key, as on the system
/// keyboard, so no tap in the key area lands on nothing.
private final class KeyArea: UIView {
    var activeKeys: () -> [KeyboardKey] = { [] }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Hidden or fading out behind the model panel: never snap to a key nobody sees.
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else {
            return nil
        }
        let hit = super.hitTest(point, with: event)
        if hit is KeyboardKey { return hit }
        return nearestKey(to: point) ?? hit
    }

    /// The visible key closest to `point` (in this view's coordinates), at any distance.
    func nearestKey(to point: CGPoint) -> KeyboardKey? {
        var nearest: KeyboardKey?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for key in activeKeys() where key.window != nil && !key.isHidden && key.isUserInteractionEnabled {
            let frame = key.convert(key.bounds, to: self)
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if distance < nearestDistance {
                nearest = key
                nearestDistance = distance
            }
        }
        return nearest
    }
}

// MARK: - DictationKeyboardView

final class DictationKeyboardView: UIView {

    weak var delegate: DictationKeyboardViewDelegate?

    private enum Page { case letters, numbers, symbols }
    private enum Shift { case off, on, locked }

    private enum Metrics {
        /// Strip (44) + gap (4) + four 42 pt rows with 10 pt gaps (198) + bottom inset (4).
        static let height: CGFloat = 250
        /// The strip above the keys: dismiss and the model chip at the left, Dictate at the
        /// right, error text between them only when there is one. No fill of its own.
        static let stripHeight: CGFloat = 44
        static let stripGap: CGFloat = 4
        static let sideInset: CGFloat = 3
        static let stripSideInset: CGFloat = 8
        /// Strip touch areas: each control answers across the strip's full height. The dismiss
        /// glyph's runs from the keyboard's left edge, the capsule's to its right edge, and the
        /// chip's past its text and chevron by `chipTouchMargin` on each side. Where two want
        /// the same points they split them at the middle.
        static let dismissMinTouchWidth: CGFloat = 52
        static let dictateMinTouchWidth: CGFloat = 80
        static let chipTouchMargin: CGFloat = 10
        /// An empty strip point this close above the key area goes to the nearest top-row key.
        static let stripKeySnap: CGFloat = 8
        static let bottomInset: CGFloat = 4
        static let rowSpacing: CGFloat = 10
        /// Error text shows for this long, then fades.
        static let errorVisibleFor: TimeInterval = 3
        static let keySpacing: CGFloat = 6
        static let sideKeyWidth: CGFloat = 1.3
        static let returnKeyWidth: CGFloat = 2.6
        /// Backspace: first repeat after this hold, then every `deleteInterval`.
        static let deleteDelay: TimeInterval = 0.5
        static let deleteInterval: TimeInterval = 0.1
        /// Held this long, backspace deletes whole words, one every two ticks.
        static let wordDeleteAfter: TimeInterval = 2
        static let capsLockTapWindow: CFTimeInterval = 0.3
    }

    private static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
    private static let numberRows: [[String]] = [
        "1234567890".map(String.init),
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
    ]
    private static let symbolRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "\u{20AC}", "\u{00A3}", "\u{00A5}", "\u{2022}"],
    ]
    private static let punctuationRow = [".", ",", "?", "!", "'"]

    private let pill = DictatePill()
    private let dismissKey = KeyboardKey(style: .toolbar)
    /// The Speech Model's name; opens the model panel. Hidden when the keyboard cannot read
    /// the App Group (no Full Access).
    private let modelChip = SpeechModelChip()
    /// Replaces the key area, at its height, while open.
    private let modelPanel = SpeechModelPanel()
    private var panelAnimator: UIViewPropertyAnimator?
    private(set) var isModelPanelOpen = false
    private var errorAfterChip: NSLayoutConstraint!
    private var errorAfterDismiss: NSLayoutConstraint!
    /// The only text in the strip, and only for errors.
    private let errorLabel = UILabel()
    private var errorGeneration = 0
    private let keyArea = KeyArea()
    private let preview = KeyPreview()
    /// The globe. The controller wires it to `handleInputModeList(from:with:)`.
    let inputModeKey = KeyboardKey(style: .special)
    private let modeKey = KeyboardKey(style: .special)
    private let spaceKey = KeyboardKey(style: .space)
    private let returnKey = KeyboardKey(style: .special)
    private var shiftKey: KeyboardKey!
    /// Every letter key's width follows this one, so rows 2 and 3 match row 1.
    private var referenceKey: KeyboardKey!

    private var letterKeys: [(key: KeyboardKey, letter: String)] = []
    private var pageKeys: [Page: [KeyboardKey]] = [:]
    private var pageRows: [Page: [UIView]] = [:]
    private var bottomRowKeys: [KeyboardKey] = []
    /// Builder constraints between views in different rows; activated once all are in the tree.
    private var deferredConstraints: [NSLayoutConstraint] = []

    private var page: Page = .letters {
        didSet {
            guard page != oldValue else { return }
            pageChanged()
        }
    }
    private var shift: Shift = .off {
        didSet {
            guard shift != oldValue else { return }
            shiftChanged()
        }
    }
    private var lastShiftTapAt: CFTimeInterval = 0

    private var state: DictationViewState = .idle

    private var deleteTimer: Timer?
    private var deleteStartedAt: CFTimeInterval = 0
    private var deleteTicks = 0
    private weak var previewOwner: KeyboardKey?

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        build()
        pageChanged()
        shiftChanged()
        pill.setMode(.idle, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateStripTouchAreas()
    }

    /// A touch on empty strip just above the keys (no strip control there) goes to the
    /// nearest top-row key, so the strip/keys boundary has no dead band either.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard hit === self, !isModelPanelOpen, keyArea.isUserInteractionEnabled, !keyArea.isHidden,
              point.y < Metrics.stripHeight, point.y >= Metrics.stripHeight - Metrics.stripKeySnap else {
            return hit
        }
        return keyArea.nearestKey(to: convert(point, to: keyArea)) ?? hit
    }

    /// Sets each strip control's touch area (see `Metrics.dismissMinTouchWidth`): full strip
    /// height, out to the keyboard's edges, and split at the middle where two would overlap.
    /// The visuals stay where they are.
    private func updateStripTouchAreas() {
        struct Span { var minX: CGFloat; var maxX: CGFloat }
        func split(_ left: inout Span, _ right: inout Span) {
            guard left.maxX > right.minX else { return }
            let middle = (left.maxX + right.minX) / 2
            left.maxX = middle
            right.minX = middle
        }
        // Frames ignoring transforms: the capsule scales while pressed.
        func layoutFrame(_ view: UIView) -> CGRect {
            CGRect(
                x: view.center.x - view.bounds.width / 2, y: view.center.y - view.bounds.height / 2,
                width: view.bounds.width, height: view.bounds.height
            )
        }
        func touchArea(_ span: Span, for frame: CGRect) -> CGRect {
            CGRect(x: span.minX - frame.minX, y: -frame.minY, width: span.maxX - span.minX, height: Metrics.stripHeight)
        }

        let dismissFrame = layoutFrame(dismissKey)
        let chipFrame = layoutFrame(modelChip)
        let pillFrame = layoutFrame(pill)
        var dismiss = Span(minX: 0, maxX: max(dismissFrame.maxX, Metrics.dismissMinTouchWidth))
        var dictate = Span(minX: min(pillFrame.minX, bounds.width - Metrics.dictateMinTouchWidth), maxX: bounds.width)
        if modelChip.isHidden {
            split(&dismiss, &dictate)
        } else {
            var chip = Span(
                minX: chipFrame.minX + SpeechModelChip.leadingPadding - Metrics.chipTouchMargin,
                maxX: chipFrame.maxX - SpeechModelChip.trailingPadding + Metrics.chipTouchMargin
            )
            split(&dismiss, &chip)
            split(&chip, &dictate)
            modelChip.touchArea = touchArea(chip, for: chipFrame)
        }
        dismissKey.touchArea = touchArea(dismiss, for: dismissFrame)
        pill.touchArea = touchArea(dictate, for: pillFrame)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDeleteRepeat()
            hidePreview()
            closeModelPanel(animated: false)
        }
    }

    // MARK: State from the controller

    func apply(state newState: DictationViewState) {
        guard newState != state else { return }
        state = newState
        if case .processing(let message) = newState {
            pill.processingDetail = message
        } else {
            pill.processingDetail = nil
        }
        // The Speech Model stays put while a turn uses it.
        let turnRunning: Bool
        switch newState {
        case .recording, .processing: turnRunning = true
        default: turnRunning = false
        }
        modelChip.isEnabled = !turnRunning
        if turnRunning { closeModelPanel(animated: true) }
        switch newState {
        case .idle, .error:
            pill.setMode(.idle)
        case .recording(let hasLiveLevel):
            pill.setMode(.recording(liveLevel: hasLiveLevel))
        case .processing:
            pill.setMode(.processing)
        case .result:
            pill.setMode(.done)
        }
        if case .error(let message) = newState {
            showError(message)
        } else {
            hideError()
        }
    }

    /// Parakeet is loading in this keyboard process for long enough to be a first-time compile.
    /// Shown inside the idle Dictate button (dimmed mic, small spinner), never as text.
    func setPreparing(_ preparing: Bool) {
        pill.setPreparing(preparing)
    }

    /// RMS of the latest captured buffer (In-keyboard path only).
    func setInputLevels(_ levels: [Float]) {
        pill.setInputLevels(levels)
    }

    /// Auto-capitalization from the controller; a locked shift stays locked.
    func setAutoShift(_ on: Bool) {
        guard shift != .locked else { return }
        shift = on ? .on : .off
    }

    /// False on devices whose system shows its own globe below the keyboard.
    func setShowsInputModeKey(_ shows: Bool) {
        guard inputModeKey.isHidden == shows else { return }
        inputModeKey.isHidden = !shows
    }

    func setReturnKeyTitle(_ title: String) {
        guard returnKey.label.text != title else { return }
        returnKey.setTitle(title, size: 16)
    }

    // MARK: Model chip and panel

    /// The chip's Speech Model name, cross-faded when it changes; nil hides the chip.
    func setSpeechModelName(_ name: String?, animated: Bool) {
        guard let name else {
            closeModelPanel(animated: false)
            modelChip.isHidden = true
            errorAfterChip.isActive = false
            errorAfterDismiss.isActive = true
            setNeedsLayout()
            return
        }
        modelChip.setName(name, animated: animated && !modelChip.isHidden)
        guard modelChip.isHidden else { return }
        modelChip.isHidden = false
        errorAfterDismiss.isActive = false
        errorAfterChip.isActive = true
        setNeedsLayout()
    }

    func closeModelPanel(animated: Bool) {
        setModelPanelOpen(false, animated: animated)
    }

    /// Where the model panel logs its touches.
    var modelPanelDiagnostics: PanelTouchDiagnostics? {
        get { modelPanel.diagnostics }
        set { modelPanel.diagnostics = newValue }
    }

    private func openModelPanel() {
        guard let content = delegate?.speechModelPanelContent() else { return }
        modelPanel.setContent(content)
        setModelPanelOpen(true, animated: true)
    }

    /// Cross-fades the panel and the keys. Interruptible: a new direction starts from what is
    /// on screen. Reduce Motion fades only.
    private func setModelPanelOpen(_ open: Bool, animated: Bool) {
        guard open != isModelPanelOpen else { return }
        isModelPanelOpen = open
        delegate?.speechModelPanelDidChange(isOpen: open)
        modelChip.setOpen(open, animated: animated)
        dismissKey.accessibilityLabel = open ? "Close speech models" : "Hide keyboard"
        stopDeleteRepeat()
        hidePreview()

        // Stopping without finishing leaves every property where it is on screen.
        panelAnimator?.stopAnimation(true)
        panelAnimator = nil
        keyArea.isHidden = false
        modelPanel.isHidden = false
        keyArea.isUserInteractionEnabled = !open
        modelPanel.isUserInteractionEnabled = open

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.keyArea.isHidden = open
            self.modelPanel.isHidden = !open
            self.modelPanel.transform = .identity
            UIAccessibility.post(
                notification: .layoutChanged,
                argument: open ? self.modelPanel.firstAccessibleElement : self.modelChip
            )
        }
        guard animated, window != nil else {
            modelPanel.alpha = open ? 1 : 0
            keyArea.alpha = open ? 0 : 1
            finish()
            return
        }

        let animator: UIViewPropertyAnimator
        if open {
            // Only a fully faded panel starts low; one caught leaving rises from where it is.
            if (modelPanel.layer.presentation()?.opacity ?? Float(modelPanel.alpha)) < 0.01 {
                modelPanel.transform = reduceMotion
                    ? .identity : CGAffineTransform(translationX: 0, y: KeyboardMotion.panelInOffset)
            }
            animator = KeyboardMotion.panelInAnimator {
                self.modelPanel.alpha = 1
                self.modelPanel.transform = .identity
                self.keyArea.alpha = 0
            }
        } else {
            animator = KeyboardMotion.panelOutAnimator {
                self.modelPanel.alpha = 0
                self.modelPanel.transform = reduceMotion
                    ? .identity : CGAffineTransform(translationX: 0, y: KeyboardMotion.panelOutOffset)
                self.keyArea.alpha = 1
            }
        }
        animator.addCompletion { position in
            guard position == .end else { return }
            finish()
        }
        animator.startAnimation()
        panelAnimator = animator
    }

    // MARK: Error text

    private func showError(_ message: String) {
        errorGeneration += 1
        let generation = errorGeneration
        errorLabel.layer.removeAllAnimations()
        errorLabel.text = message
        errorLabel.transform = .identity
        errorLabel.accessibilityLabel = message
        UIView.animate(
            withDuration: KeyboardMotion.textInDuration, delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.errorLabel.alpha = 1
        }
        UIAccessibility.post(notification: .announcement, argument: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.errorVisibleFor) { [weak self] in
            guard let self, self.errorGeneration == generation else { return }
            self.hideError()
        }
    }

    /// Fades out, drifting down a few points; Reduce Motion fades only.
    private func hideError() {
        guard errorLabel.text != nil else { return }
        errorGeneration += 1
        let generation = errorGeneration
        let drift = UIAccessibility.isReduceMotionEnabled
            ? CGAffineTransform.identity : CGAffineTransform(translationX: 0, y: KeyboardMotion.textOutOffset)
        UIView.animate(
            withDuration: KeyboardMotion.textOutDuration, delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.errorLabel.alpha = 0
            self.errorLabel.transform = drift
        } completion: { [weak self] _ in
            guard let self, self.errorGeneration == generation else { return }
            self.errorLabel.text = nil
            self.errorLabel.transform = .identity
        }
    }

    // MARK: Build

    private func build() {
        dismissKey.setSymbol("keyboard.chevron.compact.down", size: 17, accessibilityLabel: "Hide keyboard")
        dismissKey.addTarget(self, action: #selector(keyDown), for: .touchDown)
        dismissKey.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        addSubview(dismissKey)

        modelChip.isHidden = true
        modelChip.addTarget(self, action: #selector(modelChipTapped), for: .touchUpInside)
        addSubview(modelChip)

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addTarget(self, action: #selector(dictateTapped), for: .touchUpInside)
        addSubview(pill)

        keyArea.translatesAutoresizingMaskIntoConstraints = false
        keyArea.activeKeys = { [weak self] in
            guard let self else { return [] }
            return (self.pageKeys[self.page] ?? []) + self.bottomRowKeys
        }
        addSubview(keyArea)

        modelPanel.translatesAutoresizingMaskIntoConstraints = false
        modelPanel.alpha = 0
        modelPanel.isHidden = true
        modelPanel.onSelect = { [weak self] id in
            guard let self else { return }
            self.closeModelPanel(animated: true)
            self.delegate?.didSelectSpeechModel(id)
        }
        modelPanel.onFormattingChange = { [weak self] isOn in
            self?.delegate?.didToggleFormatting(isOn)
        }
        addSubview(modelPanel)

        errorLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 1
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.adjustsFontSizeToFitWidth = true
        errorLabel.minimumScaleFactor = 0.85
        errorLabel.alpha = 0
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)

        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = Metrics.rowSpacing
        rows.distribution = .fillEqually
        rows.translatesAutoresizingMaskIntoConstraints = false
        keyArea.addSubview(rows)

        let letterRow1 = characterKeys(Self.letterRows[0], page: .letters)
        referenceKey = letterRow1[0]
        let slots = (0..<3).map { _ in UIView() }
        slots.forEach(rows.addArrangedSubview)
        rows.addArrangedSubview(buildBottomRow())

        // Letters
        place(equalRow(letterRow1), in: slots[0], page: .letters)
        place(centeredRow(characterKeys(Self.letterRows[1], page: .letters)), in: slots[1], page: .letters)
        let shift = KeyboardKey(style: .special)
        shift.addTarget(self, action: #selector(keyDown), for: .touchDown)
        shift.addTarget(self, action: #selector(shiftTapped), for: .touchDown)
        shiftKey = shift
        place(sideKeyRow(
            left: shift, middle: centeredStack(characterKeys(Self.letterRows[2], page: .letters)),
            right: deleteKey(page: .letters), middleFills: false
        ), in: slots[2], page: .letters, extraKeys: [shift])

        // Numbers and symbols
        for (page, rowsOfPage, switchTitle, switchLabel) in [
            (Page.numbers, Self.numberRows, "#+=", "More symbols"),
            (Page.symbols, Self.symbolRows, "123", "Numbers"),
        ] {
            place(equalRow(characterKeys(rowsOfPage[0], page: page)), in: slots[0], page: page)
            place(equalRow(characterKeys(rowsOfPage[1], page: page)), in: slots[1], page: page)
            let switcher = KeyboardKey(style: .special)
            switcher.setTitle(switchTitle, size: 16)
            switcher.accessibilityLabel = switchLabel
            switcher.addTarget(self, action: #selector(keyDown), for: .touchDown)
            switcher.addTarget(
                self, action: page == .numbers ? #selector(showSymbols) : #selector(showNumbers), for: .touchDown
            )
            let punctuation = UIStackView(arrangedSubviews: characterKeys(Self.punctuationRow, page: page))
            punctuation.spacing = Metrics.keySpacing
            punctuation.distribution = .fillEqually
            place(sideKeyRow(
                left: switcher, middle: punctuation, right: deleteKey(page: page), middleFills: true
            ), in: slots[2], page: page, extraKeys: [switcher])
        }

        addSubview(preview)

        NSLayoutConstraint.activate(deferredConstraints)
        deferredConstraints = []
        // The error text sits between the chip and the capsule, or after the dismiss glyph
        // when there is no chip.
        errorAfterChip = errorLabel.leadingAnchor.constraint(equalTo: modelChip.trailingAnchor, constant: 4)
        errorAfterDismiss = errorLabel.leadingAnchor.constraint(equalTo: dismissKey.trailingAnchor, constant: 4)
        errorAfterDismiss.isActive = true
        NSLayoutConstraint.activate([
            // Dictate: a small capsule at the strip's right, inset a little more than the keys
            // so it clears the keyboard's rounded top corner.
            pill.centerYAnchor.constraint(equalTo: topAnchor, constant: Metrics.stripHeight / 2),
            pill.widthAnchor.constraint(equalToConstant: DictatePill.size.width),
            pill.heightAnchor.constraint(equalToConstant: DictatePill.size.height),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.stripSideInset),

            dismissKey.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideInset),
            dismissKey.topAnchor.constraint(equalTo: topAnchor),
            dismissKey.widthAnchor.constraint(equalToConstant: 44),
            dismissKey.heightAnchor.constraint(equalToConstant: Metrics.stripHeight),

            modelChip.leadingAnchor.constraint(equalTo: dismissKey.trailingAnchor),
            modelChip.topAnchor.constraint(equalTo: topAnchor),
            modelChip.heightAnchor.constraint(equalToConstant: Metrics.stripHeight),
            modelChip.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -12),

            errorLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: pill.leadingAnchor, constant: -12),

            modelPanel.topAnchor.constraint(equalTo: keyArea.topAnchor),
            modelPanel.leadingAnchor.constraint(equalTo: keyArea.leadingAnchor),
            modelPanel.trailingAnchor.constraint(equalTo: keyArea.trailingAnchor),
            modelPanel.bottomAnchor.constraint(equalTo: keyArea.bottomAnchor),

            // The key area starts at the strip's bottom so near-misses above the top row snap to it.
            keyArea.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.stripHeight),
            keyArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyArea.bottomAnchor.constraint(equalTo: bottomAnchor),

            rows.topAnchor.constraint(equalTo: keyArea.topAnchor, constant: Metrics.stripGap),
            rows.leadingAnchor.constraint(equalTo: keyArea.leadingAnchor, constant: Metrics.sideInset),
            rows.trailingAnchor.constraint(equalTo: keyArea.trailingAnchor, constant: -Metrics.sideInset),
            rows.bottomAnchor.constraint(equalTo: keyArea.bottomAnchor, constant: -Metrics.bottomInset),
        ])
    }

    /// Bottom row, shared by every page: [123/ABC] [globe] [space] [return].
    private func buildBottomRow() -> UIView {
        modeKey.addTarget(self, action: #selector(keyDown), for: .touchDown)
        modeKey.addTarget(self, action: #selector(modeTapped), for: .touchDown)

        inputModeKey.setSymbol("globe", size: 18, accessibilityLabel: "Next keyboard")
        inputModeKey.addTarget(self, action: #selector(keyDown), for: .touchDown)

        spaceKey.setTitle("space", size: 16)
        spaceKey.addTarget(self, action: #selector(keyDown), for: .touchDown)
        spaceKey.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)

        returnKey.setTitle("return", size: 16)
        returnKey.addTarget(self, action: #selector(keyDown), for: .touchDown)
        returnKey.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [modeKey, inputModeKey, spaceKey, returnKey])
        stack.axis = .horizontal
        stack.spacing = Metrics.keySpacing
        deferredConstraints += [
            modeKey.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: Metrics.sideKeyWidth),
            inputModeKey.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: Metrics.sideKeyWidth),
            returnKey.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: Metrics.returnKeyWidth),
        ]
        bottomRowKeys = [modeKey, inputModeKey, spaceKey, returnKey]
        return stack
    }

    // MARK: Row builders

    private func characterKeys(_ characters: [String], page: Page) -> [KeyboardKey] {
        characters.map { character in
            let key = KeyboardKey(style: .character)
            key.setTitle(character, size: 22)
            key.showsPreview = true
            key.addTarget(self, action: #selector(keyDown), for: .touchDown)
            key.addTarget(self, action: #selector(characterTapped(_:)), for: .touchUpInside)
            key.addTarget(self, action: #selector(characterDragEnter(_:)), for: .touchDragEnter)
            key.addTarget(self, action: #selector(characterReleased(_:)), for: [.touchDragExit, .touchUpOutside, .touchCancel])
            if page == .letters { letterKeys.append((key, character)) }
            pageKeys[page, default: []].append(key)
            return key
        }
    }

    private func deleteKey(page: Page) -> KeyboardKey {
        let key = KeyboardKey(style: .special)
        key.setSymbol("delete.left", size: 18, accessibilityLabel: "Delete")
        key.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        key.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        pageKeys[page, default: []].append(key)
        return key
    }

    /// Keys spread across the full width.
    private func equalRow(_ keys: [KeyboardKey]) -> UIView {
        let stack = UIStackView(arrangedSubviews: keys)
        stack.spacing = Metrics.keySpacing
        stack.distribution = .fillEqually
        return stack
    }

    /// Keys as wide as row 1's, centered.
    private func centeredStack(_ keys: [KeyboardKey]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: keys)
        stack.spacing = Metrics.keySpacing
        for key in keys where key !== referenceKey {
            deferredConstraints.append(key.widthAnchor.constraint(equalTo: referenceKey.widthAnchor))
        }
        return stack
    }

    private func centeredRow(_ keys: [KeyboardKey]) -> UIView {
        let row = UIView()
        let stack = centeredStack(keys)
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        deferredConstraints += [
            stack.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ]
        return row
    }

    /// [left] middle [right], the side keys 1.3 letter keys wide. The middle either sits
    /// centered at its own width (letters) or fills the space between (punctuation).
    private func sideKeyRow(left: KeyboardKey, middle: UIStackView, right: KeyboardKey, middleFills: Bool) -> UIView {
        let row = UIView()
        middle.translatesAutoresizingMaskIntoConstraints = false
        [left, middle, right].forEach(row.addSubview)
        var constraints = [
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            left.topAnchor.constraint(equalTo: row.topAnchor),
            left.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            left.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: Metrics.sideKeyWidth),
            right.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            right.topAnchor.constraint(equalTo: row.topAnchor),
            right.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            right.widthAnchor.constraint(equalTo: referenceKey.widthAnchor, multiplier: Metrics.sideKeyWidth),
            middle.topAnchor.constraint(equalTo: row.topAnchor),
            middle.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ]
        if middleFills {
            constraints += [
                middle.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: Metrics.keySpacing * 2),
                middle.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -Metrics.keySpacing * 2),
            ]
        } else {
            constraints.append(middle.centerXAnchor.constraint(equalTo: row.centerXAnchor))
        }
        deferredConstraints += constraints
        return row
    }

    /// Stacks one page's version of a row in its slot; `pageChanged` shows one page at a time.
    private func place(_ row: UIView, in slot: UIView, page: Page, extraKeys: [KeyboardKey] = []) {
        row.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(row)
        pinEdges(row, to: slot)
        pageRows[page, default: []].append(row)
        pageKeys[page, default: []].append(contentsOf: extraKeys)
    }

    // MARK: Pages and shift

    private func pageChanged() {
        for (rowPage, rows) in pageRows {
            rows.forEach { $0.isHidden = rowPage != page }
        }
        modeKey.setTitle(page == .letters ? "123" : "ABC", size: 16)
        modeKey.accessibilityLabel = page == .letters ? "Numbers" : "Letters"
        stopDeleteRepeat()
        hidePreview()
    }

    private func shiftChanged() {
        for (key, letter) in letterKeys {
            let title = shift == .off ? letter : letter.uppercased()
            key.label.text = title
            key.accessibilityLabel = title
        }
        shiftKey.isEngaged = shift != .off
        let symbol: String
        switch shift {
        case .off: symbol = "shift"
        case .on: symbol = "shift.fill"
        case .locked: symbol = "capslock.fill"
        }
        shiftKey.setSymbol(symbol, size: 18, accessibilityLabel: shift == .locked ? "Caps lock" : "Shift")
        shiftKey.accessibilityValue = shift == .off ? nil : "On"
    }

    // MARK: Key preview

    private func showPreview(for key: KeyboardKey) {
        guard let text = key.label.text, key.window != nil else { return }
        previewOwner = key
        preview.label.text = text
        let keyFrame = key.convert(key.bounds, to: self)
        let width = keyFrame.width + 16
        let height = keyFrame.height + 12
        let halfWidth = width / 2
        let centerX = min(max(keyFrame.midX, halfWidth + 2), bounds.width - halfWidth - 2)
        preview.frame = CGRect(
            x: centerX - halfWidth, y: max(0, keyFrame.minY - height + 2), width: width, height: height
        )
        preview.isHidden = false
    }

    private func hidePreview(for key: KeyboardKey? = nil) {
        guard key == nil || key === previewOwner else { return }
        preview.isHidden = true
        previewOwner = nil
    }

    // MARK: Backspace repeat

    @objc private func deleteDown() {
        UIDevice.current.playInputClick()
        delegate?.didTapBackspace()
        stopDeleteRepeat()
        deleteStartedAt = CACurrentMediaTime()
        deleteTicks = 0
        deleteTimer = scheduledTimer(Metrics.deleteDelay, repeats: false) { [weak self] in
            guard let self else { return }
            self.deleteRepeatTick()
            self.deleteTimer = self.scheduledTimer(Metrics.deleteInterval, repeats: true) { [weak self] in
                self?.deleteRepeatTick()
            }
        }
    }

    @objc private func deleteUp() {
        stopDeleteRepeat()
    }

    private func deleteRepeatTick() {
        deleteTicks += 1
        if CACurrentMediaTime() - deleteStartedAt >= Metrics.wordDeleteAfter {
            guard deleteTicks.isMultiple(of: 2) else { return }
            UIDevice.current.playInputClick()
            delegate?.didDeleteWordBackward()
        } else {
            UIDevice.current.playInputClick()
            delegate?.didTapBackspace()
        }
    }

    private func stopDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    private func scheduledTimer(_ interval: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Actions

    /// Every key clicks on touch-down, like the system keyboard (when Keyboard Clicks is on).
    @objc private func keyDown(_ sender: KeyboardKey) {
        UIDevice.current.playInputClick()
        if sender.showsPreview { showPreview(for: sender) }
    }

    @objc private func characterDragEnter(_ sender: KeyboardKey) {
        showPreview(for: sender)
    }

    @objc private func characterReleased(_ sender: KeyboardKey) {
        hidePreview(for: sender)
    }

    @objc private func characterTapped(_ sender: KeyboardKey) {
        hidePreview(for: sender)
        guard let text = sender.label.text else { return }
        // Shift is spent before the insert, so the controller's auto-capitalization decides next.
        if page == .letters, shift == .on { shift = .off }
        delegate?.didInsertText(text)
        // As on the system keyboard, an apostrophe returns to the letters.
        if page != .letters, text == "'" { page = .letters }
    }

    @objc private func shiftTapped() {
        let now = CACurrentMediaTime()
        if shift == .on, now - lastShiftTapAt < Metrics.capsLockTapWindow {
            shift = .locked
        } else {
            shift = shift == .off ? .on : .off
        }
        lastShiftTapAt = now
    }

    @objc private func modeTapped() { page = page == .letters ? .numbers : .letters }
    @objc private func showSymbols() { page = .symbols }
    @objc private func showNumbers() { page = .numbers }

    @objc private func spaceTapped() {
        delegate?.didInsertText(" ")
        if page != .letters { page = .letters }
    }

    @objc private func returnTapped() { delegate?.didInsertText("\n") }
    @objc private func dictateTapped() { delegate?.didTapDictate() }
    @objc private func dismissTapped() {
        // While the model panel is open, the dismiss glyph closes it instead.
        if isModelPanelOpen {
            closeModelPanel(animated: true)
            return
        }
        delegate?.didTapDismiss()
    }

    @objc private func modelChipTapped() {
        if isModelPanelOpen {
            closeModelPanel(animated: true)
        } else {
            openModelPanel()
        }
    }
}
