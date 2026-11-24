import UIKit

// The keyboard's model switcher: a quiet chip in the strip naming the Speech Model, and a
// panel that takes the keys' place to pick another one and turn S1-mini on or off. The views
// know nothing about Speech Models; the controller builds `SpeechModelPanelContent` from the
// catalog and the App Group.

// MARK: - Content

/// One Speech Model tile of the panel.
struct SpeechModelOption: Equatable {
    /// The Speech Model's id, as stored in `preferredModelVariant`.
    let id: String
    let name: String
    /// Its languages, or why it cannot run the stored Transcription Language.
    let hint: String
    /// Its Language Lock accepts the stored Transcription Language.
    let isAvailable: Bool
    let isCurrent: Bool
}

struct SpeechModelPanelContent: Equatable {
    /// The installed Speech Models.
    var models: [SpeechModelOption]
    /// S1-mini's switch; nil hides the row (S1-mini is not downloaded).
    var formattingIsOn: Bool?
}

// MARK: - Motion

extension KeyboardMotion {
    /// The panel replacing the keys: in over 0.2 s on a strong ease-out, rising 8 pt; out
    /// softer, 0.15 s, sinking 4 pt. Reduce Motion fades only.
    static let panelInDuration: TimeInterval = 0.2
    static let panelOutDuration: TimeInterval = 0.15
    static let panelInOffset: CGFloat = 8
    static let panelOutOffset: CGFloat = 4
    /// The chip's name cross-fades when the Speech Model changes.
    static let chipTextDuration: TimeInterval = 0.15

    static func panelInAnimator(_ animations: @escaping () -> Void) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(
            duration: panelInDuration,
            controlPoint1: CGPoint(x: 0.23, y: 1), controlPoint2: CGPoint(x: 0.32, y: 1),
            animations: animations
        )
    }

    static func panelOutAnimator(_ animations: @escaping () -> Void) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: panelOutDuration, curve: .easeOut, animations: animations)
    }
}

// MARK: - SpeechModelChip

/// The current Speech Model's name and a small up-down chevron, right of the dismiss glyph.
/// No fill. Pressing dims it at once (no scale: it is tapped often enough that motion would
/// get in the way); while the panel is open the chevron becomes a close mark.
final class SpeechModelChip: UIControl {
    private static let font = UIFont.systemFont(ofSize: 13, weight: .medium)
    private static let glyphConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
    private static let glyphSide: CGFloat = 12
    static let leadingPadding: CGFloat = 4
    static let trailingPadding: CGFloat = 10

    private let content = UIView()
    private let nameLabel = UILabel()
    private let chevron = UIImageView()
    private let closeMark = UIImageView()
    private(set) var isOpen = false
    private var enabledAnimator: UIViewPropertyAnimator?
    /// Where touches land, in the chip's coordinates; the keyboard view sets it so the chip
    /// answers across the strip's height and beside its text. Nil: its bounds.
    var touchArea: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        pinEdges(content, to: self)

        nameLabel.font = Self.font
        nameLabel.textColor = .secondaryLabel
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        // The error text between the chip and the capsule gives way first.
        nameLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        content.addSubview(nameLabel)

