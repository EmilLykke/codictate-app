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

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            refresh()
        }
    }

    private func refresh() {
        // Outside any animation block: the change is instant.
        fill.backgroundColor = currentFill
        let foreground: UIColor = isEngaged ? .black : .label
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

/// Holds the key rows. A touch in a gap between keys, or in the margin around them, goes to
/// the nearest key, as on the system keyboard, so no tap lands on nothing.
private final class KeyArea: UIView {
    var activeKeys: () -> [KeyboardKey] = { [] }
    static let snapDistance: CGFloat = 12

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit is KeyboardKey { return hit }
        guard self.point(inside: point, with: event) else { return hit }
        var nearest: KeyboardKey?
        var nearestDistance = Self.snapDistance * Self.snapDistance
        for key in activeKeys() where key.window != nil && !key.isHidden {
            let frame = key.convert(key.bounds, to: self)
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if distance <= nearestDistance {
                nearest = key
                nearestDistance = distance
            }
        }
        return nearest ?? hit
    }
}

// MARK: - DictationKeyboardView

final class DictationKeyboardView: UIView {

    weak var delegate: DictationKeyboardViewDelegate?

    static let preparingMessage = "Getting Parakeet ready (first time only)"

    private enum Page { case letters, numbers, symbols }
    private enum Shift { case off, on, locked }

    private enum Metrics {
        static let height: CGFloat = 264
        static let pillTop: CGFloat = 6
        /// The status line between the pill and the keys; empty most of the time, it doubles
        /// as the gap above the top row.
        static let statusHeight: CGFloat = 18
        static let sideInset: CGFloat = 3
        static let bottomInset: CGFloat = 4
        static let rowSpacing: CGFloat = 8
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
    private let statusLabel = UILabel()
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
    private var isPreparing = false

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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDeleteRepeat()
            hidePreview()
        }
    }

    // MARK: State from the controller

    func apply(state newState: DictationViewState) {
        guard newState != state else { return }
        state = newState
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
        updateStatus()
    }

    /// Parakeet is loading in this keyboard process for long enough to be a first-time compile.
    func setPreparing(_ preparing: Bool) {
        guard preparing != isPreparing else { return }
        isPreparing = preparing
        updateStatus()
    }

    /// RMS of the latest captured buffer (In-keyboard path only).
    func setInputLevel(_ rms: Float) {
        pill.setInputLevel(rms)
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

    private func updateStatus() {
        let text: String
        let color: UIColor
        switch state {
        case .error(let message):
            text = message
            color = .systemRed
        case .processing(let message):
            // The pill already says "Transcribing…"; the line keeps the rest of the message.
            let prefix = "Transcribing. "
            let full = message ?? ""
            text = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
            color = .secondaryLabel
        case .idle, .recording:
            text = isPreparing ? Self.preparingMessage : ""
            color = .secondaryLabel
        case .result:
            text = ""
            color = .secondaryLabel
        }
        guard statusLabel.text != text || statusLabel.textColor != color else { return }
        UIView.transition(
            with: statusLabel, duration: KeyboardMotion.colorDuration,
            options: [.transitionCrossDissolve, .beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) {
            self.statusLabel.text = text
            self.statusLabel.textColor = color
        }
    }

    // MARK: Build

    private func build() {
        dismissKey.setSymbol("keyboard.chevron.compact.down", size: 18, accessibilityLabel: "Hide keyboard")
        dismissKey.addTarget(self, action: #selector(keyDown), for: .touchDown)
        dismissKey.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        addSubview(dismissKey)

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addTarget(self, action: #selector(dictateTapped), for: .touchUpInside)
        addSubview(pill)

        keyArea.translatesAutoresizingMaskIntoConstraints = false
        keyArea.activeKeys = { [weak self] in
            guard let self else { return [] }
            return (self.pageKeys[self.page] ?? []) + self.bottomRowKeys
        }
        addSubview(keyArea)

        statusLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

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
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.pillTop),
            pill.heightAnchor.constraint(equalToConstant: DictatePill.height),
            pill.leadingAnchor.constraint(equalTo: dismissKey.trailingAnchor, constant: 4),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.sideInset),

            dismissKey.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideInset),
            dismissKey.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dismissKey.widthAnchor.constraint(equalToConstant: 44),
            dismissKey.heightAnchor.constraint(equalToConstant: 44),

            statusLabel.topAnchor.constraint(equalTo: pill.bottomAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: Metrics.statusHeight),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // The key area starts just under the pill so near-misses above the top row snap to it.
            keyArea.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 2),
            keyArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyArea.bottomAnchor.constraint(equalTo: bottomAnchor),

            rows.topAnchor.constraint(equalTo: statusLabel.bottomAnchor),
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
    @objc private func dismissTapped() { delegate?.didTapDismiss() }
}
