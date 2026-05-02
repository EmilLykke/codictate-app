import UIKit

// MARK: - State

enum DictationViewState: Equatable {
    case idle
    case recording
    case processing
    case result(String)
    case error(String)
}

// MARK: - Delegate

protocol DictationKeyboardViewDelegate: AnyObject {
    func didTapDictate()
    func didInsertText(_ text: String)
    func didTapBackspace()
    func didTapDismiss()
}

// MARK: - GlassKey

private final class GlassKey: UIControl {

    let contentLabel = UILabel()
    let contentIcon  = UIImageView()

    private let blurView: UIVisualEffectView
    private let tintOverlay    = UIView()   // dark-mode brightness layer (inside blur)
    private let recordingLayer = UIView()   // vivid fill for recording state (above blur)
    private let isSpecial: Bool

    init(special: Bool = false) {
        self.isSpecial = special
        if #available(iOS 26.0, *) {
            blurView = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            let style: UIBlurEffect.Style = special ? .systemMaterial : .systemUltraThinMaterial
            blurView = UIVisualEffectView(effect: UIBlurEffect(style: style))
        }
        super.init(frame: .zero)

        // ── Blur background ──────────────────────────────────────────────
        blurView.isUserInteractionEnabled = false
        blurView.layer.cornerRadius = 9
        blurView.layer.cornerCurve  = .continuous
        blurView.clipsToBounds = true
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        // Dark-mode brightness overlay (sits inside the blur contentView)
        if #available(iOS 26.0, *) { } else {
            tintOverlay.isUserInteractionEnabled = false
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            blurView.contentView.addSubview(tintOverlay)
            pin(tintOverlay, to: blurView.contentView)
            updateTintForCurrentAppearance()
        }

        // ── Recording fill (red layer, above blur, below content) ────────
        recordingLayer.isUserInteractionEnabled = false
        recordingLayer.backgroundColor = UIColor(red: 0.93, green: 0.23, blue: 0.24, alpha: 1)
        recordingLayer.layer.cornerRadius = 9
        recordingLayer.layer.cornerCurve  = .continuous
        recordingLayer.clipsToBounds = true
        recordingLayer.alpha = 0
        recordingLayer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordingLayer)

        // ── Content (label / icon) — directly on GlassKey, above both layers ──
        contentLabel.textColor = .label
        contentLabel.textAlignment = .center
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentLabel)

        contentIcon.tintColor = .label
        contentIcon.contentMode = .scaleAspectFit
        contentIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentIcon)

        NSLayoutConstraint.activate([
            // blur fills key
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // recording fill covers same area
            recordingLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            recordingLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            recordingLayer.topAnchor.constraint(equalTo: topAnchor),
            recordingLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
            // content centered
            contentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentIcon.widthAnchor.constraint(equalToConstant: 18),
            contentIcon.heightAnchor.constraint(equalToConstant: 18),
        ])

        layer.shadowColor   = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius  = 0.5
        layer.shadowOffset  = CGSize(width: 0, height: 1)
    }

    // MARK: Appearance helpers

    private func updateTintForCurrentAppearance() {
        if traitCollection.userInterfaceStyle == .dark {
            tintOverlay.backgroundColor = UIColor.white.withAlphaComponent(isSpecial ? 0.04 : 0.15)
        } else {
            tintOverlay.backgroundColor = .clear
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        updateTintForCurrentAppearance()
    }

    /// Shows / hides the vivid red recording fill with a short crossfade.
    func setRecordingHighlight(_ on: Bool) {
        UIView.animate(withDuration: 0.18, delay: 0, options: .beginFromCurrentState) {
            self.recordingLayer.alpha = on ? 1 : 0
        }
    }

    // MARK: Configuration

    func setLetter(_ text: String) {
        contentLabel.text = text
        contentLabel.font = UIFont.systemFont(ofSize: 17, weight: .regular)
        contentLabel.isHidden = false
        contentIcon.isHidden  = true
    }

    func setSmallText(_ text: String, size: CGFloat = 15) {
        contentLabel.text = text
        contentLabel.font = UIFont.systemFont(ofSize: size, weight: .regular)
        contentLabel.isHidden = false
        contentIcon.isHidden  = true
    }

    func setIcon(_ name: String, size: CGFloat = 16) {
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        contentIcon.image     = UIImage(systemName: name, withConfiguration: cfg)
        contentIcon.isHidden  = false
        contentLabel.isHidden = true
    }

    // MARK: Press feedback

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.08, delay: 0, options: .beginFromCurrentState) {
                self.blurView.alpha = self.isHighlighted ? 0.5 : 1.0
            }
        }
    }

    // MARK: Private

    private func pin(_ child: UIView, to parent: UIView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - DictationKeyboardView

final class DictationKeyboardView: UIView {

    weak var delegate: DictationKeyboardViewDelegate?

    private static let row1 = Array("qwertyuiop").map(String.init)
    private static let row2 = Array("asdfghjkl").map(String.init)
    private static let row3 = Array("zxcvbnm").map(String.init)

    private var letterPairs: [(GlassKey, String)] = []
    private var shiftOn = false { didSet { updateLetterTitles() } }

    // Dictate key lives in row 4; state drives icon + red fill.
    private let dictateButton  = GlassKey(special: true)
    private let dismissButton  = GlassKey(special: true)

    private let impact = UIImpactFeedbackGenerator(style: .light)

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        build()
        impact.prepare()
        // Initial icon
        dictateButton.setIcon("mic.fill", size: 18)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 260)
    }

    // MARK: State

    func apply(state: DictationViewState) {
        switch state {
        case .idle, .result, .error:
            dictateButton.isEnabled = true
            dictateButton.alpha = 1
            setDictateActive(false)
        case .recording:
            dictateButton.isEnabled = true
            dictateButton.alpha = 1
            setDictateActive(true)
        case .processing:
            dictateButton.isEnabled = false
            dictateButton.alpha = 0.5
            setDictateActive(false)
        }
    }

    // MARK: Build

    private func build() {
        let strip = buildTopStrip()

        let keys = UIStackView()
        keys.axis = .vertical
        keys.spacing = 8
        keys.distribution = .fillEqually
        keys.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keys)

        keys.addArrangedSubview(letterRow(Self.row1, inset: 0))
        keys.addArrangedSubview(letterRow(Self.row2, inset: 16))
        keys.addArrangedSubview(buildRow3())
        keys.addArrangedSubview(buildRow4())

        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 38),

            keys.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 2),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            keys.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    private func buildTopStrip() -> UIView {
        let strip = UIView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)

        dismissButton.setIcon("keyboard.chevron.compact.down", size: 14)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        strip.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            dismissButton.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 8),
            dismissButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 40),
            dismissButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        return strip
    }

    // MARK: Row builders

    private func letterRow(_ letters: [String], inset: CGFloat) -> UIView {
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 5
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        for ch in letters {
            let k = GlassKey()
            k.setLetter(ch)
            k.addTarget(self, action: #selector(letterTapped(_:)), for: .touchUpInside)
            letterPairs.append((k, ch))
            stack.addArrangedSubview(k)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func buildRow3() -> UIView {
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let shift = GlassKey(special: true)
        shift.setIcon("shift", size: 16)
        shift.widthAnchor.constraint(equalToConstant: 42).isActive = true
        shift.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
        stack.addArrangedSubview(shift)

        let ls = UIStackView()
        ls.axis = .horizontal
        ls.spacing = 5
        ls.distribution = .fillEqually
        for ch in Self.row3 {
            let k = GlassKey()
            k.setLetter(ch)
            k.addTarget(self, action: #selector(letterTapped(_:)), for: .touchUpInside)
            letterPairs.append((k, ch))
            ls.addArrangedSubview(k)
        }
        stack.addArrangedSubview(ls)

        let del = GlassKey(special: true)
        del.setIcon("delete.left", size: 16)
        del.widthAnchor.constraint(equalToConstant: 42).isActive = true
        del.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
        stack.addArrangedSubview(del)

        pin(stack, in: container)
        return container
    }

    /// Bottom row: [123] [mic/stop] [   space   ] [return]
    private func buildRow4() -> UIView {
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let nums = GlassKey(special: true)
        nums.setSmallText("123")
        nums.widthAnchor.constraint(equalToConstant: 44).isActive = true
        nums.addTarget(self, action: #selector(numbersTapped), for: .touchUpInside)
        stack.addArrangedSubview(nums)

        // Dictate key — compact, same width as 123
        dictateButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        dictateButton.addTarget(self, action: #selector(dictateTapped), for: .touchUpInside)
        stack.addArrangedSubview(dictateButton)

        let space = GlassKey()
        space.setSmallText("space", size: 16)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        stack.addArrangedSubview(space)

        let ret = GlassKey(special: true)
        ret.setSmallText("return")
        ret.widthAnchor.constraint(equalToConstant: 86).isActive = true
        ret.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        stack.addArrangedSubview(ret)

        pin(stack, in: container)
        return container
    }

    // MARK: Dictate button appearance

    private func setDictateActive(_ on: Bool) {
        // Swap icon: mic when idle, filled square when recording.
        dictateButton.setIcon(on ? "stop.fill" : "mic.fill", size: 18)
        // White icon on red background when recording; adaptive label color when idle.
        dictateButton.contentIcon.tintColor = on ? .white : .label
        // Animate the red fill layer in/out.
        dictateButton.setRecordingHighlight(on)
    }

    // MARK: Letter title refresh

    private func updateLetterTitles() {
        for (key, base) in letterPairs {
            key.contentLabel.text = shiftOn ? base.uppercased() : base
        }
    }

    // MARK: Helpers

    private func pin(_ child: UIView, in parent: UIView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    // MARK: Actions

    @objc private func letterTapped(_ sender: GlassKey) {
        impact.impactOccurred()
        let text = sender.contentLabel.text ?? ""
        delegate?.didInsertText(text)
        shiftOn = false
    }

    @objc private func shiftTapped()     { impact.impactOccurred(); shiftOn.toggle() }
    @objc private func backspaceTapped() { impact.impactOccurred(); delegate?.didTapBackspace() }
    @objc private func dictateTapped()   { impact.impactOccurred(); delegate?.didTapDictate() }
    @objc private func dismissTapped()   { delegate?.didTapDismiss() }
    @objc private func numbersTapped()   { impact.impactOccurred() }
    @objc private func spaceTapped()     { impact.impactOccurred(); delegate?.didInsertText(" ") }
    @objc private func returnTapped()    { impact.impactOccurred(); delegate?.didInsertText("\n") }
}
