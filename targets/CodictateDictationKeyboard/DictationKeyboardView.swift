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
    func didTapNextKeyboard()
}

// MARK: - KeyboardKey

private final class KeyboardKey: UIControl {

    let contentLabel = UILabel()
    let contentIcon  = UIImageView()

    private let backgroundLayer = UIView()
    private let recordingLayer = UIView()
    private let style: KeyStyle
    private var isSelectedKey = false

    enum KeyStyle {
        case letter
        case special
        case space
        case accent
    }

    init(style: KeyStyle = .letter) {
        self.style = style
        super.init(frame: .zero)

        backgroundLayer.isUserInteractionEnabled = false
        backgroundLayer.layer.cornerRadius = 6
        backgroundLayer.layer.cornerCurve = .continuous
        backgroundLayer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundLayer)

        recordingLayer.isUserInteractionEnabled = false
        recordingLayer.backgroundColor = UIColor.systemRed
        recordingLayer.layer.cornerRadius = 6
        recordingLayer.layer.cornerCurve = .continuous
        recordingLayer.clipsToBounds = true
        recordingLayer.alpha = 0
        recordingLayer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordingLayer)

        contentLabel.textColor = .label
        contentLabel.textAlignment = .center
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentLabel)

        contentIcon.tintColor = .label
        contentIcon.contentMode = .scaleAspectFit
        contentIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentIcon)

        NSLayoutConstraint.activate([
            backgroundLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundLayer.topAnchor.constraint(equalTo: topAnchor),
            backgroundLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
            recordingLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            recordingLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            recordingLayer.topAnchor.constraint(equalTo: topAnchor),
            recordingLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentIcon.widthAnchor.constraint(equalToConstant: 18),
            contentIcon.heightAnchor.constraint(equalToConstant: 18),
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        updateColors()
    }

    func setRecordingHighlight(_ on: Bool) {
        UIView.animate(withDuration: 0.18, delay: 0, options: .beginFromCurrentState) {
            self.recordingLayer.alpha = on ? 1 : 0
        }
    }

    // MARK: Configuration

    func setLetter(_ text: String) {
        contentLabel.text = text
        contentLabel.font = UIFont.systemFont(ofSize: 22, weight: .regular)
        contentLabel.isHidden = false
        contentIcon.isHidden = true
    }

    func setSmallText(_ text: String, size: CGFloat = 15) {
        contentLabel.text = text
        contentLabel.font = UIFont.systemFont(ofSize: size, weight: .regular)
        contentLabel.isHidden = false
        contentIcon.isHidden  = true
    }

    func setIcon(_ name: String, size: CGFloat = 16) {
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        contentIcon.image = UIImage(systemName: name, withConfiguration: cfg)
        contentIcon.isHidden = false
        contentLabel.isHidden = true
    }

    func setSelected(_ selected: Bool) {
        isSelectedKey = selected
        updateColors()
    }

    // MARK: Press feedback

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.08, delay: 0, options: .beginFromCurrentState) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
                self.backgroundLayer.backgroundColor = self.isHighlighted
                    ? self.highlightColor()
                    : self.currentColor()
            }
        }
    }

    // MARK: Private

    private func updateColors() {
        backgroundLayer.backgroundColor = currentColor()
        contentLabel.textColor = isSelectedKey ? systemBackgroundColor() : .label
        contentIcon.tintColor = isSelectedKey ? systemBackgroundColor() : .label
    }

    private func currentColor() -> UIColor {
        isSelectedKey ? .label : baseColor()
    }

    private func baseColor() -> UIColor {
        switch style {
        case .letter, .space:
            return traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.36, alpha: 1)
                : .white
        case .special:
            return traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.18, alpha: 1)
                : UIColor(red: 0.674, green: 0.705, blue: 0.748, alpha: 1)
        case .accent:
            return UIColor.systemRed.withAlphaComponent(0.18)
        }
    }

    private func highlightColor() -> UIColor {
        switch style {
        case .letter, .space:
            return traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.28, alpha: 1)
                : UIColor(white: 0.82, alpha: 1)
        case .special, .accent:
            return traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.25, alpha: 1)
                : UIColor(red: 0.56, green: 0.60, blue: 0.65, alpha: 1)
        }
    }

    private func systemBackgroundColor() -> UIColor {
        traitCollection.userInterfaceStyle == .dark ? .black : .white
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - DictationKeyboardView

final class DictationKeyboardView: UIView {

    weak var delegate: DictationKeyboardViewDelegate?

    private static let row1 = Array("qwertyuiop").map(String.init)
    private static let row2 = Array("asdfghjkl").map(String.init)
    private static let row3 = Array("zxcvbnm").map(String.init)

    private var letterPairs: [(KeyboardKey, String)] = []
    private var shiftButton: KeyboardKey?
    private var shiftOn = false {
        didSet {
            updateLetterTitles()
            shiftButton?.setSelected(shiftOn)
        }
    }

    private let dictateButton = KeyboardKey(style: .accent)
    private let dismissButton = KeyboardKey(style: .special)
    private let statusLabel = UILabel()

    private let impact = UIImpactFeedbackGenerator(style: .light)

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.812, green: 0.831, blue: 0.859, alpha: 1)
        build()
        impact.prepare()
        dictateButton.setIcon("mic.fill", size: 16)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 266)
    }

    // MARK: State

    func apply(state: DictationViewState) {
        switch state {
        case .idle, .result, .error:
            dictateButton.isEnabled = true
            dictateButton.alpha = 1
            setDictateActive(false)
            statusLabel.text = ""
        case .recording:
            dictateButton.isEnabled = true
            dictateButton.alpha = 1
            setDictateActive(true)
            statusLabel.text = "Recording"
        case .processing:
            dictateButton.isEnabled = false
            dictateButton.alpha = 0.65
            setDictateActive(false)
            dictateButton.setIcon("waveform", size: 16)
            statusLabel.text = "Transcribing"
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
            keys.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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

        statusLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(statusLabel)

        dictateButton.translatesAutoresizingMaskIntoConstraints = false
        dictateButton.addTarget(self, action: #selector(dictateTapped), for: .touchUpInside)
        strip.addSubview(dictateButton)

        NSLayoutConstraint.activate([
            dismissButton.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 8),
            dismissButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 40),
            dismissButton.heightAnchor.constraint(equalToConstant: 30),

            dictateButton.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -8),
            dictateButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            dictateButton.widthAnchor.constraint(equalToConstant: 40),
            dictateButton.heightAnchor.constraint(equalToConstant: 30),

            statusLabel.leadingAnchor.constraint(equalTo: dismissButton.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: dictateButton.leadingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
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
            let k = KeyboardKey()
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

        let shift = KeyboardKey(style: .special)
        shift.setIcon("shift", size: 16)
        shift.widthAnchor.constraint(equalToConstant: 44).isActive = true
        shift.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
        shiftButton = shift
        stack.addArrangedSubview(shift)

        let ls = UIStackView()
        ls.axis = .horizontal
        ls.spacing = 5
        ls.distribution = .fillEqually
        for ch in Self.row3 {
            let k = KeyboardKey()
            k.setLetter(ch)
            k.addTarget(self, action: #selector(letterTapped(_:)), for: .touchUpInside)
            letterPairs.append((k, ch))
            ls.addArrangedSubview(k)
        }
        stack.addArrangedSubview(ls)

        let del = KeyboardKey(style: .special)
        del.setIcon("delete.left", size: 16)
        del.widthAnchor.constraint(equalToConstant: 44).isActive = true
        del.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
        stack.addArrangedSubview(del)

        pin(stack, in: container)
        return container
    }

    /// Bottom row: [123] [globe] [space] [return]
    private func buildRow4() -> UIView {
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let nums = KeyboardKey(style: .special)
        nums.setSmallText("123")
        nums.widthAnchor.constraint(equalToConstant: 46).isActive = true
        nums.addTarget(self, action: #selector(numbersTapped), for: .touchUpInside)
        stack.addArrangedSubview(nums)

        let globe = KeyboardKey(style: .special)
        globe.setIcon("globe", size: 17)
        globe.widthAnchor.constraint(equalToConstant: 46).isActive = true
        globe.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)
        stack.addArrangedSubview(globe)

        let space = KeyboardKey(style: .space)
        space.setSmallText("space", size: 16)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        stack.addArrangedSubview(space)

        let ret = KeyboardKey(style: .special)
        ret.setSmallText("return")
        ret.widthAnchor.constraint(equalToConstant: 86).isActive = true
        ret.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        stack.addArrangedSubview(ret)

        pin(stack, in: container)
        return container
    }

    // MARK: Dictate button appearance

    private func setDictateActive(_ on: Bool) {
        dictateButton.setIcon(on ? "stop.fill" : "mic.fill", size: 18)
        dictateButton.contentIcon.tintColor = on ? .white : .label
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

    @objc private func letterTapped(_ sender: KeyboardKey) {
        impact.impactOccurred()
        let text = sender.contentLabel.text ?? ""
        delegate?.didInsertText(text)
        shiftOn = false
    }

    @objc private func shiftTapped()     { impact.impactOccurred(); shiftOn.toggle() }
    @objc private func backspaceTapped() { impact.impactOccurred(); delegate?.didTapBackspace() }
    @objc private func dictateTapped()   { impact.impactOccurred(); delegate?.didTapDictate() }
    @objc private func dismissTapped()   { delegate?.didTapDismiss() }
    @objc private func nextKeyboardTapped() { delegate?.didTapNextKeyboard() }
    @objc private func numbersTapped()   { impact.impactOccurred() }
    @objc private func spaceTapped()     { impact.impactOccurred(); delegate?.didInsertText(" ") }
    @objc private func returnTapped()    { impact.impactOccurred(); delegate?.didInsertText("\n") }
}
