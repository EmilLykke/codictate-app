import UIKit

// The keyboard's model switcher: a quiet chip in the strip naming the Speech Model, and a
// panel that takes the keys' place to pick another one and turn S1-mini on or off. The views
// know nothing about Speech Models; the controller builds `SpeechModelPanelContent` from the
// catalog and the App Group.

// MARK: - Content

/// One Speech Model row of the panel.
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

/// Takes the key area's place at the same height: the installed Speech Models, one 44 pt row
/// each, then S1-mini's switch when S1-mini is downloaded. Scrolls when they do not fit.
final class SpeechModelPanel: UIView {
    static let rowHeight: CGFloat = 44
    static let textInset: CGFloat = 16
    private static let verticalInset: CGFloat = 4

    var onSelect: ((String) -> Void)?
    var onFormattingChange: ((Bool) -> Void)?

    private let scrollView = PanelScrollView()
    private let stack = UIStackView()
    private weak var currentRow: UIView?
    private(set) var firstAccessibleElement: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Scrolls only when the rows do not fit; when they do, a tap that drifts a little
        // still selects instead of starting a bounce.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInset = UIEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        // Rows highlight on touch-down; once a drag turns into a scroll, the scroll view takes
        // the touch back (`PanelScrollView`), cancelling the row.
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.rows = stack
        addSubview(scrollView)
        pinEdges(scrollView, to: self)

        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        // The content is exactly as wide as the panel and as tall as the rows, so it scrolls
        // vertically only, and only when the rows are taller than the panel.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A row scrolled past an edge fades out over 12 pt instead of being cut, so it never
    /// looks tucked under the strip above. On the panel, not the scroll view, so it stays put.
    private let edgeFade = CAGradientLayer()
    private static let fadeLength: CGFloat = 12

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height > Self.fadeLength * 2 else { return }
        let stop = NSNumber(value: Double(Self.fadeLength / bounds.height))
        edgeFade.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        edgeFade.locations = [0, stop, NSNumber(value: 1 - stop.doubleValue), 1]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = bounds
        CATransaction.commit()
        if layer.mask !== edgeFade { layer.mask = edgeFade }
    }

    func setContent(_ content: SpeechModelPanelContent) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        currentRow = nil
        firstAccessibleElement = nil

        for (index, option) in content.models.enumerated() {
            let row = SpeechModelRow(option: option, showsSeparator: index < content.models.count - 1)
            row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(row)
            if option.isCurrent { currentRow = row }
            if firstAccessibleElement == nil { firstAccessibleElement = row }
        }
        if content.models.count <= 1 {
            let footnote = UILabel()
            footnote.text = content.models.isEmpty
                ? "Download a model in Codictate."
                : "Download more models in Codictate."
            footnote.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            footnote.textColor = .secondaryLabel
            footnote.numberOfLines = 0
            stack.addArrangedSubview(Self.padded(footnote, top: 6, bottom: 12))
            if firstAccessibleElement == nil { firstAccessibleElement = footnote }
        }
        if let isOn = content.formattingIsOn {
            if !content.models.isEmpty { stack.addArrangedSubview(Self.hairline(inset: 0)) }
            let row = FormattingRow(isOn: isOn)
            row.onChange = { [weak self] on in self?.onFormattingChange?(on) }
            stack.addArrangedSubview(row)
            if firstAccessibleElement == nil { firstAccessibleElement = row.toggle }
        }
    }

    /// Back to the top, or as far down as it takes to show the current Speech Model. When
    /// the rows do not all fit, the scroll indicator flashes to say so.
    func scrollToCurrent() {
        layoutIfNeeded()
        // Clamped to the scrollable range, so the first drag never jumps.
        let inset = scrollView.adjustedContentInset
        let top = -inset.top
        let bottom = max(top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        var offset = top
        if let currentRow {
            offset = currentRow.frame.maxY + Self.verticalInset - scrollView.bounds.height
        }
        scrollView.contentOffset = CGPoint(x: 0, y: min(max(offset, top), bottom))
        if scrollView.contentSize.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom
            > scrollView.bounds.height {
            scrollView.flashScrollIndicators()
        }
    }

    @objc private func rowTapped(_ row: SpeechModelRow) {
        onSelect?(row.optionID)
    }

    static func hairline(inset: CGFloat) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        let line = Hairline()
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private static func padded(_ view: UIView, top: CGFloat, bottom: CGFloat) -> UIView {
        let container = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: textInset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -textInset),
        ])
        return container
    }
}

