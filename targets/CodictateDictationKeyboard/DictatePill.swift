import QuartzCore
import UIKit

/// Colors shared by the keys and the Dictate button. Dynamic, so light and dark appearance
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

    /// Idle Dictate is a key like the letters: same fill, same shadow, a quiet glyph.
    static let dictateIdleFill = characterKey
    static let dictateIdleGlyph = UIColor.label
    static let dictateRecordingFill = UIColor.systemRed
    static let brandOrange = UIColor(red: 1, green: 140 / 255, blue: 60 / 255, alpha: 1)
}

/// Motion values for the keyboard. Keys typed hundreds of times a day never animate; the
/// Dictate button, used tens of times a day, gets short, interruptible motion.
enum KeyboardMotion {
    static let springDuration: TimeInterval = 0.3
    static let pressScale: CGFloat = 0.96
    /// Swapped glyphs shrink to this, never to 0.
    static let swapScale: CGFloat = 0.25
    static let colorDuration: TimeInterval = 0.15
    /// Error text in the strip: quick in, slightly slower out.
    static let textInDuration: TimeInterval = 0.15
    static let textOutDuration: TimeInterval = 0.2
    static let textOutOffset: CGFloat = 4

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

/// The Dictate button: a small capsule at the right of the strip above the keys. It carries
/// no text; each mode has a static cue (fill color and glyph) and motion only on top of it.
/// Idle is a key-colored capsule with a mic, recording is red with live level bars,
/// transcribing is orange with a spinner, and a delivered transcript shows a checkmark.
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

    static let size = CGSize(width: 60, height: 34)
    /// The capsule is smaller than a finger; touches this close still land on it.
    private static let minimumHitSize = CGSize(width: 72, height: 44)
    private static let glyphFont = UIFont.systemFont(ofSize: 15, weight: .semibold)

    private(set) var mode: Mode = .idle
    /// Parakeet's first-time load is running; shown only while idle.
    private(set) var isPreparing = false
    /// Spoken by VoiceOver while transcribing (the processing message), never drawn.
    var processingDetail: String?

    private let fill = UIView()
    private let meter = LevelMeterView()
    private let processingSpinner = UIActivityIndicatorView(style: .medium)
    private let preparingSpinner = UIActivityIndicatorView(style: .medium)
    private var idleContent: UIView!
    private var preparingContent: UIView!
    private var recordingContent: UIView!
    private var processingContent: UIView!
    private var doneContent: UIView!
    private var contents: [UIView] { [idleContent, preparingContent, recordingContent, processingContent, doneContent] }
    private var colorAnimator: UIViewPropertyAnimator?
    private var recordingStartedAt: Date?

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.isUserInteractionEnabled = false
        fill.backgroundColor = KeyboardPalette.dictateIdleFill
        fill.layer.cornerRadius = Self.size.height / 2
        fill.layer.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        pinEdges(fill, to: self)

        // The keys' shadow, so idle reads as one more key.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)

        // The mic's visual mass sits low (the stand); lift it half a point.
        idleContent = addContent(
            Self.glyph("mic.fill", color: KeyboardPalette.dictateIdleGlyph), nudge: CGVector(dx: 0, dy: -0.5)
        )

        preparingSpinner.color = .secondaryLabel
        preparingSpinner.hidesWhenStopped = false
        preparingSpinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        let dimmedMic = Self.glyph("mic.fill", color: KeyboardPalette.dictateIdleGlyph)
        dimmedMic.alpha = 0.4
        let preparing = UIStackView(arrangedSubviews: [dimmedMic, Self.slot(for: preparingSpinner, side: 12)])
        preparing.axis = .horizontal
        preparing.alignment = .center
        preparing.spacing = 3
        preparingContent = addContent(preparing, nudge: CGVector(dx: 0, dy: -0.5))

        meter.tintColor = .white
        recordingContent = addContent(meter, nudge: .zero)

        processingSpinner.color = .white
        processingSpinner.hidesWhenStopped = false
        processingSpinner.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        processingContent = addContent(Self.slot(for: processingSpinner, side: 15), nudge: .zero)

        // A checkmark's weight sits left of its box center; nudge it right.
        doneContent = addContent(
            Self.glyph("checkmark", color: KeyboardPalette.dictateIdleGlyph), nudge: CGVector(dx: 0.5, dy: 0)
        )