        let slot = UIView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(slot)
        for (glyph, name) in [(chevron, "chevron.up.chevron.down"), (closeMark, "xmark")] {
            glyph.image = UIImage(systemName: name, withConfiguration: Self.glyphConfiguration)
            glyph.tintColor = .secondaryLabel
            glyph.contentMode = .center
            glyph.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            ])
        }
        closeMark.alpha = 0
        closeMark.transform = CGAffineTransform(scaleX: KeyboardMotion.swapScale, y: KeyboardMotion.swapScale)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.leadingPadding),
            nameLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            slot.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            slot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.trailingPadding),
            // The label's box includes room for descenders; half a point down meets the text's middle.
            slot.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor, constant: 0.5),
            slot.widthAnchor.constraint(equalToConstant: Self.glyphSide),
            slot.heightAnchor.constraint(equalToConstant: Self.glyphSide),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        isAccessibilityElement = true
        accessibilityLabel = "Speech model"
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError() }

    var name: String? { nameLabel.text }

    /// Cross-fades to `name` when animated.
    func setName(_ name: String, animated: Bool) {
        guard nameLabel.text != name else { return }
        accessibilityValue = name
        guard animated, window != nil, nameLabel.text != nil else {
            nameLabel.text = name
            return
        }
        UIView.transition(
            with: nameLabel, duration: KeyboardMotion.chipTextDuration,
            options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.nameLabel.text = name
        }
    }

    /// The chevron becomes a close mark while the panel is open: the outgoing glyph shrinks to
    /// `swapScale` and fades as the other grows from it. Reduce Motion keeps the fade only.
    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        updateAccessibility()
        let shown = open ? closeMark : chevron
        let hidden = open ? chevron : closeMark
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let shrunk = CGAffineTransform(scaleX: KeyboardMotion.swapScale, y: KeyboardMotion.swapScale)
        guard animated else {
            shown.alpha = 1
            shown.transform = .identity
            hidden.alpha = 0
            hidden.transform = shrunk
            return
        }
        // Only a fully faded glyph starts small; one caught mid-fade continues from where it is.
        if (shown.layer.presentation()?.opacity ?? Float(shown.alpha)) < 0.01 {
            shown.transform = reduceMotion ? .identity : shrunk
        }
        KeyboardMotion.spring {
            shown.alpha = 1
            shown.transform = .identity
            hidden.alpha = 0
            hidden.transform = reduceMotion ? .identity : shrunk
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        touchArea?.contains(point) ?? super.point(inside: point, with: event)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            // Outside any animation block: instant.
            content.alpha = isHighlighted ? 0.5 : 1
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        isHighlighted = false
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            updateAccessibility()
            enabledAnimator?.stopAnimation(true)
            enabledAnimator = nil
            let target: CGFloat = isEnabled ? 1 : 0.4
            guard window != nil else {
                alpha = target
                return
            }
            let animator = KeyboardMotion.colorAnimator { self.alpha = target }
            animator.startAnimation()
            enabledAnimator = animator
        }
    }

    private func updateAccessibility() {
        accessibilityHint = isOpen ? "Double tap to close" : "Double tap to change"
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
    }
}

// MARK: - SpeechModelPanel

/// Where the panel's touch diagnostics go. The controller supplies both: the log, and the
/// keyboard window's system gesture recognizers, whose states a cancelled touch reports.
struct PanelTouchDiagnostics {
    var write: (String) -> Void
    var systemRecognizers: () -> [UIGestureRecognizer]
}

/// Takes the key area's place at the same height and never scrolls: the installed Speech
/// Models as key-like tiles, two to a row, then a hairline and S1-mini's switch when S1-mini
/// is downloaded. When they would not fit, the tiles shrink (to `minTileHeight`) instead.
/// Every point of the panel near a tile or the switch's row belongs to it: the gaps between
/// tiles split at the middle, and the side and top insets go to the tile beside them.
final class SpeechModelPanel: UIView {
    static let sideInset: CGFloat = 16
    static let tileSpacing: CGFloat = 8
    static let tileHeight: CGFloat = 44
    static let minTileHeight: CGFloat = 38
    static let topInset: CGFloat = 6
    /// Between the tiles and the footnote or the hairline above S1-mini's row.
    static let sectionGap: CGFloat = 6
    static let formattingRowHeight: CGFloat = 44
    /// A touch this far from every tile and row (an empty cell beside an odd last tile, the
    /// space under a short panel) lands on the panel itself and does nothing.
    static let touchReach: CGFloat = 16
    /// Touch log lines per opening, so a stuck finger cannot flood the log.
    private static let maxLogLines = 40

    var onSelect: ((String) -> Void)?
    var onFormattingChange: ((Bool) -> Void)?
    var diagnostics: PanelTouchDiagnostics?

