import UIKit
import UIKit.UIGestureRecognizerSubclass
import AVFoundation
import SwiftUI

/// 顯示遠端畫面並把觸控 / 觸控板 / 實體鍵盤轉成 Mac 的輸入事件
///
/// 直接觸控模式：像在 iPad 上操作網頁；點一下 = 左鍵，兩指點 = 右鍵，長按後拖移 = 拖曳，單指或兩指滑動 = 捲動手指底下的內容（放手後帶慣性）
/// 觸控板模式：手指相對移動游標（像 MacBook 觸控板）
/// 實體滑鼠 / 巧控板：游標跟著 iPad 指標，左鍵 / 右鍵 / 中鍵按下與放開即時送出，可按住拖曳、雙擊、⌘ 點按
final class RemoteCanvasView: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    var send: (ClientMessage) -> Void = { _ in }
    var trackpadMode = false
    var videoSize: CGSize = .zero
    /// 工具列上暫時按住的修飾鍵（⌘⌥⌃⇧），點擊後自動放開
    var stickyModifiers: Modifiers = []
    var consumeStickyModifiers: () -> Void = {}

    private let displayLayer: AVSampleBufferDisplayLayer
    private var lastTap: (time: TimeInterval, point: CGPoint, count: Int)?
    private var lastPan: CGPoint = .zero
    private var lastScroll: CGPoint = .zero
    /// 不足 1 像素的捲動量先累積，避免慢慢滑時被四捨五入吃掉
    private var scrollRemainder: CGPoint = .zero
    private var inertiaLink: CADisplayLink?
    private var inertiaVelocity: CGPoint = .zero
    private let scrollGain: CGFloat = 2
    private let trackpadSensitivity: CGFloat = 1.6
    private var lastTouchIsPointer = false

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(displayLayer)
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityIdentifier = "remoteCanvas"
        accessibilityLabel = "遠端畫面"
        accessibilityTraits = .allowsDirectInteraction
        focusEffect = nil   // 拿到鍵盤焦點時不要畫藍框
        setupGestures()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }


    // MARK: 座標換算

    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let rect = videoRect
        return CGPoint(x: min(max((point.x - rect.minX) / rect.width, 0), 1),
                       y: min(max((point.y - rect.minY) / rect.height, 0), 1))
    }

    private func moveAbsolute(to point: CGPoint) {
        let n = normalized(point)
        send(.mouseMove(x: n.x, y: n.y))
    }

    private func moveRelative(by delta: CGPoint) {
        let rect = videoRect
        send(.mouseMoveRelative(dx: delta.x / rect.width * trackpadSensitivity,
                                dy: delta.y / rect.height * trackpadSensitivity))
    }

    private func takeModifiers() -> Modifiers {
        let m = stickyModifiers
        if !m.isEmpty { consumeStickyModifiers() }
        return m
    }

    // MARK: 手勢

    private func setupGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = direct + [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleRightClick))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = direct
        addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 12
        longPress.allowedTouchTypes = direct
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = direct
        pan.require(toFail: longPress)
        addGestureRecognizer(pan)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedTouchTypes = direct
        addGestureRecognizer(scroll)

        // 巧控鍵盤 / 滑鼠的兩指捲動
        let pointerScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        pointerScroll.allowedScrollTypesMask = .all
        pointerScroll.allowedTouchTypes = []
        addGestureRecognizer(pointerScroll)

        // 實體滑鼠 / 巧控板按鍵：按下、拖曳、放開都即時轉送
        let mouseButtons = PointerButtonRecognizer(target: self, action: #selector(handleMouseButton))
        mouseButtons.allowedTouchTypes = pointer
        addGestureRecognizer(mouseButtons)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        addGestureRecognizer(hover)

        gestureRecognizers?.forEach {
            $0.delegate = self
            // 手勢只處理觸控；實體鍵盤的空白鍵 / Return（.select 按壓）留給鍵盤處理
            $0.allowedPressTypes = []
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // 慣性捲動中點一下 = 停住（像 iOS），不送出點擊
        if inertiaLink != nil { stopInertia(); return }
        becomeFirstResponder()   // 點遠端畫面 = 結束輸入框，鍵盤回到 Mac
        reclaimKeyboardIfNeeded()
        let point = gesture.location(in: self)
        let now = CACurrentMediaTime()
        var count = 1
        if let last = lastTap, now - last.time < 0.4, hypot(point.x - last.point.x, point.y - last.point.y) < 30 {
            count = min(last.count + 1, 3)
        }
        lastTap = (now, point, count)
        if !trackpadMode || lastTouchIsPointer {
            moveAbsolute(to: point)
        }
        send(.click(button: .left, clickCount: count, modifiers: takeModifiers()))
    }

    @objc private func handleRightClick(_ gesture: UITapGestureRecognizer) {
        if !trackpadMode || lastTouchIsPointer {
            moveAbsolute(to: gesture.location(in: self))
        }
        send(.click(button: .right, clickCount: 1, modifiers: takeModifiers()))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // 直接觸控：單指滑動 = 捲動（像 iPad 上滑網頁）；觸控板模式：移動游標
        guard trackpadMode else { handleScroll(gesture); return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            lastPan = point
        case .changed:
            moveRelative(by: CGPoint(x: point.x - lastPan.x, y: point.y - lastPan.y))
            lastPan = point
        default:
            break
        }
    }

    @objc private func handleDrag(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            stopInertia()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            lastPan = point
            if !trackpadMode { moveAbsolute(to: point) }
            send(.mouseButton(button: .left, down: true, clickCount: 1, modifiers: takeModifiers()))
        case .changed:
            if trackpadMode {
                moveRelative(by: CGPoint(x: point.x - lastPan.x, y: point.y - lastPan.y))
            } else {
                moveAbsolute(to: point)
            }
            lastPan = point
        case .ended, .cancelled, .failed:
            send(.mouseButton(button: .left, down: false, clickCount: 1, modifiers: []))
        default:
            break
        }
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            stopInertia()
            lastScroll = translation
            scrollRemainder = .zero
            // 觸控螢幕捲動：先把游標移到手指位置，Mac 才會捲動手指底下的視窗（觸控板捲動則留在原位）
            if gesture.numberOfTouches > 0, !trackpadMode || lastTouchIsPointer {
                moveAbsolute(to: gesture.location(in: self))
            }
        case .changed:
            let dx = translation.x - lastScroll.x
            let dy = translation.y - lastScroll.y
            lastScroll = translation
            sendScroll(dx: dx * scrollGain, dy: dy * scrollGain)
        case .ended:
            // 觸控滑動放手後延續慣性（巧控板的捲動由系統自己處理慣性）
            if !gesture.allowedTouchTypes.isEmpty {
                startInertia(velocity: gesture.velocity(in: self))
            }
        default:
            break
        }
    }

    private func sendScroll(dx: CGFloat, dy: CGFloat) {
        let x = scrollRemainder.x + dx, y = scrollRemainder.y + dy
        let sx = x.rounded(.towardZero), sy = y.rounded(.towardZero)
        scrollRemainder = CGPoint(x: x - sx, y: y - sy)
        if sx != 0 || sy != 0 { send(.scroll(dx: sx, dy: sy)) }
    }

    private func startInertia(velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 150 else { return }
        inertiaVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(stepInertia))
        link.add(to: .main, forMode: .common)
        inertiaLink = link
    }

    @objc private func stepInertia(_ link: CADisplayLink) {
        let dt = CGFloat(max(link.targetTimestamp - link.timestamp, 1.0 / 120))
        sendScroll(dx: inertiaVelocity.x * dt * scrollGain, dy: inertiaVelocity.y * dt * scrollGain)
        let decay = pow(0.95, dt * 60)          // 約 0.95／幀（60Hz），與 iOS 一般捲動手感接近
        inertiaVelocity = CGPoint(x: inertiaVelocity.x * decay, y: inertiaVelocity.y * decay)
        if hypot(inertiaVelocity.x, inertiaVelocity.y) < 20 { stopInertia() }
    }

    private func stopInertia() {
        inertiaLink?.invalidate()
        inertiaLink = nil
        inertiaVelocity = .zero
    }

    private var lastMouseDown: (time: TimeInterval, point: CGPoint, button: MouseButton, count: Int)?
    private var mouseClickCount = 1

    @objc private func handleMouseButton(_ gesture: PointerButtonRecognizer) {
        let point = gesture.location(in: self)
        let button = gesture.button
        switch gesture.state {
        case .began:
            becomeFirstResponder()
            reclaimKeyboardIfNeeded()
            let now = CACurrentMediaTime()
            var count = 1
            if let last = lastMouseDown, last.button == button, now - last.time < 0.45,
               hypot(point.x - last.point.x, point.y - last.point.y) < 8 {
                count = min(last.count + 1, 3)
            }
            lastMouseDown = (now, point, button, count)
            mouseClickCount = count
            moveAbsolute(to: point)
            let modifiers = takeModifiers().union(KeyMap.modifiers(from: gesture.modifierFlags))
            send(.mouseButton(button: button, down: true, clickCount: count, modifiers: modifiers))
        case .changed:
            moveAbsolute(to: point)
        case .ended, .cancelled, .failed:
            moveAbsolute(to: point)
            send(.mouseButton(button: button, down: false, clickCount: mouseClickCount,
                              modifiers: KeyMap.modifiers(from: gesture.modifierFlags)))
        default:
            break
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        if gesture.state == .changed || gesture.state == .began {
            moveAbsolute(to: gesture.location(in: self))
        }
    }

    /// 巧控鍵盤 / 滑鼠的點擊一律用絕對位置（游標就在指標所在處）
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        lastTouchIsPointer = touch.type == .indirectPointer
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    // MARK: 隱藏 iPad 游標（遠端畫面裡已經有 Mac 游標）

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    // MARK: 實體鍵盤

    override var canBecomeFirstResponder: Bool { true }

    /// 關掉輸入框後把實體鍵盤拿回來，不必再點一下畫面才能打字
    func reclaimKeyboardIfNeeded() {
        guard let window else { return }
        // 若別的文字輸入元件（例如輸入框）正在使用鍵盤，不要搶
        if let responder = window.firstResponder, responder !== self, responder is UITextInput { return }
        let focusSystem = UIFocusSystem.focusSystem(for: window)
        let hasFocus = focusSystem == nil || focusSystem?.focusedItem === self
        if isFirstResponder && hasFocus { return }
        // iPadOS 接上實體鍵盤時，按鍵會送給「鍵盤焦點」所在的元件，而不只是 first responder。
        // 重新成為 first responder 會讓焦點系統把焦點移到這個可聚焦的視圖上。
        if isFirstResponder { resignFirstResponder() }
        becomeFirstResponder()
    }

    /// 輸入框沒在用時，遠端畫面要能拿到鍵盤焦點（實體鍵盤的按鍵才會送進來）；
    /// 輸入框在用時放掉，否則空白鍵會被焦點系統攔截，注音打不出一聲。
    var keyboardFocusEnabled = true {
        didSet {
            guard oldValue != keyboardFocusEnabled else { return }
            if !keyboardFocusEnabled { setNeedsFocusUpdate() }
        }
    }

    override var canBecomeFocused: Bool { keyboardFocusEnabled }

    /// 空白鍵、Return、Tab、Esc、方向鍵在 iPadOS 也是鍵盤焦點系統的「選取 / 移動焦點」鍵，
    /// 會在 pressesBegan 之前被系統吃掉（畫面四周出現藍框，Mac 收不到）。
    /// 用優先於系統行為的快捷鍵把它們攔下來，直接送給 Mac。
    override var keyCommands: [UIKeyCommand]? { Self.systemKeyCommands }

    private static let systemKeys: [(input: String, code: UInt16)] = [
        (" ", MacKey.space), ("\r", MacKey.returnKey), ("\t", MacKey.tab),
        (UIKeyCommand.inputEscape, MacKey.escape),
        (UIKeyCommand.inputUpArrow, MacKey.up), (UIKeyCommand.inputDownArrow, MacKey.down),
        (UIKeyCommand.inputLeftArrow, MacKey.left), (UIKeyCommand.inputRightArrow, MacKey.right),
    ]

    private static let systemKeyCommands: [UIKeyCommand] = {
        let modifiers: [UIKeyModifierFlags] = [.shift, .control, .alternate, .command]
        // 所有修飾鍵組合（例如 ⌃空白鍵切換輸入法、⇧方向鍵選取文字）
        let combos: [UIKeyModifierFlags] = (0..<(1 << modifiers.count)).map { mask in
            modifiers.enumerated().reduce(into: UIKeyModifierFlags()) { result, item in
                if mask & (1 << item.offset) != 0 { result.insert(item.element) }
            }
        }
        return systemKeys.flatMap { key in
            combos.map { flags in
                let command = UIKeyCommand(input: key.input, modifierFlags: flags,
                                           action: #selector(handleSystemKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
    }()

    @objc private func handleSystemKey(_ command: UIKeyCommand) {
        guard let input = command.input,
              let code = Self.systemKeys.first(where: { $0.input == input })?.code else { return }
        send(.keyPress(keyCode: code, modifiers: KeyMap.modifiers(from: command.modifierFlags).union(takeModifiers())))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let code = KeyMap.macKeyCode(for: key.keyCode) else { continue }
            send(.key(keyCode: code, down: true, modifiers: KeyMap.modifiers(from: key.modifierFlags)))
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let code = KeyMap.macKeyCode(for: key.keyCode) else { continue }
            send(.key(keyCode: code, down: false, modifiers: KeyMap.modifiers(from: key.modifierFlags)))
            handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}

/// 實體滑鼠按鍵：按下就開始（不像點按手勢要等放開），記錄是哪一顆鍵（修飾鍵用內建的 modifierFlags）
final class PointerButtonRecognizer: UIGestureRecognizer {
    private(set) var button: MouseButton = .left

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { return }
        let mask = event.buttonMask
        if mask.contains(.secondary) {
            button = .right
        } else if mask.contains(.button(3)) {
            button = .middle
        } else {
            button = .left
        }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}

/// SwiftUI 包裝
struct RemoteScreen: UIViewRepresentable {
    @ObservedObject var client: RemoteClient
    var trackpadMode: Bool
    @Binding var stickyModifiers: Modifiers
    /// 輸入框是否正在使用；沒有時實體鍵盤要回到遠端畫面，才能直接打字到 Mac
    var textInputActive = false

    func makeUIView(context: Context) -> RemoteCanvasView {
        let view = RemoteCanvasView(displayLayer: client.renderer.displayLayer)
        view.send = { [weak client] in client?.send($0) }
        return view
    }

    func updateUIView(_ view: RemoteCanvasView, context: Context) {
        view.trackpadMode = trackpadMode
        view.videoSize = client.videoSize
        view.stickyModifiers = stickyModifiers
        view.consumeStickyModifiers = { stickyModifiers = [] }
        view.keyboardFocusEnabled = !textInputActive
        if !textInputActive {
            DispatchQueue.main.async { view.reclaimKeyboardIfNeeded() }
        }
    }
}

private extension UIView {
    /// 在這個視圖底下找出目前的 first responder
    var firstResponder: UIResponder? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.firstResponder { return responder }
        }
        return nil
    }
}