/// One device pixel tall, in the separator color.
private final class Hairline: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .separator
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Hairline, _: UITraitCollection) in
            self.invalidateIntrinsicContentSize()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 1 / max(traitCollection.displayScale, 1))
    }
}

/// The panel's scroller. Its rows are controls that fill the content, and a stock scroll
/// view never cancels a touch that began on a `UIControl`, so no drag starting on a row
/// would scroll. Here every drag that turns into a scroll takes the touch back (the row's
/// highlight clears, nothing is picked); a tap, or a touch that lifts before the pan begins,
/// still reaches the row. A touch in the insets or on a separator goes to the nearest row.
private final class PanelScrollView: UIScrollView {
    /// How far above or below a row a touch still lands on it.
    private static let rowSnapDistance: CGFloat = 12
    weak var rows: UIStackView?

    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let hit, hit === self || hit === rows || hit.superview === rows, !(hit is UIControl),
              let rows else { return hit }
        var nearest: UIControl?
        var nearestDistance = Self.rowSnapDistance
        for case let row as UIControl in rows.arrangedSubviews where !row.isHidden {
            let frame = row.convert(row.bounds, to: self)
            let distance = max(frame.minY - point.y, 0, point.y - frame.maxY)
            if distance <= nearestDistance {
                nearest = row
                nearestDistance = distance
            }
        }
        return nearest ?? hit
    }
}

// MARK: - Rows

/// A Speech Model: name, its languages at the right, and a checkmark on the current one.
/// Pressing tints it at once, like a key. One its Language Lock rejects is dimmed and says why.
private final class SpeechModelRow: UIControl {
    let optionID: String
    private let nameLabel = UILabel()
    private let hintLabel = UILabel()
    private let check = UIImageView()

    init(option: SpeechModelOption, showsSeparator: Bool) {
        optionID = option.id
        super.init(frame: .zero)

        nameLabel.text = option.name
        nameLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        nameLabel.textColor = .label
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        hintLabel.text = option.hint
        hintLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .right
        hintLabel.lineBreakMode = .byTruncatingTail

        check.image = UIImage(
            systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        check.contentMode = .center
        check.isHidden = !option.isCurrent

        for view in [nameLabel, hintLabel, check] as [UIView] {
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = SpeechModelPanel.textInset
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SpeechModelPanel.rowHeight),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 18),
            hintLabel.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -10),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 12),
            hintLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
        ])
        if showsSeparator {
            let separator = SpeechModelPanel.hairline(inset: inset)
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        isEnabled = option.isAvailable
        alpha = option.isAvailable ? 1 : 0.4
        isAccessibilityElement = true
        accessibilityLabel = option.name
        accessibilityValue = option.hint
        var traits: UIAccessibilityTraits = .button
        if option.isCurrent { traits.insert(.selected) }
        if !option.isAvailable { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            // Outside any animation block: instant.
            backgroundColor = isHighlighted ? KeyboardPalette.toolbarPressed : .clear
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        isHighlighted = false
    }
}

/// S1-mini on or off. A tap anywhere on the row flips the switch; the row takes every touch,
/// the switch's included, so a drag that starts on the switch scrolls the panel like any
/// other row (the thumb no longer slides). The switch carries the row's accessibility and
/// still answers VoiceOver itself.
private final class FormattingRow: UIControl {
    let toggle = UISwitch()
    var onChange: ((Bool) -> Void)?

    init(isOn: Bool) {
        super.init(frame: .zero)
        let nameLabel = UILabel()
        // The model's name, exactly as its license asks.
        nameLabel.text = "S1-mini"
        nameLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        nameLabel.textColor = .label
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let hintLabel = UILabel()
        hintLabel.text = "Clean up English text"
        hintLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .right
        hintLabel.lineBreakMode = .byTruncatingTail

        toggle.isOn = isOn
        toggle.addTarget(self, action: #selector(toggled), for: .valueChanged)
        toggle.accessibilityLabel = "S1-mini formatting"
        toggle.accessibilityHint = "Cleans up English text."

        for view in [nameLabel, hintLabel, toggle] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameLabel.isAccessibilityElement = false
        hintLabel.isAccessibilityElement = false
        let inset = SpeechModelPanel.textInset
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SpeechModelPanel.rowHeight),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -10),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 12),
            hintLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
        ])
        addTarget(self, action: #selector(rowTapped), for: .touchUpInside)
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

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        isHighlighted = false
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