    private var tiles: [SpeechModelTile] = []
    private var footnote: UILabel?
    private var formattingRow: FormattingRow?
    private let separator = UIView()
    private(set) var firstAccessibleElement: UIView?
    private var logLines = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        separator.backgroundColor = .separator
        separator.isUserInteractionEnabled = false
        separator.isHidden = true
        addSubview(separator)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setContent(_ content: SpeechModelPanelContent) {
        tiles.forEach { $0.removeFromSuperview() }
        footnote?.removeFromSuperview()
        formattingRow?.removeFromSuperview()
        tiles = []
        footnote = nil
        formattingRow = nil
        firstAccessibleElement = nil
        logLines = 0

        for option in content.models {
            let tile = SpeechModelTile(option: option)
            tile.addTarget(self, action: #selector(tileTapped(_:)), for: .primaryActionTriggered)
            tile.onTouchEvent = { [weak self, weak tile] event in
                guard let self, let tile else { return }
                self.log(event, on: tile)
            }
            addSubview(tile)
            tiles.append(tile)
        }
        firstAccessibleElement = tiles.first
        if content.models.count <= 1 {
            let label = UILabel()
            label.text = content.models.isEmpty
                ? "Download a model in Codictate."
                : "Download more models in Codictate."
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            addSubview(label)
            footnote = label
            if firstAccessibleElement == nil { firstAccessibleElement = label }
        }
        if let isOn = content.formattingIsOn {
            let row = FormattingRow(isOn: isOn)
            row.onChange = { [weak self] on in self?.onFormattingChange?(on) }
            row.onTouchEvent = { [weak self, weak row] event in
                guard let self, let row else { return }
                self.log(event, on: row)
            }
            addSubview(row)
            formattingRow = row
            if firstAccessibleElement == nil { firstAccessibleElement = row.toggle }
        }
        separator.isHidden = formattingRow == nil
        // Above the row, so its pressed fill never covers the line.
        bringSubviewToFront(separator)
        setNeedsLayout()
    }

    // MARK: Layout

    /// Tile height for `rows` rows in a panel `height` tall: 44 pt, or less (down to 38) when
    /// the content would otherwise not fit.
    private func tileHeight(rows: Int, height: CGFloat, footnoteHeight: CGFloat) -> CGFloat {
        guard rows > 0 else { return 0 }
        var fixed = Self.topInset + CGFloat(rows - 1) * Self.tileSpacing
        if footnote != nil { fixed += Self.sectionGap + footnoteHeight }
        if formattingRow != nil { fixed += Self.sectionGap + Self.formattingRowHeight }
        let fitting = floor((height - fixed) / CGFloat(rows))
        return min(Self.tileHeight, max(Self.minTileHeight, fitting))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let contentWidth = width - Self.sideInset * 2
        let tileWidth = (contentWidth - Self.tileSpacing) / 2
        let rows = (tiles.count + 1) / 2
        let footnoteHeight = footnote.map {
            ceil($0.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
        } ?? 0
        let tileHeight = tileHeight(rows: rows, height: bounds.height, footnoteHeight: footnoteHeight)

        var y = Self.topInset
        for (index, tile) in tiles.enumerated() {
            let row = index / 2
            let column = index % 2
            // An odd last tile keeps its column's width, left aligned.
            tile.frame = CGRect(
                x: Self.sideInset + CGFloat(column) * (tileWidth + Self.tileSpacing),
                y: Self.topInset + CGFloat(row) * (tileHeight + Self.tileSpacing),
                width: tileWidth, height: tileHeight
            )
        }
        if rows > 0 { y += CGFloat(rows) * tileHeight + CGFloat(rows - 1) * Self.tileSpacing }
        if let footnote {
            if rows > 0 { y += Self.sectionGap }
            footnote.frame = CGRect(x: Self.sideInset, y: y, width: contentWidth, height: footnoteHeight)
            y += footnoteHeight
        }
        if let formattingRow {
            if rows > 0 || footnote != nil { y += Self.sectionGap }
            formattingRow.frame = CGRect(x: 0, y: y, width: width, height: Self.formattingRowHeight)
            let scale = max(traitCollection.displayScale, 1)
            separator.frame = CGRect(x: 0, y: y, width: width, height: 1 / scale)
        }
    }

    // MARK: Touches

    /// The tile or row nearest `point` (gaps and insets included), or the panel itself when
    /// none is within `touchReach`.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else {
            return nil
        }
        return nearestControl(to: point) ?? self
    }

    func nearestControl(to point: CGPoint) -> PanelTapControl? {
        var nearest: PanelTapControl?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        let controls: [PanelTapControl] = tiles + (formattingRow.map { [$0] } ?? [])
        for control in controls where !control.isHidden {
            let frame = control.frame
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < nearestDistance {
                nearest = control
                nearestDistance = distance
            }
        }
        return nearestDistance <= Self.touchReach ? nearest : nil
    }

    @objc private func tileTapped(_ tile: SpeechModelTile) {
        onSelect?(tile.optionID)
    }

    private func log(_ event: PanelTapControl.TouchEvent, on control: PanelTapControl) {
        guard let diagnostics, logLines < Self.maxLogLines else { return }
        logLines += 1
        let name = control.touchName
        let line: String
        switch event {
        case .began:
            line = "began \(name)"
        case .ended(let tapped, let moved):
            line = "ended \(name) \(tapped ? "selected" : "not selected") moved \(Self.points(moved))"
        case .cancelled(let moved, let duration, let touch, let rescued):
            var seen = Set<ObjectIdentifier>()
            let recognizers = (diagnostics.systemRecognizers() + (touch.gestureRecognizers ?? [])).filter {
                seen.insert(ObjectIdentifier($0)).inserted
            }
            let active = recognizers.compactMap { recognizer -> String? in
                guard let state = Self.activeStateName(recognizer.state) else { return nil }
                return "\(String(describing: type(of: recognizer)))=\(state)"
            }
            let by = active.isEmpty ? "none active of \(recognizers.count)" : active.joined(separator: ",")
            line = "cancelled \(name) moved \(Self.points(moved)) \(String(format: "%.2f", duration))s by \(by)"
                + (rescued ? "; tap rescued from cancel" : "")
        }
        diagnostics.write("[Keyboard][Touch] \(line)")
        if logLines == Self.maxLogLines {
            diagnostics.write("[Keyboard][Touch] log capped at \(Self.maxLogLines) lines until the panel reopens")
        }
    }

