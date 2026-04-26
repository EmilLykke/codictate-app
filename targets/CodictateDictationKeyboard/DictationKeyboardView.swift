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
//
// A UIControl whose background is a UIVisualEffectView (UIGlassEffect on iOS 26+,
// UIBlurEffect on earlier). All content lives in the effect's contentView so
// vibrancy / glass tinting works correctly.

private final class GlassKey: UIControl {

    // Public content accessors for tint overrides (e.g. dictate button colour)
    let contentLabel = UILabel()
    let contentIcon  = UIImageView()

    private let blurView: UIVisualEffectView

    init(special: Bool = false) {
        if #available(iOS 26.0, *) {
            blurView = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            let style: UIBlurEffect.Style = special ? .systemMaterialDark : .systemUltraThinMaterialDark
            blurView = UIVisualEffectView(effect: UIBlurEffect(style: style))
        }
        super.init(frame: .zero)

        blurView.isUserInteractionEnabled = false
        blurView.layer.cornerRadius = 9
        blurView.layer.cornerCurve  = .continuous
        blurView.clipsToBounds = true
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        // On older iOS: add a white tint overlay so letter keys appear lighter than special keys
        if #available(iOS 26.0, *) { /* UIGlassEffect handles this */ } else {
            let tint = UIView()
            tint.backgroundColor = UIColor.white.withAlphaComponent(special ? 0.04 : 0.15)
            tint.isUserInteractionEnabled = false
            tint.translatesAutoresizingMaskIntoConstraints = false
            blurView.contentView.addSubview(tint)
            pin(tint, to: blurView.contentView)
        }

        contentLabel.textColor = .white
        contentLabel.textAlignment = .center
        contentLabel.translatesAutoresizingMaskIntoConstraints = false

        contentIcon.tintColor = .white
        contentIcon.contentMode = .scaleAspectFit
        contentIcon.translatesAutoresizingMaskIntoConstraints = false

        blurView.contentView.addSubview(contentLabel)
        blurView.contentView.addSubview(contentIcon)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentLabel.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            contentLabel.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),

            contentIcon.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            contentIcon.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
            contentIcon.widthAnchor.constraint(equalToConstant: 18),
            contentIcon.heightAnchor.constraint(equalToConstant: 18),
        ])

        // Subtle drop-shadow so keys lift off the glass background
        layer.shadowColor   = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius  = 0.5
        layer.shadowOffset  = CGSize(width: 0, height: 1)
    }

    // MARK: Configuration helpers

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
        contentIcon.image    = UIImage(systemName: name, withConfiguration: cfg)
        contentIcon.isHidden = false
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

    private let dictateButton = GlassKey(special: true)
    private let dismissButton = GlassKey(special: true)

    // Stack inside dictate button (mic + label side by side)
    private let dictateStack = UIStackView()
    private let dictateIcon  = UIImageView()
    private let dictateLabel = UILabel()

    private let impact = UIImpactFeedbackGenerator(style: .light)

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear   // Let UIInputView(.keyboard) glass material show through
        build()
        impact.prepare()
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
            setDictateActive(false)
        case .recording:
            dictateButton.isEnabled = true
            setDictateActive(true)
        case .processing:
            dictateButton.isEnabled = false
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

        // Dismiss button (bottom-left, standard iOS keyboard placement)
        dismissButton.setIcon("keyboard.chevron.compact.down", size: 14)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        strip.addSubview(dismissButton)

        // Dictate pill button (right side) — contains a horizontal stack: mic icon + "Dictate" text
        buildDictatePill(in: strip)

        NSLayoutConstraint.activate([
            dismissButton.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 8),
            dismissButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 40),
            dismissButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        return strip
    }

    private func buildDictatePill(in strip: UIView) {
        // mic icon
        let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        dictateIcon.image   = UIImage(systemName: "mic.fill", withConfiguration: cfg)
        dictateIcon.tintColor = UIColor(white: 0.9, alpha: 1)
        dictateIcon.contentMode = .scaleAspectFit
        dictateIcon.setContentHuggingPriority(.required, for: .horizontal)
        dictateIcon.translatesAutoresizingMaskIntoConstraints = false

        // label
        dictateLabel.text      = "Dictate"
        dictateLabel.font      = UIFont.systemFont(ofSize: 13, weight: .medium)
        dictateLabel.textColor = UIColor(white: 0.9, alpha: 1)
        dictateLabel.translatesAutoresizingMaskIntoConstraints = false

        dictateStack.axis      = .horizontal
        dictateStack.spacing   = 4
        dictateStack.alignment = .center
        dictateStack.isUserInteractionEnabled = false
        dictateStack.translatesAutoresizingMaskIntoConstraints = false
        dictateStack.addArrangedSubview(dictateIcon)
        dictateStack.addArrangedSubview(dictateLabel)

        // dictateButton has no built-in content — we embed the stack in its blur view
        dictateButton.contentLabel.isHidden = true
        dictateButton.contentIcon.isHidden  = true
        dictateButton.blurView(addingSubview: dictateStack) { stack, content in
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }

        dictateButton.translatesAutoresizingMaskIntoConstraints = false
        dictateButton.addTarget(self, action: #selector(dictateTapped), for: .touchUpInside)
        strip.addSubview(dictateButton)

        NSLayoutConstraint.activate([
            dictateButton.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -8),
            dictateButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            dictateButton.widthAnchor.constraint(equalToConstant: 92),
            dictateButton.heightAnchor.constraint(equalToConstant: 30),
        ])
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
        let color: UIColor = on
            ? UIColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 1)
            : UIColor(white: 0.9, alpha: 1)
        dictateIcon.tintColor  = color
        dictateLabel.textColor = color

        if on {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue   = 1.0
            anim.toValue     = 0.35
            anim.duration    = 0.75
            anim.autoreverses = true
            anim.repeatCount = .infinity
            dictateButton.layer.add(anim, forKey: "pulse")
        } else {
            dictateButton.layer.removeAllAnimations()
        }
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
        if text == "space" { delegate?.didInsertText(" "); return }
        delegate?.didInsertText(text)
        shiftOn = false
    }

    @objc private func shiftTapped()    { impact.impactOccurred(); shiftOn.toggle() }
    @objc private func backspaceTapped(){ impact.impactOccurred(); delegate?.didTapBackspace() }
    @objc private func dictateTapped()  { impact.impactOccurred(); delegate?.didTapDictate() }
    @objc private func dismissTapped()  { delegate?.didTapDismiss() }
    @objc private func numbersTapped()  { impact.impactOccurred() }
    @objc private func spaceTapped()    { impact.impactOccurred(); delegate?.didInsertText(" ") }
    @objc private func returnTapped()   { impact.impactOccurred(); delegate?.didInsertText("\n") }
}

// MARK: - GlassKey convenience: embed arbitrary content in its blur contentView

extension GlassKey {
    /// Adds `subview` into the visual effect's contentView and calls `constraints` to constrain it.
    func blurView(addingSubview subview: UIView, constraints: (UIView, UIView) -> Void) {
        // blurView is private — access via a known subview chain
        for sub in subviews {
            if let effectView = sub as? UIVisualEffectView {
                effectView.contentView.addSubview(subview)
                constraints(subview, effectView.contentView)
                return
            }
        }
    }
}
