import QuartzCore
import UIKit

/// Colors shared by the keys and the Dictate pill. Dynamic, so light and dark appearance
/// resolve on their own and no view has to watch trait changes.
enum KeyboardPalette {
    private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    static let characterKey = dynamic(light: .white, dark: UIColor(white: 0.36, alpha: 1))
    static let characterKeyPressed = dynamic(light: UIColor(white: 0.82, alpha: 1), dark: UIColor(white: 0.28, alpha: 1))
    static let specialKey = dynamic(
        light: UIColor(red: 0.674, green: 0.705, blue: 0.748, alpha: 1), dark: UIColor(white: 0.18, alpha: 1)
    )
    /// Like the system keyboard, a pressed special key lights up to a character key's color.
    static let specialKeyPressed = characterKey
    static let toolbarPressed = dynamic(light: UIColor(white: 0, alpha: 0.08), dark: UIColor(white: 1, alpha: 0.12))
    /// Shift while on or locked.
    static let engagedKey = dynamic(light: .white, dark: UIColor(white: 0.92, alpha: 1))

    /// Idle Dictate: a light red tint, opaque so its label keeps its contrast on any backdrop.
    static let dictateIdleFill = dynamic(
        light: UIColor(red: 1, green: 0.90, blue: 0.89, alpha: 1),
        dark: UIColor(red: 0.33, green: 0.13, blue: 0.13, alpha: 1)
    )
    static let dictateIdleForeground = dynamic(
        light: UIColor(red: 0.80, green: 0.12, blue: 0.10, alpha: 1),
        dark: UIColor(red: 1, green: 0.62, blue: 0.60, alpha: 1)
    )
    static let dictateRecordingFill = UIColor.systemRed
    static let brandOrange = UIColor(red: 1, green: 140 / 255, blue: 60 / 255, alpha: 1)
}

/// Motion values for the keyboard. Keys typed hundreds of times a day never animate; the
/// Dictate pill, used tens of times a day, gets short, interruptible motion.
enum KeyboardMotion {
    static let springDuration: TimeInterval = 0.3
    static let pressScale: CGFloat = 0.96
    /// Swapped glyphs shrink to this, never to 0.
    static let swapScale: CGFloat = 0.25
    static let colorDuration: TimeInterval = 0.15

    static func spring(_ animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        UIView.animate(
            springDuration: springDuration, bounce: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: animations, completion: completion
        )
    }

    /// Strong ease-out (0.23, 1, 0.32, 1); never ease-in.
    static func colorAnimator(_ animations: @escaping () -> Void) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(
            duration: colorDuration,
            controlPoint1: CGPoint(x: 0.23, y: 1), controlPoint2: CGPoint(x: 0.32, y: 1),
            animations: animations
        )
    }
}

// MARK: - DictatePill

/// The keyboard's main control: one large capsule that starts and stops a Dictation turn.
/// Every mode has a static cue (fill color, glyph, label) and motion only on top of it.
final class DictatePill: UIControl {
    enum Mode: Equatable {
        case idle
        /// `liveLevel`: the keyboard hears the audio itself (In-keyboard path), so the bars
        /// follow it; otherwise (Warm or Cold path) they breathe calmly.
        case recording(liveLevel: Bool)
        case processing
        /// A transcript was just inserted.
        case done

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    static let height: CGFloat = 44

    private(set) var mode: Mode = .idle
    private let fill = UIView()
    private let meter = LevelMeterView()
    private let timerLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var idleGroup: PillGroup!
    private var recordingGroup: PillGroup!
    private var processingGroup: PillGroup!
    private var doneGroup: PillGroup!
    private var groups: [PillGroup] { [idleGroup, recordingGroup, processingGroup, doneGroup] }
    private var colorAnimator: UIViewPropertyAnimator?
    private var recordingStartedAt: Date?
    private var clock: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.isUserInteractionEnabled = false
        fill.backgroundColor = KeyboardPalette.dictateIdleFill
        fill.layer.cornerRadius = Self.height / 2
        fill.layer.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        pinEdges(fill, to: self)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)