    private static func points(_ value: CGFloat) -> String {
        "\(Int(value.rounded()))pt"
    }

    /// A recognizer that has claimed (or is claiming) its gesture; nil while it only watches.
    private static func activeStateName(_ state: UIGestureRecognizer.State) -> String? {
        switch state {
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "recognized"
        case .cancelled: return "cancelled"
        default: return nil
        }
    }
}

// MARK: - Tap tracking

/// Decides whether one touch on a panel control is a tap. It may end within the control's
/// bounds grown by `slop` (or within `slop` of where it started, for a touch that began in
/// the padding the control owns). A touch iOS cancels still counts as a tap when it never
/// wandered `slop` from its start, never left that area, and lasted under `rescueWindow`:
/// a system gesture recognizer claiming a still finger must not swallow the tap.
struct PanelTapTracker {
    static let slop: CGFloat = 12
    static let rescueWindow: TimeInterval = 0.6

    let start: CGPoint
    let startTime: TimeInterval
    let area: CGRect
    /// The farthest the touch has been from its start.
    private(set) var maxDistance: CGFloat = 0
    private(set) var stayedInside = true

    init(start: CGPoint, time: TimeInterval, bounds: CGRect) {
        self.start = start
        startTime = time
        area = bounds.insetBy(dx: -Self.slop, dy: -Self.slop)
            .union(CGRect(x: start.x - Self.slop, y: start.y - Self.slop, width: Self.slop * 2, height: Self.slop * 2))
    }

    /// Whether `point` is still close enough to count.
    @discardableResult
    mutating func move(to point: CGPoint) -> Bool {
        let dx = point.x - start.x
        let dy = point.y - start.y
        maxDistance = max(maxDistance, (dx * dx + dy * dy).squareRoot())
        let inside = area.contains(point)
        if !inside { stayedInside = false }
        return inside
    }

    mutating func endIsTap(at point: CGPoint) -> Bool {
        move(to: point)
    }

    mutating func cancelIsTap(at point: CGPoint, time: TimeInterval) -> Bool {
        move(to: point)
        return stayedInside && maxDistance < Self.slop && time - startTime < Self.rescueWindow
    }
}

/// A tile or row of the panel. It tracks its own touch (`PanelTapTracker`) rather than
/// relying on UIControl's tracking: it lights up on touch-down, fires
/// `.primaryActionTriggered` for a tap, and still fires for a tap iOS cancelled.
class PanelTapControl: UIControl {
    enum TouchEvent {
        case began
        case ended(tapped: Bool, moved: CGFloat)
        case cancelled(moved: CGFloat, duration: TimeInterval, touch: UITouch, rescued: Bool)
    }

    var onTouchEvent: ((TouchEvent) -> Void)?
    /// Names the control in the touch log.
    var touchName: String { "" }
    private var tracker: PanelTapTracker?
    private weak var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        tracker = PanelTapTracker(start: touch.location(in: self), time: touch.timestamp, bounds: bounds)
        // Outside any animation block: instant, like a key.
        isHighlighted = isEnabled
        onTouchEvent?(.began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch), var tracker else { return }
        isHighlighted = isEnabled && tracker.move(to: touch.location(in: self))
        self.tracker = tracker
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch), var tracker else { return }
        let tapped = tracker.endIsTap(at: touch.location(in: self)) && isEnabled
        finish()
        onTouchEvent?(.ended(tapped: tapped, moved: tracker.maxDistance))
        if tapped { sendActions(for: .primaryActionTriggered) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch), var tracker else { return }
        // Cancelled because the panel went away is never a tap.
        let onScreen = window != nil && isUserInteractionEnabled && superview?.isUserInteractionEnabled == true
        let rescued = tracker.cancelIsTap(at: touch.location(in: self), time: touch.timestamp)
            && onScreen && isEnabled
        finish()
        onTouchEvent?(.cancelled(
            moved: tracker.maxDistance, duration: touch.timestamp - tracker.startTime, touch: touch, rescued: rescued
        ))
        if rescued { sendActions(for: .primaryActionTriggered) }
    }

    private func finish() {
        trackedTouch = nil
        tracker = nil
        isHighlighted = false
    }
}