        idleContent.alpha = 1
        isAccessibilityElement = true
        updateAccessibility()

        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { Self.size }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (Self.minimumHitSize.width - bounds.width) / 2)
        let dy = max(0, (Self.minimumHitSize.height - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }

    // MARK: Mode

    func setMode(_ newMode: Mode, animated: Bool = true) {
        guard newMode != mode else { return }
        let wasRecording = mode.isRecording
        mode = newMode

        let fillColor: UIColor
        switch newMode {
        case .idle, .done:
            fillColor = KeyboardPalette.dictateIdleFill
        case .recording(let live):
            fillColor = KeyboardPalette.dictateRecordingFill
            if !wasRecording { recordingStartedAt = Date() }
            meter.start(live: live)
        case .processing:
            fillColor = KeyboardPalette.brandOrange
        }
        if !newMode.isRecording {
            recordingStartedAt = nil
            meter.stop()
        }
        // The button takes no taps while transcribing, as before.
        isEnabled = newMode != .processing
        show(currentContent, animated: animated)
        setFill(fillColor, animated: animated)
        updateAccessibility()
    }

    func setPreparing(_ preparing: Bool, animated: Bool = true) {
        guard preparing != isPreparing else { return }
        isPreparing = preparing
        if mode == .idle { show(currentContent, animated: animated) }
        updateAccessibility()
    }

    /// Linear RMS of the latest buffer, 0...1. Only drawn on the In-keyboard path.
    func setInputLevels(_ levels: [Float]) {
        meter.push(levels: levels)
    }

    private var currentContent: UIView {
        switch mode {
        case .idle: return isPreparing ? preparingContent : idleContent
        case .recording: return recordingContent
        case .processing: return processingContent
        case .done: return doneContent
        }
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

    /// Cross-fades to `content`: the outgoing glyph shrinks to `swapScale` and fades, the
    /// incoming one grows from it. Reduce Motion keeps the fade only.
    private func show(_ content: UIView, animated: Bool) {
        if content === processingContent { processingSpinner.startAnimating() }
        if content === preparingContent { preparingSpinner.startAnimating() }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let shrunk = CGAffineTransform(scaleX: KeyboardMotion.swapScale, y: KeyboardMotion.swapScale)
        guard animated else {
            for each in contents {
                each.alpha = each === content ? 1 : 0
                each.transform = .identity
            }
            stopHiddenSpinners()
            return
        }
        // Only a fully faded glyph starts small; one caught mid-fade continues from where it is.
        let visibleOpacity = content.layer.presentation()?.opacity ?? Float(content.alpha)
        if visibleOpacity < 0.01 {
            content.transform = reduceMotion ? .identity : shrunk
        }
        KeyboardMotion.spring({
            for each in self.contents {
                let isTarget = each === content
                each.alpha = isTarget ? 1 : 0
                each.transform = (isTarget || reduceMotion) ? .identity : shrunk
            }
        }, completion: { [weak self] _ in self?.stopHiddenSpinners() })
    }

    private func stopHiddenSpinners() {
        let visible = currentContent
        if visible !== processingContent { processingSpinner.stopAnimating() }
        if visible !== preparingContent { preparingSpinner.stopAnimating() }
    }

    /// Interruptible: a new color starts from whatever is on screen, not from the last target.
    private func setFill(_ color: UIColor, animated: Bool) {
        let onScreen = fill.layer.presentation()?.backgroundColor
        colorAnimator?.stopAnimation(true)
        colorAnimator = nil
        guard animated else {
            fill.backgroundColor = color
            return
        }
        if let onScreen { fill.layer.backgroundColor = onScreen }
        let animator = KeyboardMotion.colorAnimator { self.fill.backgroundColor = color }
        animator.startAnimation()
        colorAnimator = animator
    }

    @objc private func reduceMotionChanged() {
        if case .recording(let live) = mode { meter.start(live: live) }
        if UIAccessibility.isReduceMotionEnabled { transform = .identity }
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        switch mode {
        case .idle, .done:
            accessibilityLabel = "Dictate"
            accessibilityTraits = .button
        case .recording:
            accessibilityLabel = "Stop dictation"
            accessibilityTraits = [.button, .updatesFrequently]
        case .processing:
            accessibilityLabel = "Transcribing"
            accessibilityTraits = [.button, .notEnabled]
        }
    }

    override var accessibilityValue: String? {
        get {
            switch mode {
            case .idle:
                return isPreparing ? "Getting ready" : nil
            case .recording:
                let seconds = recordingStartedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
                return "Recording, \(seconds) seconds"
            case .processing:
                return processingDetail
            case .done:
                return "Inserted"
            }
        }
        set {}
    }

    // MARK: Builders

    /// Centers `view` in the capsule, offset by `nudge` for optical centering. Hidden until shown.
    private func addContent(_ view: UIView, nudge: CGVector) -> UIView {
        view.isUserInteractionEnabled = false
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor, constant: nudge.dx),
            view.centerYAnchor.constraint(equalTo: centerYAnchor, constant: nudge.dy),
        ])
        return view
    }

    private static func glyph(_ name: String, color: UIColor) -> UIImageView {
        let image = UIImageView(image: UIImage(
            systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: glyphFont)
        ))
        image.tintColor = color
        image.contentMode = .center
        return image
    }

    /// A fixed square for a (scaled) spinner, so its layout size matches what is drawn.
    private static func slot(for spinner: UIActivityIndicatorView, side: CGFloat) -> UIView {
        let slot = UIView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(spinner)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: side),
            slot.heightAnchor.constraint(equalToConstant: side),
            spinner.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
        ])
        return slot
    }
}