        let titleFont = UIFont.systemFont(ofSize: 17, weight: .semibold)

        idleGroup = PillGroup(
            glyph: Self.glyph("mic.fill", font: titleFont, color: KeyboardPalette.dictateIdleForeground,
                              nudge: CGVector(dx: 0, dy: -0.5)),
            rest: [Self.label("Dictate", font: titleFont, color: KeyboardPalette.dictateIdleForeground)]
        )

        timerLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        timerLabel.textColor = .white
        timerLabel.text = "0:00"
        meter.tintColor = .white
        recordingGroup = PillGroup(
            glyph: Self.glyph("stop.fill", font: UIFont.systemFont(ofSize: 14, weight: .bold), color: .white,
                              nudge: .zero),
            rest: [meter, timerLabel],
            spacing: 10
        )

        spinner.color = .white
        spinner.hidesWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let spinnerSlot = UIView()
        spinnerSlot.translatesAutoresizingMaskIntoConstraints = false
        spinnerSlot.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinnerSlot.widthAnchor.constraint(equalToConstant: 22),
            spinnerSlot.heightAnchor.constraint(equalToConstant: 22),
            spinner.centerXAnchor.constraint(equalTo: spinnerSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: spinnerSlot.centerYAnchor),
        ])
        spinner.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        processingGroup = PillGroup(
            glyph: spinnerSlot,
            rest: [Self.label("Transcribing\u{2026}", font: titleFont, color: .white)]
        )

        doneGroup = PillGroup(
            glyph: Self.glyph("checkmark", font: UIFont.systemFont(ofSize: 16, weight: .bold),
                              color: KeyboardPalette.dictateIdleForeground, nudge: CGVector(dx: 0, dy: 0.5)),
            rest: [Self.label("Inserted", font: titleFont, color: KeyboardPalette.dictateIdleForeground)]
        )

        for group in groups {
            addSubview(group)
            NSLayoutConstraint.activate([
                group.centerXAnchor.constraint(equalTo: centerXAnchor),
                group.centerYAnchor.constraint(equalTo: centerYAnchor),
                group.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                group.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            ])
            group.alpha = group === idleGroup ? 1 : 0
        }

        isAccessibilityElement = true
        updateAccessibility()

        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    // MARK: Mode

    func setMode(_ newMode: Mode, animated: Bool = true) {
        guard newMode != mode else { return }
        let wasRecording = mode.isRecording
        mode = newMode

        let target: PillGroup
        let fillColor: UIColor
        switch newMode {
        case .idle:
            target = idleGroup
            fillColor = KeyboardPalette.dictateIdleFill
        case .recording(let live):
            target = recordingGroup
            fillColor = KeyboardPalette.dictateRecordingFill
            if !wasRecording { startClock() }
            meter.start(live: live)
        case .processing:
            target = processingGroup
            fillColor = KeyboardPalette.brandOrange
            spinner.startAnimating()
        case .done:
            target = doneGroup
            fillColor = KeyboardPalette.dictateIdleFill
        }
        if !newMode.isRecording {
            stopClock()
            meter.stop()
        }
        // The pill takes no taps while transcribing, as before.
        isEnabled = newMode != .processing
        show(target, animated: animated)
        setFill(fillColor, animated: animated)
        updateAccessibility()
    }

    /// Linear RMS of the latest buffer, 0...1. Only drawn on the In-keyboard path.
    func setInputLevel(_ rms: Float) {
        meter.push(rms: rms)
    }

    // MARK: Press feedback

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if UIAccessibility.isReduceMotionEnabled {
                transform = .identity
                fill.alpha = isHighlighted ? 0.82 : 1
                return
            }
            fill.alpha = 1
            KeyboardMotion.spring {
                self.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: KeyboardMotion.pressScale, y: KeyboardMotion.pressScale)
                    : .identity
            }
        }
    }

    // MARK: Transitions

    /// Cross-fades to `group`: both glyphs stay in the tree, the outgoing one shrinks to
    /// `swapScale` and fades, the incoming one grows from it. Reduce Motion keeps the fade only.
    private func show(_ group: PillGroup, animated: Bool) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let shrunk = CGAffineTransform(scaleX: KeyboardMotion.swapScale, y: KeyboardMotion.swapScale)
        guard animated else {
            for each in groups {
                each.alpha = each === group ? 1 : 0
                each.glyph.transform = .identity
            }
            finishSwap()
            return
        }
        // Only a fully faded group starts small; one caught mid-fade continues from where it is.
        let visibleOpacity = group.layer.presentation()?.opacity ?? Float(group.alpha)
        if visibleOpacity < 0.01 {
            group.glyph.transform = reduceMotion ? .identity : shrunk
        }
        KeyboardMotion.spring({
            for each in self.groups {
                let isTarget = each === group
                each.alpha = isTarget ? 1 : 0
                each.glyph.transform = (isTarget || reduceMotion) ? .identity : shrunk
            }
        }, completion: { [weak self] _ in self?.finishSwap() })
    }

    private func finishSwap() {
        if mode != .processing { spinner.stopAnimating() }
    }

    private func setFill(_ color: UIColor, animated: Bool) {
        colorAnimator?.stopAnimation(true)
        colorAnimator = nil
        guard animated else {
            fill.backgroundColor = color
            return
        }
        let animator = KeyboardMotion.colorAnimator { self.fill.backgroundColor = color }
        animator.startAnimation()
        colorAnimator = animator
    }

    @objc private func reduceMotionChanged() {
        if case .recording(let live) = mode { meter.start(live: live) }
        if UIAccessibility.isReduceMotionEnabled { transform = .identity }
    }

    // MARK: Elapsed time

    private func startClock() {
        recordingStartedAt = Date()
        updateClock()
        clock?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
        recordingStartedAt = nil
    }

    private var elapsedSeconds: Int {
        guard let recordingStartedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
    }

    private func updateClock() {
        let seconds = elapsedSeconds
        let text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        if timerLabel.text != text { timerLabel.text = text }
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        switch mode {
        case .idle:
            accessibilityLabel = "Dictate"
            accessibilityTraits = .button
        case .recording:
            accessibilityLabel = "Stop dictation"
            accessibilityTraits = [.button, .updatesFrequently]
        case .processing:
            accessibilityLabel = "Transcribing"
            accessibilityTraits = [.button, .notEnabled]
        case .done:
            accessibilityLabel = "Dictate"
            accessibilityTraits = .button
        }
    }

    override var accessibilityValue: String? {
        get {
            switch mode {
            case .recording: return "Recording, \(elapsedSeconds) seconds"
            case .done: return "Inserted"
            default: return nil
            }
        }
        set {}
    }

    // MARK: Builders

    private static func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        return label
    }

    /// A 22 pt slot with the symbol nudged by `nudge` so it reads centered beside the label.
    private static func glyph(_ name: String, font: UIFont, color: UIColor, nudge: CGVector) -> UIView {
        let slot = UIView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        let image = UIImageView(image: UIImage(
            systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: font)
        ))
        image.tintColor = color
        image.contentMode = .center
        image.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(image)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: 22),
            slot.heightAnchor.constraint(equalToConstant: 22),
            image.centerXAnchor.constraint(equalTo: slot.centerXAnchor, constant: nudge.dx),
            image.centerYAnchor.constraint(equalTo: slot.centerYAnchor, constant: nudge.dy),
        ])
        return slot
    }
}