// MARK: - Tiles

private extension KeyboardPalette {
    /// The current Speech Model's tile: the key fill tinted with the system blue.
    static let selectedTile = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.264, green: 0.407, blue: 0.552, alpha: 1)
            : UIColor(red: 0.86, green: 0.935, blue: 1, alpha: 1)
    }
}

/// A Speech Model as a key: its name over its languages, on the key fill with the keys'
/// shadow. The current one is tinted, its name heavier, with a checkmark. Pressing changes
/// the fill at once, like a key. One its Language Lock rejects is dimmed and says why.
private final class SpeechModelTile: PanelTapControl {
    static let cornerRadius: CGFloat = 10
    private static let contentInset: CGFloat = 12

    let optionID: String
    private let isCurrent: Bool
    private let fill = UIView()
    private let nameLabel = UILabel()
    private let hintLabel = UILabel()
    private let check = UIImageView()

    override var touchName: String { nameLabel.text ?? optionID }

    init(option: SpeechModelOption) {
        optionID = option.id
        isCurrent = option.isCurrent
        super.init(frame: .zero)

        fill.isUserInteractionEnabled = false
        fill.layer.cornerRadius = Self.cornerRadius
        fill.layer.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        pinEdges(fill, to: self)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)

        nameLabel.text = option.name
        nameLabel.font = UIFont.systemFont(ofSize: 15, weight: option.isCurrent ? .semibold : .medium)
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail
        // A long name shrinks a little before it truncates.
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.85

        hintLabel.text = option.hint
        hintLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.lineBreakMode = .byTruncatingTail

        check.image = UIImage(
            systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        check.tintColor = .systemBlue
        check.contentMode = .center
        check.isHidden = !option.isCurrent

        let text = UIStackView(arrangedSubviews: [nameLabel, hintLabel])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [text, check] as [UIView] {
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -4),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 16),
        ])

        isEnabled = option.isAvailable
        alpha = option.isAvailable ? 1 : 0.4
        isAccessibilityElement = true
        accessibilityLabel = option.name
        accessibilityValue = option.hint
        var traits: UIAccessibilityTraits = .button
        if option.isCurrent { traits.insert(.selected) }
        if !option.isAvailable { traits.insert(.notEnabled) }
        accessibilityTraits = traits
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            refresh()
        }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .primaryActionTriggered)
        return true
    }

    private func refresh() {
        // Outside any animation block: instant.
        if isHighlighted {
            fill.backgroundColor = KeyboardPalette.characterKeyPressed
        } else {
            fill.backgroundColor = isCurrent ? KeyboardPalette.selectedTile : KeyboardPalette.characterKey
        }
    }
}

/// S1-mini on or off. A tap anywhere on the row flips the switch: the row takes every touch,
/// the switch's included (its thumb does not slide). The switch carries the row's
/// accessibility and still answers VoiceOver itself.
private final class FormattingRow: PanelTapControl {
    let toggle = UISwitch()
    var onChange: ((Bool) -> Void)?

    override var touchName: String { "S1-mini" }

    init(isOn: Bool) {
        super.init(frame: .zero)
        let nameLabel = UILabel()
        // The model's name, exactly as its license asks.
        nameLabel.text = "S1-mini"
        nameLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = .label
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let hintLabel = UILabel()
        hintLabel.text = "Clean up English text"
        hintLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.lineBreakMode = .byTruncatingTail

        toggle.isOn = isOn
        toggle.addTarget(self, action: #selector(toggled), for: .valueChanged)
        toggle.accessibilityLabel = "S1-mini"
        toggle.accessibilityHint = "Cleans up English text."

        for view in [nameLabel, hintLabel, toggle] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameLabel.isAccessibilityElement = false
        hintLabel.isAccessibilityElement = false
        let inset = SpeechModelPanel.sideInset
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            hintLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTarget(self, action: #selector(rowTapped), for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Touches anywhere on the row, the switch included, belong to the row.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            // Outside any animation block: instant.
            backgroundColor = isHighlighted ? KeyboardPalette.toolbarPressed : .clear
        }
    }

    @objc private func rowTapped() {
        toggle.setOn(!toggle.isOn, animated: true)
        onChange?(toggle.isOn)
    }

    /// VoiceOver flips the switch directly.
    @objc private func toggled() {
        onChange?(toggle.isOn)
    }
}