// MARK: - LevelMeterView

/// Five rounded bars. Live: driven by the capture's RMS, smoothed per frame on a display link
/// that runs only while recording. Without a live level the bars breathe slowly, which says
/// "listening" without pretending to show speech. Reduce Motion: static bars.
/// Bars change height (not a y-scale), so their round caps stay round at every level.
final class LevelMeterView: UIView {
    private static let barCount = 5
    private static let barWidth: CGFloat = 2.5
    private static let barHeight: CGFloat = 18
    private static let barSpacing: CGFloat = 2.5
    private static let restScale: CGFloat = 0.2
    /// A slight center bias, so the meter still reads as one shape.
    private static let weights: [CGFloat] = [0.8, 0.92, 1, 0.92, 0.8]
    /// Speech without auto gain sits around -35 to -25 dBFS at arm's length; this range
    /// puts it in the upper half of the meter, and room noise near the floor.
    private static let floorDB: Double = -55
    private static let ceilingDB: Double = -20

    private var bars: [UIView] = []
    private var link: CADisplayLink?
    private var live = false
    private var isRunning = false
    /// Per bar: the latest slice level, mapped to 0...1, and its smoothed value on screen.
    private var targets = [CGFloat](repeating: 0, count: barCount)
    private var smoothed = [CGFloat](repeating: 0, count: barCount)
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
            bar.layer.cornerCurve = .circular
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight)
            bar.center = CGPoint(
                x: CGFloat(index) * (Self.barWidth + Self.barSpacing) + Self.barWidth / 2, y: Self.barHeight / 2
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
        targets = targets.map { _ in 0 }
        smoothed = smoothed.map { _ in 0 }
        setScales(Array(repeating: Self.restScale, count: Self.barCount))
    }

    /// One level per bar, in time order across the last buffer. A shorter array (an older
    /// page) spreads its values across the bars.
    func push(levels: [Float]) {
        guard live, !levels.isEmpty else { return }
        for index in 0..<Self.barCount {
            let rms = levels[index * levels.count / Self.barCount]
            let db = 20 * log10(max(Double(rms), 0.000_01))
            let linear = min(1, max(0, (db - Self.floorDB) / (Self.ceilingDB - Self.floorDB)))
            // A gentle curve lifts quiet speech so the bars move with normal talking.
            targets[index] = CGFloat(pow(linear, 0.75))
        }
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
            // Fast attack, quick release (so syllables read as separate beats),
            // frame-rate independent.
            for index in 0..<Self.barCount {
                let perFrame: CGFloat = targets[index] > smoothed[index] ? 0.5 : 0.22
                let k = 1 - pow(1 - perFrame, CGFloat(dt * 60))
                smoothed[index] += (targets[index] - smoothed[index]) * k
            }
            setScales((0..<Self.barCount).map { index in
                Self.restScale + (1 - Self.restScale) * Self.weights[index] * smoothed[index]
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
            bar.bounds.size.height = max(Self.barWidth, Self.barHeight * scale)
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