/// One mode's content: a glyph that scales on swaps, then labels or the meter.
private final class PillGroup: UIStackView {
    let glyph: UIView

    init(glyph: UIView, rest: [UIView], spacing: CGFloat = 8) {
        self.glyph = glyph
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        self.spacing = spacing
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(glyph)
        rest.forEach(addArrangedSubview)
    }

    required init(coder: NSCoder) { fatalError() }
}

// MARK: - LevelMeterView

/// Five rounded bars. Live: driven by the capture's RMS, smoothed per frame on a display link
/// that runs only while recording. Without a live level the bars breathe slowly, which says
/// "listening" without pretending to show speech. Reduce Motion: static bars.
final class LevelMeterView: UIView {
    private static let barCount = 5
    private static let barWidth: CGFloat = 3.5
    private static let barHeight: CGFloat = 20
    private static let barSpacing: CGFloat = 3.5
    private static let restScale: CGFloat = 0.2
    /// Center bar tallest, so the meter reads as one shape.
    private static let weights: [CGFloat] = [0.55, 0.8, 1, 0.8, 0.55]
    /// Outer bars show the level a few frames later than the center: a ripple of real data.
    private static let delayFrames = [6, 3, 0, 3, 6]

    private var bars: [UIView] = []
    private var link: CADisplayLink?
    private var live = false
    private var isRunning = false
    private var target: CGFloat = 0
    private var smoothed: CGFloat = 0
    private var history = [CGFloat](repeating: 0, count: 8)
    private var historyIndex = 0
    private var startTime: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        for index in 0..<Self.barCount {
            let bar = UIView()
            bar.backgroundColor = tintColor
            bar.layer.cornerRadius = Self.barWidth / 2
            bar.layer.cornerCurve = .continuous
            bar.frame = CGRect(
                x: CGFloat(index) * (Self.barWidth + Self.barSpacing), y: 0,
                width: Self.barWidth, height: Self.barHeight
            )
            addSubview(bar)
            bars.append(bar)
        }
        setScales(Array(repeating: Self.restScale, count: Self.barCount))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(Self.barCount)
        return CGSize(width: count * Self.barWidth + (count - 1) * Self.barSpacing, height: Self.barHeight)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        bars.forEach { $0.backgroundColor = tintColor }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopLink()
        } else if isRunning {
            start(live: live)
        }
    }

    func start(live: Bool) {
        self.live = live
        isRunning = true
        if UIAccessibility.isReduceMotionEnabled {
            stopLink()
            setScales(live ? Self.weights.map { 0.25 + 0.4 * $0 } : Array(repeating: 0.35, count: Self.barCount))
            return
        }
        guard link == nil, window != nil else { return }
        startTime = CACurrentMediaTime()
        lastTimestamp = 0
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        isRunning = false
        stopLink()
        target = 0
        smoothed = 0
        history = history.map { _ in 0 }
        setScales(Array(repeating: Self.restScale, count: Self.barCount))
    }

    func push(rms: Float) {
        guard live else { return }
        // -50 dBFS (room) to -10 dBFS (close, loud speech) fills the meter.
        let db = 20 * log10(max(Double(rms), 0.000_01))
        target = CGFloat(min(1, max(0, (db + 50) / 40)))
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(0.1, now - lastTimestamp)
        lastTimestamp = now
        if live {
            // Fast attack, slower release, frame-rate independent.
            let perFrame: CGFloat = target > smoothed ? 0.45 : 0.12
            let k = 1 - pow(1 - perFrame, CGFloat(dt * 60))
            smoothed += (target - smoothed) * k
            history[historyIndex] = smoothed
            let current = historyIndex
            historyIndex = (historyIndex + 1) % history.count
            setScales((0..<Self.barCount).map { index in
                let delayed = history[(current - Self.delayFrames[index] + history.count) % history.count]
                return Self.restScale + (1 - Self.restScale) * Self.weights[index] * delayed
            })
        } else {
            let t = now - startTime
            setScales((0..<Self.barCount).map { index in
                let wave = 0.5 + 0.5 * sin(2 * Double.pi * t / 2.4 - Double(index) * 0.5)
                return 0.28 + 0.12 * CGFloat(wave)
            })
        }
    }

    private func setScales(_ scales: [CGFloat]) {
        for (bar, scale) in zip(bars, scales) {
            bar.transform = CGAffineTransform(scaleX: 1, y: scale)
        }
    }
}

/// CADisplayLink retains its target; this breaks the cycle with the meter.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var meter: LevelMeterView?

    init(_ meter: LevelMeterView) {
        self.meter = meter
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let meter else {
            link.invalidate()
            return
        }
        meter.step(link)
    }
}

func pinEdges(_ child: UIView, to parent: UIView, insets: UIEdgeInsets = .zero) {
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
    ])
}
