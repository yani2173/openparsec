import Foundation
import UIKit
import ParsecSDK
import QuartzCore
import os

protocol ParsecPlayground {
	init(viewController: UIViewController, updateImage: @escaping () -> Void)
	var renderView: UIView { get }
	func viewDidLoad()
	func cleanUp()
	func updateSize(width: CGFloat, height: CGFloat)
}

class ParsecViewController: UIViewController, UIScrollViewDelegate, ParsecTouchInputDelegate {
	var glkView: ParsecPlayground!
	var gamePadController: GamepadController!
	var touchController: TouchController!
	var u: UIImageView?
	var lastImg: CGImage?
    var lastMouseX: Int32 = -1
    var lastMouseY: Int32 = -1
    var lastCursorHidden: Bool = false
	var zoomEnabled = false
	var appliedRenderScale: CGFloat = 0       // last contentScaleFactor applied (avoids redundant reallocations)
	let maxRenderScale: CGFloat = 6.0         // cap on drawable density
	var clickHoldActive = false        // left button held via long-press (file drag)
	// Flick-to-glide momentum (tuned constants, not user settings).
	var momentumLink: CADisplayLink?
	var cursorMomentumActive = false
	var scrollMomentumActive = false
	var edgeScrollActive = false
	var edgeScrollPoint: CGPoint = .zero
	var edgeScrollLastTick: CFTimeInterval = 0
	let edgeScrollMargin: CGFloat = 44.0
	let edgeScrollMaxSpeed: CGFloat = 900.0
	var cursorVelocity: CGPoint = .zero     // content points / sec
	var scrollVelocity: Float = 0.0         // wheel units / sec
	var lastCursorMoveTime: CFTimeInterval = 0
	var lastScrollMoveTime: CFTimeInterval = 0
	let flingMinSpeed: CGFloat = 80.0       // min release speed (content pts/sec) to start a cursor glide
	let cursorStopSpeed: CGFloat = 40.0     // end the glide below this speed (lower = gentler, less abrupt)
	let cursorDecayPerSec: Double = 0.08    // fraction of speed left after 1s (bigger = longer glide)
	let scrollStartSpeed: Float = 800.0     // min release speed (wheel units/sec) to start a scroll glide
	let scrollStopSpeed: Float = 200.0
	let scrollDecayPerSec: Double = 0.004
	// A left click fires only if the finger barely moved (else it's a cursor nudge).
	var cursorDidMoveThisTouch = false
	var singleTouchStartScreen: CGPoint = .zero
	let tapMoveSlop: CGFloat = 4.0          // finger movement (pts) above which a touch is a drag, not a tap
	let staleTouchThreshold: TimeInterval = 1.5   // a touch idle this long vs an actively-moving one is a ghost
	let staleMoveSlop: CGFloat = 24.0        // the moving finger must travel this far before a ghost is swept
	var twoFingerDidMove = false            // true once a 2-finger gesture became a pinch/scroll (suppresses right-click)

	var mouseSensitivity: Float { Float(SettingsHandler.mouseSensitivity) }
	// Two-finger scroll-wheel accumulation, kept separate from cursor movement.
	var lastScrollTranslation: CGPoint = .zero
	var accumulatedScrollY: Float = 0.0
	var accumulatedScrollX: Float = 0.0
	// smoothed finger speed (pts/sec) driving touchpad pointer acceleration
	var smoothedFingerSpeed: CGFloat = 0
	private lazy var lightImpact = UIImpactFeedbackGenerator(style: .light)
	private lazy var mediumImpact = UIImpactFeedbackGenerator(style: .medium)
	var scrollWheelSpeed: Float { Float(SettingsHandler.scrollSensitivity) * 2.3 }

	// Input-driven cursor + viewport state (manual touch handling via TouchOverlayView).
	var touchOverlay: TouchOverlayView!
	var cursorContentPos: CGPoint = .zero
	var isDragging = false
	var twoFingerResidual = false       // leftover finger after a 2-finger gesture; inert until full lift
	var activeTouches: [UITouch] = []   // ordered; first two drive pinch / scroll
	var touchOrigins: [UITouch: CGPoint] = [:]   // begin location per touch, for ghost-sweep movement test

	enum TwoFingerMode { case undecided, zoom, scroll, pan, appZoom }
	var multiFingerResidual = false     // fingers left after a three-finger gesture; inert until full lift
	var appZoomCtrlHeld = false         // Ctrl held down for a Windows pinch zoom (Ctrl + wheel)
	var appZoomAccum: CGFloat = 0

	// One finger in the Windows-style touch modes (Direct, Two-Finger, Three-Finger), decided as the
	// finger moves: a tap clicks, a drag scrolls, a hold right clicks, a hold then drag drags.
	enum TouchPhase { case idle, pending, scrolling, holdArmed, dragging }
	var touchPhase: TouchPhase = .idle
	var touchHoldTimer: Timer?
	var touchStartContent: CGPoint = .zero
	var touchEmulatedThisTouch = false
	var lastTapTime: CFTimeInterval = 0
	var lastTapScreen: CGPoint = .zero
	var lastTapContent: CGPoint = .zero
	let doubleTapWindow: CFTimeInterval = 0.4
	let doubleTapSlop: CGFloat = 28

	// press and hold: a grey circle fills in under the cursor, when it's full the left button is
	// held so the next movement drags (like a remote desktop app on a phone)
	var holdIndicator: CAShapeLayer?
	let holdToDragDuration: TimeInterval = 0.5
	let holdIndicatorDelay: TimeInterval = 0.12
	let holdMoveSlop: CGFloat = 12
	var twoFingerMode: TwoFingerMode = .undecided
	var startPinchDistance: CGFloat = 0
	var lastPinchDistance: CGFloat = 0
	var startTwoFingerMidpoint: CGPoint = .zero
	var lastTwoFingerMidpoint: CGPoint = .zero

	var keyboardAccessoriesView: UIView?
	var keyboardHeight: CGFloat = 0.0
	var keyboardVisible: Bool = false
	var pinnedToKeyboard = false
	var onKeyboardCoversPicture: (() -> Void)?
	private var panHandle: UIImageView?
	private var keyScrollView: UIScrollView?
	private var keyBarDone: UIButton?
	private var extraKeyScrollView: UIScrollView?
	private var keyBarBuiltWithExtraRow = false
	private var panStartOffset: CGPoint = .zero
	private var keyboardCoversPicture = false
	var onKeyboardVisibilityChanged: ((Bool) -> Void)?
	var onMenuEdgeSwipe: (() -> Void)?
	var menuEdgeSwipe: UIScreenEdgePanGestureRecognizer?
	var menuEdgeSwipeRight: UIScreenEdgePanGestureRecognizer?
	var scrollView: UIScrollView!
	var contentView: UIView!
	var lastLaidOutWidth: CGFloat = 0
	var lastLaidOutHeight: CGFloat = 0

	override var prefersPointerLocked: Bool {
		return true
	}

	override var prefersHomeIndicatorAutoHidden: Bool {
		return true
	}

	// we're a text input while the keyboard is up, so iOS would otherwise grab three-finger swipes
	// and pinches for its own undo / copy / paste gestures
	override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
		return .none
	}

	init() {
		super.init(nibName: nil, bundle: nil)

		let update: () -> Void = { [weak self] in self?.updateImage() }
		let metal = SettingsHandler.renderer == .metal ? ParsecMetalViewController(viewController: self, updateImage: update) : nil
		if let metal = metal, metal.metalRenderer != nil {
			self.glkView = metal
			CParsec.runningRenderer = .metal
			appNote("[renderer] metal")
		} else {
			CParsec.runningRenderer = .opengl
			appNote("[renderer] opengl")
			if metal != nil {
				os_log("%{public}@", log: sdkLog, type: .error, "metal could not start, using opengl")
			}
			self.glkView = ParsecGLKViewController(viewController: self, updateImage: update)
		}

		self.gamePadController = GamepadController()
		self.touchController = TouchController()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func computeRenderScale() -> CGFloat {
		let nativeScale = UIScreen.main.nativeScale
		guard scrollView.zoomScale > 1.01 else { return nativeScale }
		let vw = glkView.renderView.frame.size.width
		let vh = glkView.renderView.frame.size.height
		let sw = CGFloat(CParsec.hostWidth)
		let sh = CGFloat(CParsec.hostHeight)
		guard vw > 0, vh > 0, sw > 0, sh > 0 else { return nativeScale }
		// Match the drawable to the source so zoom stays crisp without rendering wasted pixels.
		let needed = max(sw / vw, sh / vh)
		return min(maxRenderScale, max(nativeScale, needed))
	}

	func updateRenderScale() {
		// only matters once zoomed in or after zooming back out, skip the math every other frame
		guard scrollView.zoomScale > 1.01 || appliedRenderScale != UIScreen.main.nativeScale else { return }
		let target = computeRenderScale()
		if abs(target - appliedRenderScale) > 0.01 {
			appliedRenderScale = target
			DispatchQueue.main.async { [weak self] in
				self?.glkView.renderView.contentScaleFactor = target
			}
		}
	}

	func updateImage() {
		updateRenderScale()
		// runs every vsync: copy the cursor state once instead of going through the
		// service protocol (and retaining the CGImage) four separate times
		let info = CParsec.mouseInfo
		let currentMouseX = info.mouseX
		let currentMouseY = info.mouseY
		let currentHidden = info.cursorHidden
		let currentImg = info.cursorImg

        // Skip if nothing changed
        if currentMouseX == lastMouseX &&
           currentMouseY == lastMouseY &&
           currentHidden == lastCursorHidden &&
           currentImg == lastImg {
            return
        }

        lastMouseX = currentMouseX
        lastMouseY = currentMouseY
        lastCursorHidden = currentHidden

		if currentImg != nil && !currentHidden {
			u?.isHidden = false
			if lastImg != currentImg {
				u!.image = UIImage(cgImage: currentImg!)
				lastImg = currentImg!
			}

			// While dragging, the touch handler owns the cursor position and viewport (smooth,
			// input-driven). When idle, follow the host's reported cursor so host- or keyboard-
			// driven moves are reflected and any prediction drift is corrected.
			if !isDragging && !clickHoldActive && !cursorMomentumActive {
				let fingerSet = SettingsHandler.cursorMode.isTouch
					&& abs(cursorContentPos.x - CGFloat(currentMouseX)) < 1
					&& abs(cursorContentPos.y - CGFloat(currentMouseY)) < 1
				cursorContentPos = CGPoint(x: CGFloat(currentMouseX), y: CGFloat(currentMouseY))
				positionCursorOverlay()
				if scrollView.zoomScale > 1.0 {
					// in the touch modes the view only moves when you move it
					if !fingerSet && !SettingsHandler.cursorMode.isTouch {
						centerViewportOnCursorPos()
						positionCursorOverlay()
					}
				} else {
					// Not zoomed: keep the cursor above the on-screen keyboard.
					keepCursorAboveKeyboard()
				}
			}
		} else {
			u?.isHidden = true
		}
	}

	func applyFrameRate() {
		let fps = SettingsHandler.preferredFramesPerSecond == 0 ? UIScreen.main.maximumFramesPerSecond : SettingsHandler.preferredFramesPerSecond
		(glkView as? ParsecMetalViewController)?.metalView.preferredFramesPerSecond = fps
		(glkView as? ParsecGLKViewController)?.glkViewController.preferredFramesPerSecond = fps
	}

	override func viewDidLoad() {
		// ScrollView Setup
		scrollView = UIScrollView(frame: view.bounds)
		scrollView.delegate = self
		scrollView.minimumZoomScale = 1.0
		scrollView.maximumZoomScale = 5.0
		scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		// The scroll view is a programmatically-driven zoom/pan container only. Every touch is
		// owned by touchOverlay (created below); the scroll view's own gestures are disabled so
		// they can never race with or swallow our cursor / pinch / scroll handling.
		scrollView.panGestureRecognizer.isEnabled = false
		scrollView.pinchGestureRecognizer?.isEnabled = false
		scrollView.isScrollEnabled = false
		scrollView.bouncesZoom = false
		view.addSubview(scrollView)

        // ContentView
		contentView = UIView(frame: view.bounds)
		scrollView.addSubview(contentView)
		scrollView.contentSize = view.bounds.size

        // Initialize GLKView
		glkView.viewDidLoad()

		// Move GLKView to ContentView
		// glkView.viewDidLoad() adds the view to 'view', we need to move it.
		glkView.renderView.removeFromSuperview()
		contentView.addSubview(glkView.renderView)

		if #available(iOS 15.0, *) {
			if SettingsHandler.enablePiP {
				if let parsecGLK = glkView as? ParsecGLKViewController, let eaglContext = parsecGLK.eaglContext {
					PictureInPictureManager.shared.setup(sourceView: view, glContext: eaglContext)
				} else if glkView is ParsecMetalViewController {
					PictureInPictureManager.shared.setup(sourceView: view, glContext: nil)
				}
			}
		}

		touchController.viewDidLoad()
		gamePadController.viewDidLoad()

		// Touch overlay: a transparent sibling ON TOP of the scroll view (and above the gamepad /
		// touch controllers) that captures every raw touch and routes it deterministically
		// (1 finger = cursor, 2 fingers = pinch / scroll). Added before the cursor image and the
		// keyboard toolbar so those stay on top of it.
		touchOverlay = TouchOverlayView(frame: view.bounds)
		touchOverlay.backgroundColor = .clear
		touchOverlay.isMultipleTouchEnabled = true
		touchOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		touchOverlay.inputDelegate = self
		view.addSubview(touchOverlay)

		// Cursor is a screen-space overlay ON TOP of everything (not inside the scroll view), so the
		// zoom transform never scales it - keeping it crisp and a constant on-screen size.
		u = UIImageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
		u!.isUserInteractionEnabled = false
		view.addSubview(u!)

		setNeedsUpdateOfPrefersPointerLocked()

		let pointerInteraction = UIPointerInteraction(delegate: self)
		view.addInteraction(pointerInteraction)

		view.isMultipleTouchEnabled = true
		view.isUserInteractionEnabled = true

		// All gestures (cursor, pinch-zoom, two-finger scroll) are handled in the
		// ParsecTouchInputDelegate methods below, driven by touchOverlay's raw touches.

		// Add tap gesture recognizer for single-finger touch
		let singleFingerTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleSingleFingerTap(_:)))
		singleFingerTapGestureRecognizer.numberOfTouchesRequired = 1
		singleFingerTapGestureRecognizer.allowedTouchTypes = [0, 2]
		// Let the overlay see the real touch end so no phantom finger lingers.
		singleFingerTapGestureRecognizer.cancelsTouchesInView = false
		singleFingerTapGestureRecognizer.delaysTouchesEnded = false
		view.addGestureRecognizer(singleFingerTapGestureRecognizer)

		// Add tap gesture recognizer for two-finger touch
		let twoFingerTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
		twoFingerTapGestureRecognizer.numberOfTouchesRequired = 2
		twoFingerTapGestureRecognizer.allowedTouchTypes = [0]
		twoFingerTapGestureRecognizer.cancelsTouchesInView = false
		twoFingerTapGestureRecognizer.delaysTouchesEnded = false
		view.addGestureRecognizer(twoFingerTapGestureRecognizer)
		//		view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
		//		view.backgroundColor = UIColor(red: 0x66, green: 0xcc, blue: 0xff, alpha: 1.0)

		let threeFingerTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleThreeFinderTap(_:)))
		threeFingerTapGestureRecognizer.numberOfTouchesRequired = 3
		threeFingerTapGestureRecognizer.allowedTouchTypes = [0]
		threeFingerTapGestureRecognizer.cancelsTouchesInView = false
		threeFingerTapGestureRecognizer.delaysTouchesEnded = false
		view.addGestureRecognizer(threeFingerTapGestureRecognizer)

		let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
		longPressGestureRecognizer.numberOfTouchesRequired = 1
		longPressGestureRecognizer.allowedTouchTypes = [0, 2]
		longPressGestureRecognizer.minimumPressDuration = holdToDragDuration
		// the finger has to stay put (same slop the grey circle uses) or it's a cursor move
		longPressGestureRecognizer.allowableMovement = holdMoveSlop
		// Don't cancel the overlay's touch, so the click-hold button can be released on lift.
		longPressGestureRecognizer.cancelsTouchesInView = false
		view.addGestureRecognizer(longPressGestureRecognizer)

		// three-finger swipe up shows the keyboard, down hides it (or brings up the menu)
		let swipeDirections: [UISwipeGestureRecognizer.Direction] = [.up, .down]
		for direction in swipeDirections {
			let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe(_:)))
			swipe.direction = direction
			swipe.numberOfTouchesRequired = 3
			swipe.cancelsTouchesInView = false
			swipe.delaysTouchesEnded = false
			view.addGestureRecognizer(swipe)
		}

		menuEdgeSwipe = addMenuEdgeSwipe(.left)
		menuEdgeSwipeRight = addMenuEdgeSwipe(.right)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(keyboardWillShow),
			name: UIResponder.keyboardWillShowNotification,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(inputWasReleased),
			name: NSNotification.Name("ParsecInputReleased"),
			object: nil
		)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(keyboardWillHide),
			name: UIResponder.keyboardWillHideNotification,
			object: nil
		)

		// Backgrounding / Control Center / system alerts can orphan touches; flush on resign.
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(appWillResignActive),
			name: UIApplication.willResignActiveNotification,
			object: nil
		)

	}

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)

		let h = size.height
		let w = size.width

		// Reset zoom on rotation
		scrollView.zoomScale = 1.0

		self.glkView.updateSize(width: w, height: h)
		contentView.frame.size = CGSize(width: w, height: h)
		scrollView.contentSize = CGSize(width: w, height: h)
		CParsec.setFrame(w, h, UIScreen.main.scale)

        // Reset accessory view to ensure correct width in new orientation
        clearToolbarModifiers(sendToHost: true)
        keyboardAccessoriesView = nil
        if keyboardVisible {
            reloadInputViews()
        }
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		// glkView/contentView get sized from possibly-stale bounds in viewDidLoad and have no
		// autoresizing, so the stream renders in a corner until a rotation re-applies the size.
		// re-apply once layout settles; skip while zoomed so we dont stomp pan/zoom.
		guard scrollView != nil, scrollView.zoomScale == 1.0 else { return }
		let w = view.bounds.width
		let h = view.bounds.height
		guard w > 0, h > 0, w != lastLaidOutWidth || h != lastLaidOutHeight else { return }
		lastLaidOutWidth = w
		lastLaidOutHeight = h
		glkView.updateSize(width: w, height: h)
		contentView.frame.size = CGSize(width: w, height: h)
		scrollView.contentSize = CGSize(width: w, height: h)
		CParsec.setFrame(w, h, UIScreen.main.scale)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		UIApplication.shared.isIdleTimerDisabled = true
		if let parent = parent {
			parent.setChildForHomeIndicatorAutoHidden(self)
			parent.setChildViewControllerForPointerLock(self)
		}
		if keyboardVisible {
			becomeFirstResponder()
		}
		// (Pinch-to-zoom is driven manually via touchOverlay; the scroll view's pinch stays off.)
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		UIApplication.shared.isIdleTimerDisabled = false
		stopMomentum()
		if let parent = parent {
			parent.setChildForHomeIndicatorAutoHidden(nil)
			parent.setChildViewControllerForPointerLock(nil)
		}
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
	}
	
	
	private var repeatTimer: Timer?
	private var repeatKeyCode: Int = -1
	private var optCmdRemapActive = false
	private var altKeyHeld = false

	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key else { continue }

			if key.keyCode == .keyboardLeftAlt || key.keyCode == .keyboardRightAlt {
				altKeyHeld = true
			}

			if SettingsHandler.optionAsCommand && !isModifierKey(key.keyCode) && (altKeyHeld || key.modifierFlags.contains(.alternate)) {
				if !optCmdRemapActive {
					CParsec.sendKeyboardMessage(keyCode: 226, pressed: false)
					CParsec.sendKeyboardMessage(keyCode: 230, pressed: false)
					CParsec.sendKeyboardMessage(keyCode: 227, pressed: true)
					optCmdRemapActive = true
				}
				let code = KeyCodeTranslators.uiKeyCodeToInt(key: key.keyCode)
				CParsec.sendKeyboardMessage(keyCode: UInt32(code), pressed: true)
				startKeyRepeat(keyCode: code)
				continue
			}

			CParsec.sendKeyboardMessage(event:KeyBoardKeyEvent(input: press.key, isPressBegin: true))

			if !isModifierKey(key.keyCode) {
				startKeyRepeat(keyCode: KeyCodeTranslators.uiKeyCodeToInt(key: key.keyCode))
			}
		}
	}

	override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key else { continue }

			if optCmdRemapActive {
				if key.keyCode == .keyboardLeftAlt || key.keyCode == .keyboardRightAlt {
					altKeyHeld = false
					CParsec.sendKeyboardMessage(keyCode: 227, pressed: false)
					optCmdRemapActive = false
					continue
				}
				if !isModifierKey(key.keyCode) {
					let code = KeyCodeTranslators.uiKeyCodeToInt(key: key.keyCode)
					CParsec.sendKeyboardMessage(keyCode: UInt32(code), pressed: false)
					if code == repeatKeyCode { stopKeyRepeat() }
					continue
				}
			}

			if key.keyCode == .keyboardLeftAlt || key.keyCode == .keyboardRightAlt {
				altKeyHeld = false
			}

			CParsec.sendKeyboardMessage(event:KeyBoardKeyEvent(input: press.key, isPressBegin: false))

			let code = KeyCodeTranslators.uiKeyCodeToInt(key: key.keyCode)
			if code == repeatKeyCode {
				stopKeyRepeat()
			}
		}
	}

	override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		// iOS sends this instead of pressesEnded when a press is interrupted (e.g. backgrounding
		// mid-hold) — without cleanup the host keeps keys held (stuck paste, stuck modifier).
		CParsec.sendReleaseMessage()
		resetKeyState()
	}

	private func startKeyRepeat(keyCode: Int) {
		stopKeyRepeat()
		repeatKeyCode = keyCode

		repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self = self else { return }
				self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
					MainActor.assumeIsolated {
						guard let self = self else { return }
						CParsec.sendKeyboardMessage(keyCode: UInt32(self.repeatKeyCode), pressed: false)
						CParsec.sendKeyboardMessage(keyCode: UInt32(self.repeatKeyCode), pressed: true)
					}
				}
			}
		}
	}

	private func stopKeyRepeat() {
		repeatTimer?.invalidate()
		repeatTimer = nil
		repeatKeyCode = -1
	}

	func resetKeyState() {
		stopKeyRepeat()
		optCmdRemapActive = false
		altKeyHeld = false
	}

	private func isModifierKey(_ keyCode: UIKeyboardHIDUsage) -> Bool {
		switch keyCode {
		case .keyboardLeftControl, .keyboardLeftShift, .keyboardLeftAlt, .keyboardLeftGUI,
			 .keyboardRightControl, .keyboardRightShift, .keyboardRightAlt, .keyboardRightGUI,
			 .keyboardCapsLock:
			return true
		default:
			return false
		}
	}

	@objc func keyboardWillShow(notification: NSNotification) {
		if let keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
			let keyboardFrameInView = view.convert(keyboardFrame, from: nil)
			let scrollFrameInView = scrollView.convert(scrollView.bounds, to: view)
			let intersection = scrollFrameInView.intersection(keyboardFrameInView)
			let coversBottomEdge = !intersection.isNull && intersection.maxY >= scrollFrameInView.maxY - 1
			let height = coversBottomEdge ? intersection.height : 0
			keyboardHeight = height
            keyboardVisible = true

            // Allow scrolling past current bottom to see hidden content
            scrollView.contentInset.bottom = height

			if scrollView.zoomScale <= 1.0, let shift = pictureShiftAboveKeyboard(height - accessoryClearBand) {
				keyboardCoversPicture = false
				updatePanHandle()
				pinnedToKeyboard = true
				scrollView.contentInset.top = max(0, -shift)
				scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: shift), animated: true)
				onKeyboardVisibilityChanged?(true)
				return
			}
			var baseY = scrollView.contentOffset.y
			if pinnedToKeyboard {
				pinnedToKeyboard = false
				scrollView.contentInset.top = 0
				baseY = 0
			}
			keyboardCoversPicture = height > 0
			updatePanHandle()
			if height > 0 && SettingsHandler.cursorMode.isTouch {
				onKeyboardCoversPicture?()
			}
			if SettingsHandler.cursorMode.isTouch {
				let bottomY = max(0, scrollView.contentSize.height - scrollView.bounds.height + height)
				scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottomY), animated: true)
				onKeyboardVisibilityChanged?(true)
				return
			}

            // Automatic scroll up only if mouse is in the bottom half of the screen
            let mouseY = CGFloat(CParsec.mouseInfo.mouseY)
            let screenMidY = view.bounds.height / 2.1

            if mouseY > screenMidY {
                 let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + height)
                 let newOffsetY = min(maxOffsetY, baseY + height / 1.25)

                 scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newOffsetY), animated: true)

            } else if baseY != scrollView.contentOffset.y {
				scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: baseY), animated: true)
			}
		}
		onKeyboardVisibilityChanged?(true)
	}

	var accessoryClearBand: CGFloat {
		keyboardAccessoriesView?.subviews.map { $0.frame.minY }.min() ?? 0
	}

	func pictureShiftAboveKeyboard(_ keyboard: CGFloat) -> CGFloat? {
		let w = view.bounds.width, h = view.bounds.height
		guard keyboard > 0, CParsec.hostWidth > 0, CParsec.hostHeight > 0 else { return nil }
		let picture = min(h, w * CGFloat(CParsec.hostHeight / CParsec.hostWidth))
		guard picture <= h - keyboard else { return nil }
		return keyboard - (h - picture) / 2
	}

	func updatePanHandle() {
		setPanHandleVisible(keyboardCoversPicture && SettingsHandler.cursorMode.isTouch)
	}

	func setPanHandleVisible(_ visible: Bool) {
		guard let handle = panHandle else { return }
		handle.isHidden = !visible
		setPanHandleAxes()
		layoutKeyBar()
	}

	func setPanHandleAxes() {
		guard let handle = panHandle, !handle.isHidden else { return }
		let zoomed = scrollView.zoomScale > 1.01
		let label = zoomed ? "Move screen in any direction" : "Move screen up or down"
		guard handle.accessibilityLabel != label else { return }
		handle.image = UIImage(systemName: zoomed ? "arrow.up.and.down.and.arrow.left.and.right" : "arrow.up.and.down")
		handle.accessibilityLabel = label
	}

	func layoutKeyBar() {
		guard let handle = panHandle, let keys = keyScrollView, let bar = keys.superview else { return }
		let inset = bar.safeAreaInsets
		handle.frame.origin.x = 4 + inset.left
		let left = (handle.isHidden ? 8 : 48) + inset.left
		keys.frame = CGRect(x: left, y: 0, width: bar.bounds.width - 72 - left - inset.right, height: 44)
		keyBarDone?.frame.origin.x = bar.bounds.width - 70 - inset.right
		if let extra = extraKeyScrollView, let extraBar = extra.superview {
			let extraInset = extraBar.safeAreaInsets
			extra.frame = CGRect(x: 8 + extraInset.left, y: 0, width: extraBar.bounds.width - 16 - extraInset.left - extraInset.right, height: 44)
		}
	}

	@objc func handlePanHandle(_ gesture: UIPanGestureRecognizer) {
		if gesture.state == .began {
			panStartOffset = scrollView.contentOffset
		}
		let t = gesture.translation(in: view)
		let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
		let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
		let x = min(max(0, panStartOffset.x - t.x), maxX)
		let y = min(max(-scrollView.contentInset.top, panStartOffset.y - t.y), maxY)
		scrollView.setContentOffset(CGPoint(x: x, y: y), animated: false)
		positionCursorOverlay()
	}

	@objc func handlePanHandleDoubleTap(_ gesture: UITapGestureRecognizer) {
		let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
		let y: CGFloat = scrollView.contentOffset.y < maxY / 2 ? maxY : 0
		scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: true)
	}

	@objc func keyboardWillHide(notification: NSNotification) {
		keyboardHeight = 0.0
        keyboardVisible = false
		keyboardCoversPicture = false
		setPanHandleVisible(false)
		if pinnedToKeyboard {
			pinnedToKeyboard = false
			scrollView.contentInset = .zero
			scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: 0), animated: true)
			onKeyboardVisibilityChanged?(false)
			return
		}

        // Restore inset
        scrollView.contentInset.bottom = 0

        // Transform cleanup (just in case)
        view.transform = .identity

        // Automatic scroll down in landscape mode (reverse of show)
        if view.bounds.width > view.bounds.height {
             // We subtract, but clamp to 0 (or valid range)
			let newOffsetY = max(0, scrollView.contentOffset.y - ((notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.height ?? 0.0))
             // Or maybe just clamp to valid range without forcing a subtract?
             // User said "bajar la altura", implying a reverse scroll.
             scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newOffsetY), animated: true)
        }
		onKeyboardVisibilityChanged?(false)
	}

}

extension ParsecViewController: UIGestureRecognizerDelegate {

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		return true
	}

	// the delay stops a direct mode swipe from clicking at the edge first
	private func addMenuEdgeSwipe(_ edge: UIRectEdge) -> UIScreenEdgePanGestureRecognizer {
		let edgeSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleMenuEdgeSwipe(_:)))
		edgeSwipe.edges = edge
		edgeSwipe.maximumNumberOfTouches = 1
		edgeSwipe.allowedTouchTypes = [0]
		edgeSwipe.delaysTouchesBegan = true
		edgeSwipe.isEnabled = false
		view.addGestureRecognizer(edgeSwipe)
		return edgeSwipe
	}

	// left brings back a hidden menu button, slide over owns the right edge
	func updateMenuEdgeSwipe(menuHidden: Bool) {
		menuEdgeSwipe?.isEnabled = menuHidden || SettingsHandler.menuSwipeEdge == .left
		menuEdgeSwipeRight?.isEnabled = SettingsHandler.menuSwipeEdge == .right
	}

	// switching it off mid swipe would hand the held touch to the stream
	@objc private func handleMenuEdgeSwipe(_ gestureRecognizer: UIScreenEdgePanGestureRecognizer) {
		switch gestureRecognizer.state {
		case .began:
			flushAllTouches()
			onMenuEdgeSwipe?()
		case .ended, .cancelled, .failed:
			updateMenuEdgeSwipe(menuHidden: false)
		default:
			break
		}
	}

	@objc func handlePinchGesture(_ gestureRecognizer: UIPinchGestureRecognizer) {
		// Pinch is handled by UIScrollView
	}

	// MARK: - Manual touch handling (ParsecTouchInputDelegate)
	// touchOverlay delivers raw touches here. One finger drives the mouse cursor; two fingers are
	// classified once per gesture into either pinch-zoom or host scroll-wheel (never both), so the
	// gestures never fight. No UIScrollView gesture recognizer is in the loop.

	func parsecTouchesUpdated(_ touches: Set<UITouch>, moved: Bool) {
		let oldCount = activeTouches.count
		// Rebuild from the event each time (keeping order) so a cancelled touch can't leave a stale one.
		var ordered = activeTouches.filter { touches.contains($0) }
		for t in touches where !ordered.contains(t) {
			ordered.append(t)
			touchOrigins[t] = t.location(in: view)
		}
		// Sweep a ghost (an OS-dropped lift lingering as .stationary) only while another finger actively
		// moves - a resting or just-tapped finger is never swept, so taps and held fingers stay safe.
		var sweptGhost = false
		if ordered.count >= 2 && !clickHoldActive,
		   let newest = ordered.max(by: { $0.timestamp < $1.timestamp }) {
			let origin = touchOrigins[newest] ?? newest.location(in: view)
			let here = newest.location(in: view)
			if hypot(here.x - origin.x, here.y - origin.y) > staleMoveSlop {
				let fresh = ordered.filter { newest.timestamp - $0.timestamp < staleTouchThreshold }
				if fresh.count < ordered.count { ordered = fresh; sweptGhost = true }
			}
		}
		activeTouches = ordered
		touchOrigins = touchOrigins.filter { activeTouches.contains($0.key) }
		if sweptGhost && activeTouches.count == 1 {
			// Recover the surviving finger as a live cursor instead of inert two-finger residual.
			stopMomentum()
			twoFingerResidual = false
			twoFingerMode = .undecided
			startCursor()
		} else if activeTouches.count != oldCount {
			handleTouchCountChange(old: oldCount, new: activeTouches.count)
		}
		if moved { handleActiveTouchesMoved() }
	}

	private func handleTouchCountChange(old: Int, new: Int) {
		cancelHoldIndicator()
		edgeScrollActive = false
		if new > old { stopMomentum() }   // any new finger cancels an in-progress glide
		if new == 0 {
			let flingCursor = (old == 1) && isDragging && !twoFingerResidual && !clickHoldActive
			let flingScroll = ((old >= 2) && (twoFingerMode == .scroll)) || ((old == 1) && touchPhase == .scrolling)
			releaseClickHoldIfNeeded()   // defensive: the left button must never stay stuck down
			endCursorIfNeeded(lifted: true)
			endMultiFinger()
			isDragging = false
			twoFingerResidual = false
			multiFingerResidual = false
			twoFingerMode = .undecided
			if flingCursor { startCursorMomentum() }
			if flingScroll { startScrollMomentum() }
		} else if new == 1 {
			if old >= 2 {
				// Leftover finger after a two-finger gesture: stay inert until full lift so it
				// doesn't jump the cursor.
				if twoFingerMode == .scroll { startScrollMomentum() }
				endMultiFinger()
				twoFingerResidual = true
				twoFingerMode = .undecided
			} else if old == 0 {
				startCursor()
			}
		} else if new >= 2 {
			releaseClickHoldIfNeeded()   // can't keep the button held during a two-finger gesture
			if isDragging { endCursorIfNeeded(lifted: false); isDragging = false }
			endMultiFinger()
			if new < old {
				// a finger left a three-finger gesture: the rest stay inert until everything lifts
				multiFingerResidual = true
				twoFingerMode = .undecided
			} else {
				multiFingerResidual = false
				beginTwoFinger()
			}
		}
	}

	private func releaseClickHoldIfNeeded() {
		if clickHoldActive {
			CParsec.sendMouseClickMessage(ParsecMouseButton.init(rawValue: 1), false)
			clickHoldActive = false
		}
	}

	@objc private func appWillResignActive() { flushAllTouches() }

	// Drop all touch state and release any held button so nothing sticks when backgrounded.
	private func flushAllTouches() {
		cancelHoldIndicator()
		stopMomentum()
		releaseClickHoldIfNeeded()
		endCursorIfNeeded(lifted: false)
		endMultiFinger()
		isDragging = false
		twoFingerResidual = false
		multiFingerResidual = false
		twoFingerMode = .undecided
		activeTouches = []
	}

	// called when the touch mode is changed during a stream
	func applyCursorMode() {
		flushAllTouches()
		if SettingsHandler.cursorMode == .direct {
			resetZoom()   // Direct Touch always shows the whole desktop
		}
		updatePanHandle()
	}

	private func startCursor() {
		isDragging = true
		twoFingerResidual = false
		cursorDidMoveThisTouch = false
		smoothedFingerSpeed = 0
		singleTouchStartScreen = activeTouches.first?.location(in: view) ?? .zero
		touchEmulatedThisTouch = SettingsHandler.cursorMode.isTouch && !CParsec.mouseInfo.mousePositionRelative
		if touchEmulatedThisTouch {
			beginTouch(at: singleTouchStartScreen)
		} else if !clickHoldActive {
			startHoldIndicator(at: cursorScreenPoint)
		}
	}

	private func endCursorIfNeeded(lifted: Bool) {
		guard isDragging, touchPhase != .idle else { return }
		finishTouch(lifted: lifted)
	}

	// MARK: - Windows-style touch (Direct, Two-Finger and Three-Finger modes)
	// Parsec can only send mouse and keyboard, so a finger is turned into what Windows does with a
	// touch: tap = click where the finger is, drag = scroll, hold = right click, hold then drag =
	// drag whatever is under the finger.

	private func beginTouch(at screen: CGPoint) {
		touchHoldTimer?.invalidate()
		touchPhase = .pending
		var start = clampToContent(contentView.convert(screen, from: view))
		// a second tap close to the first lands on the same spot, so Windows sees a double click
		if CACurrentMediaTime() - lastTapTime < doubleTapWindow,
		   hypot(screen.x - lastTapScreen.x, screen.y - lastTapScreen.y) < doubleTapSlop {
			start = lastTapContent
		}
		touchStartContent = start
		if !CParsec.mouseInfo.mousePositionRelative {
			// hover first: Windows scrolls and clicks whatever is under the pointer
			cursorContentPos = start
			CParsec.sendMousePosition(Int32(start.x), Int32(start.y))
			positionCursorOverlay()
		}
		startHoldIndicator(at: screen)
		touchHoldTimer = Timer.scheduledTimer(withTimeInterval: holdToDragDuration, repeats: false) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.touchHoldCompleted()
			}
		}
	}

	private func touchHoldCompleted() {
		touchHoldTimer = nil
		guard touchPhase == .pending else { return }
		// the grey circle is full: lifting now is a right click, moving now drags
		touchPhase = .holdArmed
		cancelHoldIndicator()
		haptic(true)
		showClickRipple(at: singleTouchStartScreen, secondary: true)
	}

	private func moveTouch(with t: UITouch) {
		let loc = t.location(in: view)
		let prev = t.previousLocation(in: view)
		let travelled = hypot(loc.x - singleTouchStartScreen.x, loc.y - singleTouchStartScreen.y)
		if travelled > tapMoveSlop {
			cursorDidMoveThisTouch = true
		}
		switch touchPhase {
		case .pending:
			guard travelled > holdMoveSlop else { return }
			touchHoldTimer?.invalidate()
			touchHoldTimer = nil
			cancelHoldIndicator()
			touchPhase = .scrolling
			accumulatedScrollX = 0
			accumulatedScrollY = 0
			scrollTouch(dx: loc.x - prev.x, dy: loc.y - prev.y, total: CGPoint(x: loc.x - singleTouchStartScreen.x, y: loc.y - singleTouchStartScreen.y))
		case .scrolling:
			scrollTouch(dx: loc.x - prev.x, dy: loc.y - prev.y, total: CGPoint(x: loc.x - singleTouchStartScreen.x, y: loc.y - singleTouchStartScreen.y))
		case .holdArmed:
			guard travelled > holdMoveSlop else { return }
			touchPhase = .dragging
			CParsec.sendMouseMessage(ParsecMouseButton(rawValue: 1), Int32(touchStartContent.x), Int32(touchStartContent.y), true)
			dragTouch(to: loc)
		case .dragging:
			dragTouch(to: loc)
		case .idle:
			break
		}
	}

	// one finger scrolls like on a touch screen: the content follows the finger
	private func scrollTouch(dx: CGFloat, dy: CGFloat, total: CGPoint) {
		let totalX = abs(total.x)
		let totalY = abs(total.y)
		let deltaY = totalY >= totalX * 0.5 ? Float(dy) : 0
		let deltaX = totalX >= totalY * 0.5 ? Float(dx) : 0
		sendScroll(deltaX: deltaX, deltaY: deltaY)
	}

	private func dragTouch(to loc: CGPoint) {
		cursorContentPos = clampToContent(contentView.convert(loc, from: view))
		CParsec.sendMousePosition(Int32(cursorContentPos.x), Int32(cursorContentPos.y))
		positionCursorOverlay()
		// near the edge of a zoomed view, keep sliding the view so a drag can reach off-screen spots
		edgeScrollPoint = loc
		if edgeScrollVelocity(at: loc) != .zero {
			if !edgeScrollActive { edgeScrollLastTick = 0 }
			edgeScrollActive = true
			ensureMomentumLink()
		} else {
			edgeScrollActive = false
		}
	}

	private func finishTouch(lifted: Bool) {
		touchHoldTimer?.invalidate()
		touchHoldTimer = nil
		cancelHoldIndicator()
		edgeScrollActive = false
		let phase = touchPhase
		touchPhase = .idle
		let x = Int32(touchStartContent.x)
		let y = Int32(touchStartContent.y)
		switch phase {
		case .pending where lifted:
			let left = ParsecMouseButton(rawValue: 1)
			CParsec.sendMouseMessage(left, x, y, true)
			CParsec.sendMouseMessage(left, x, y, false)
			lastTapTime = CACurrentMediaTime()
			lastTapScreen = singleTouchStartScreen
			lastTapContent = touchStartContent
			haptic()
			showClickRipple(at: singleTouchStartScreen)
		case .holdArmed where lifted:
			// dont leak a right click to the host while backgrounding or after a disconnect
			guard UIApplication.shared.applicationState == .active,
				  ParsecBackgroundManager.shared.hasActiveConnection else { return }
			let right = ParsecMouseButton(rawValue: 3)
			CParsec.sendMouseMessage(right, x, y, true)
			CParsec.sendMouseMessage(right, x, y, false)
		case .dragging:
			CParsec.sendMouseClickMessage(ParsecMouseButton(rawValue: 1), false)
		default:
			break
		}
	}

	// MARK: - Two and three fingers

	private func beginTwoFinger() {
		twoFingerMode = .undecided
		twoFingerDidMove = false
		accumulatedScrollY = 0.0
		accumulatedScrollX = 0.0
		let d = twoFingerDistanceAndMidpoint()
		startPinchDistance = d.distance
		lastPinchDistance = d.distance
		startTwoFingerMidpoint = d.midpoint
		lastTwoFingerMidpoint = d.midpoint
	}

	// lets go of Ctrl if an app-zoom pinch was holding it
	private func endMultiFinger() {
		if appZoomCtrlHeld {
			CParsec.sendKeyboardMessage(keyCode: 224, pressed: false)
			appZoomCtrlHeld = false
		}
	}

	// Spread and centre of the first two or three fingers. The spread is twice the mean distance
	// from the centre, which for two fingers is simply the distance between them.
	private func twoFingerDistanceAndMidpoint() -> (distance: CGFloat, midpoint: CGPoint) {
		let pts = activeTouches.prefix(3).map { $0.location(in: view) }
		guard pts.count >= 2 else { return (0, pts.first ?? .zero) }
		let n = CGFloat(pts.count)
		var mid = CGPoint.zero
		for p in pts {
			mid.x += p.x / n
			mid.y += p.y / n
		}
		var spread: CGFloat = 0
		for p in pts {
			spread += hypot(p.x - mid.x, p.y - mid.y) / n
		}
		return (spread * 2, mid)
	}

	private func handleActiveTouchesMoved() {
		let count = activeTouches.count
		if (isDragging || clickHoldActive), !twoFingerResidual, count == 1, let t = activeTouches.first {
			if touchPhase != .idle {
				moveTouch(with: t)
			} else {
				moveCursor(with: t)
			}
		} else if multiFingerResidual {
			return
		} else if count == 2 || (count == 3 && SettingsHandler.cursorMode == .threeFingerPanZoom) {
			// three fingers only move the view in Three-Finger mode, elsewhere they're the keyboard swipe
			handleTwoFinger()
		}
	}

	private func moveCursor(with t: UITouch) {
		let zoom = scrollView.zoomScale
		let loc = t.location(in: view)
		let prev = t.previousLocation(in: view)
		let travelled = hypot(loc.x - singleTouchStartScreen.x, loc.y - singleTouchStartScreen.y)
		if travelled > tapMoveSlop {
			cursorDidMoveThisTouch = true
		}
		if travelled > holdMoveSlop {
			cancelHoldIndicator()
		}

		if CParsec.mouseInfo.mousePositionRelative {
			// Host has captured the pointer (e.g. a game): send true relative motion instead.
			let s = CGFloat(mouseSensitivity) / zoom
			CParsec.sendMouseDelta(Int32((loc.x - prev.x) * s), Int32((loc.y - prev.y) * s))
			return
		}

		// Relative finger movement, predicted locally; sensitivity scales down with zoom so the
		// cursor tracks the visible finger.
		let now = CACurrentMediaTime()
		let dt = CGFloat(now - lastCursorMoveTime)
		let fx = loc.x - prev.x
		let fy = loc.y - prev.y
		let s = CGFloat(mouseSensitivity) / zoom * pointerGain(fingerDistance: hypot(fx, fy), dt: dt)
		let dcx = fx * s
		let dcy = fy * s
		cursorContentPos = clampToContent(CGPoint(x: cursorContentPos.x + dcx, y: cursorContentPos.y + dcy))
		// Smoothed velocity so a quick flick keeps gliding after the finger lifts.
		if dt > 0.0005 && dt < 0.1 {
			cursorVelocity = CGPoint(x: cursorVelocity.x * 0.4 + (dcx / dt) * 0.6,
									 y: cursorVelocity.y * 0.4 + (dcy / dt) * 0.6)
		}
		lastCursorMoveTime = now
		// Command the host to the ABSOLUTE predicted position (not a delta) so the host cursor can't
		// crawl behind network round-trips - clicks always land where the cursor is drawn.
		CParsec.sendMousePosition(Int32(cursorContentPos.x), Int32(cursorContentPos.y))
		centerViewportOnCursorPos()
		keepCursorAboveKeyboard()
		positionCursorOverlay()
	}

	// Laptop-style pointer acceleration for touchpad mode: slow, careful finger movement gets finer
	// than 1:1 so small targets are easy to hit, quick swipes cover more of the screen so the
	// finger doesn't run out of glass. Off = the old constant speed.
	private func pointerGain(fingerDistance: CGFloat, dt: CGFloat) -> CGFloat {
		guard SettingsHandler.pointerAcceleration else { return 1 }
		let speed: CGFloat = (dt > 0.0005 && dt < 0.1) ? fingerDistance / dt : 0
		smoothedFingerSpeed = smoothedFingerSpeed * 0.5 + speed * 0.5
		let slow: CGFloat = 120     // pts/sec at or below which movement is precise
		let fast: CGFloat = 1400    // pts/sec at or above which the gain tops out
		let t = min(max((smoothedFingerSpeed - slow) / (fast - slow), 0), 1)
		let eased = t * t * (3 - 2 * t)   // smoothstep, so there's no felt "kick" between speeds
		return 0.65 + eased * 1.6         // 0.65x ... 2.25x
	}

	// What two (or, in Three-Finger mode, three) fingers do, decided once per gesture:
	//   Trackpad      pinch = zoom the view (Pinch to Zoom on), drag = scroll (or pan, see settings)
	//   Direct        pinch = Ctrl+wheel zoom in the app under the fingers, drag = scroll
	//   Two-Finger    pinch = zoom the view, drag = move the view
	//   Three-Finger  2 fingers like Direct, 3 fingers zoom / move the view
	private func handleTwoFinger() {
		let d = twoFingerDistanceAndMidpoint()
		let mode = SettingsHandler.cursorMode
		if twoFingerMode == .undecided {
			let distDelta = abs(d.distance - startPinchDistance)
			let midDelta = hypot(d.midpoint.x - startTwoFingerMidpoint.x, d.midpoint.y - startTwoFingerMidpoint.y)
			let deadZone: CGFloat = 12.0
			if distDelta > deadZone || midDelta > deadZone {
				let pinching = distDelta > midDelta
				switch mode {
				case .touchpad:
					if pinching && zoomEnabled {
						twoFingerMode = .zoom
					} else if SettingsHandler.twoFingerDrag == .panView && scrollView.zoomScale > 1.01 {
						twoFingerMode = .pan
					} else {
						twoFingerMode = .scroll
					}
				case .direct:
					twoFingerMode = pinching ? .appZoom : .scroll
				case .twoFingerPanZoom:
					twoFingerMode = pinching ? .zoom : .pan
				case .threeFingerPanZoom:
					if activeTouches.count >= 3 {
						twoFingerMode = pinching ? .zoom : .pan
					} else {
						twoFingerMode = pinching ? .appZoom : .scroll
					}
				}
				if mode.isTouch && (twoFingerMode == .scroll || twoFingerMode == .appZoom) && !CParsec.mouseInfo.mousePositionRelative {
					// Windows scrolls / zooms whatever is under the pointer, so put it under the fingers
					cursorContentPos = clampToContent(contentView.convert(d.midpoint, from: view))
					CParsec.sendMousePosition(Int32(cursorContentPos.x), Int32(cursorContentPos.y))
					positionCursorOverlay()
				}
				if twoFingerMode == .appZoom {
					CParsec.sendKeyboardMessage(keyCode: 224, pressed: true)
					appZoomCtrlHeld = true
					appZoomAccum = 0
				}
				twoFingerDidMove = true
			}
		}
		switch twoFingerMode {
		case .zoom:
			if lastPinchDistance > 0 {
				applyZoom(to: scrollView.zoomScale * (d.distance / lastPinchDistance), anchorInView: d.midpoint)
			}
		case .appZoom:
			// Ctrl+wheel, the zoom every Windows app understands: one notch per ~12% of pinch
			if lastPinchDistance > 0 && d.distance > 0 {
				appZoomAccum += log(d.distance / lastPinchDistance)
				let step: CGFloat = 0.12
				while appZoomAccum > step {
					CParsec.sendWheelMsg(x: 0, y: 120)
					appZoomAccum -= step
				}
				while appZoomAccum < -step {
					CParsec.sendWheelMsg(x: 0, y: -120)
					appZoomAccum += step
				}
			}
		case .scroll:
			// Lock to the gesture's dominant axis so a vertical swipe doesn't drift sideways (and
			// the other way round); a clearly diagonal swipe scrolls both ways.
			let total = CGPoint(x: abs(d.midpoint.x - startTwoFingerMidpoint.x), y: abs(d.midpoint.y - startTwoFingerMidpoint.y))
			let deltaY = total.y >= total.x * 0.5 ? Float(d.midpoint.y - lastTwoFingerMidpoint.y) : 0
			let deltaX = total.x >= total.y * 0.5 ? Float(d.midpoint.x - lastTwoFingerMidpoint.x) : 0
			sendScroll(deltaX: deltaX, deltaY: deltaY)
		case .pan:
			panViewport(by: CGPoint(x: lastTwoFingerMidpoint.x - d.midpoint.x, y: lastTwoFingerMidpoint.y - d.midpoint.y))
		case .undecided:
			break
		}
		lastPinchDistance = d.distance
		lastTwoFingerMidpoint = d.midpoint
	}

	// finger movement (points) to wheel messages, natural direction, with flick momentum tracking
	private func sendScroll(deltaX: Float, deltaY: Float) {
		let direction: Float = SettingsHandler.reverseScrollDirection ? -1.0 : 1.0
		let contribution = deltaY * scrollWheelSpeed * direction
		accumulatedScrollY += contribution
		// natural scrolling: finger right = content right = wheel left
		accumulatedScrollX -= deltaX * scrollWheelSpeed * direction
		let intScrollY = Int32(accumulatedScrollY)
		let intScrollX = Int32(accumulatedScrollX)
		if intScrollY != 0 || intScrollX != 0 {
			CParsec.sendWheelMsg(x: intScrollX, y: intScrollY)
			accumulatedScrollY -= Float(intScrollY)
			accumulatedScrollX -= Float(intScrollX)
		}
		// Track scroll velocity for a little post-flick momentum.
		let snow = CACurrentMediaTime()
		let sdt = Float(snow - lastScrollMoveTime)
		if sdt > 0.0005 && sdt < 0.1 {
			scrollVelocity = scrollVelocity * 0.4 + (contribution / sdt) * 0.6
		}
		lastScrollMoveTime = snow
	}

	private func startCursorMomentum() {
		guard SettingsHandler.cursorMode == .touchpad, !CParsec.mouseInfo.mousePositionRelative else { return }
		guard CACurrentMediaTime() - lastCursorMoveTime < 0.06 else { return }   // finger was still moving at release
		guard hypot(cursorVelocity.x, cursorVelocity.y) > flingMinSpeed else { return }
		// Less glide when zoomed out: at 1x the cursor crosses the screen instead of panning the view.
		let glideScale = min(1.0, 0.3 + 0.7 * (scrollView.zoomScale - 1.0))
		cursorVelocity.x *= glideScale
		cursorVelocity.y *= glideScale
		cursorMomentumActive = true
		ensureMomentumLink()
	}

	private func startScrollMomentum() {
		guard CACurrentMediaTime() - lastScrollMoveTime < 0.06 else { return }
		guard abs(scrollVelocity) > scrollStartSpeed else { return }
		scrollMomentumActive = true
		ensureMomentumLink()
	}

	private func ensureMomentumLink() {
		if momentumLink == nil {
			let link = CADisplayLink(target: self, selector: #selector(momentumTick(_:)))
			link.add(to: .main, forMode: .common)
			momentumLink = link
		}
	}

	func stopMomentum() {
		cursorMomentumActive = false
		scrollMomentumActive = false
		edgeScrollActive = false
		cursorVelocity = .zero
		scrollVelocity = 0
		momentumLink?.invalidate()
		momentumLink = nil
	}

	@objc func momentumTick(_ link: CADisplayLink) {
		let dt = CGFloat(link.targetTimestamp - link.timestamp)
		if dt <= 0 { return }
		var stillActive = false

		if cursorMomentumActive {
			let decay = CGFloat(pow(cursorDecayPerSec, Double(dt)))
			cursorVelocity.x *= decay
			cursorVelocity.y *= decay
			let before = cursorContentPos
			cursorContentPos = clampToContent(CGPoint(x: cursorContentPos.x + cursorVelocity.x * dt,
													  y: cursorContentPos.y + cursorVelocity.y * dt))
			if !CParsec.mouseInfo.mousePositionRelative {
				CParsec.sendMousePosition(Int32(cursorContentPos.x), Int32(cursorContentPos.y))
			}
			centerViewportOnCursorPos()
			positionCursorOverlay()
			let stalled = abs(cursorContentPos.x - before.x) < 0.05 && abs(cursorContentPos.y - before.y) < 0.05
			if hypot(cursorVelocity.x, cursorVelocity.y) < cursorStopSpeed || stalled {
				cursorMomentumActive = false
			} else {
				stillActive = true
			}
		}

		if scrollMomentumActive {
			scrollVelocity *= Float(pow(scrollDecayPerSec, Double(dt)))
			accumulatedScrollY += scrollVelocity * Float(dt)
			let i = Int32(accumulatedScrollY)
			if i != 0 {
				CParsec.sendWheelMsg(x: 0, y: i)
				accumulatedScrollY -= Float(i)
			}
			if abs(scrollVelocity) < scrollStopSpeed {
				scrollMomentumActive = false
			} else {
				stillActive = true
			}
		}

		if edgeScrollActive {
			let elapsed = edgeScrollLastTick > 0 ? min(CGFloat(link.timestamp - edgeScrollLastTick), 0.1) : dt
			edgeScrollLastTick = link.timestamp
			if stepEdgeScroll(elapsed) {
				stillActive = true
			} else {
				edgeScrollActive = false
			}
		}

		if !stillActive { stopMomentum() }
	}

	// Manually zoom the scroll view around a screen-space anchor (the pinch midpoint), keeping the
	// content point under the anchor fixed. Replaces the scroll view's own pinch recognizer.
	private func applyZoom(to targetScale: CGFloat, anchorInView anchor: CGPoint) {
		let oldZoom = scrollView.zoomScale
		let newZoom = min(max(targetScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
		guard abs(newZoom - oldZoom) > 0.0001 else { return }
		let off = scrollView.contentOffset
		let contentX = (anchor.x + off.x) / oldZoom
		let contentY = (anchor.y + off.y) / oldZoom
		scrollView.zoomScale = newZoom
		setPanHandleAxes()
		if pinnedToKeyboard {
			pinnedToKeyboard = false
			scrollView.contentInset.top = 0
			keyboardCoversPicture = keyboardHeight > 0
			updatePanHandle()
		}
		var newOff = CGPoint(x: contentX * newZoom - anchor.x, y: contentY * newZoom - anchor.y)
		let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
		let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
		newOff.x = min(max(0, newOff.x), maxX)
		newOff.y = min(max(0, newOff.y), maxY)
		scrollView.setContentOffset(newOff, animated: false)
		positionCursorOverlay()
		// the touch modes put the pointer under the finger, there's no cursor to keep in view
		guard SettingsHandler.cursorMode == .touchpad else { return }
		// Park the cursor at the viewport centre after zooming so a later drag doesn't snap the view.
		let bottomInset = keyboardVisible ? keyboardHeight : 0.0
		let centerX = (scrollView.bounds.width / 2 + scrollView.contentOffset.x) / newZoom
		let centerY = ((scrollView.bounds.height - bottomInset) / 2 + scrollView.contentOffset.y) / newZoom
		cursorContentPos = clampToContent(CGPoint(x: centerX, y: centerY))
		if !CParsec.mouseInfo.mousePositionRelative {
			CParsec.sendMousePosition(Int32(cursorContentPos.x), Int32(cursorContentPos.y))
		}
		positionCursorOverlay()
	}

	private func clampToContent(_ p: CGPoint) -> CGPoint {
		let w = view.bounds.width
		let h = view.bounds.height
		return CGPoint(x: min(max(0, p.x), w), y: min(max(0, p.y), h))
	}

	// Places the cursor overlay at the cursor's content position projected into screen space,
	// drawn at full Cursor Scale (no zoom division) so it stays crisp and constant-sized.
	func positionCursorOverlay() {
		guard let u = u else { return }
		let zoom = scrollView.zoomScale
		let off = scrollView.contentOffset
		let screenX = cursorContentPos.x * zoom - off.x
		let screenY = cursorContentPos.y * zoom - off.y
		let cs = CGFloat(SettingsHandler.cursorScale)
		let hotX = CGFloat(CParsec.mouseInfo.cursorHotX) * cs
		let hotY = CGFloat(CParsec.mouseInfo.cursorHotY) * cs
		let w = CGFloat(CParsec.mouseInfo.cursorWidth) * cs
		let h = CGFloat(CParsec.mouseInfo.cursorHeight) * cs
		u.frame = CGRect(x: screenX - hotX, y: screenY - hotY, width: w, height: h)
	}

	// a small tap on the glass confirms the click reached the PC without looking at the cursor
	func haptic(_ strong: Bool = false) {
		guard SettingsHandler.hapticFeedback else { return }
		(strong ? mediumImpact : lightImpact).impactOccurred()
	}

	@objc func handleSingleFingerTap(_ gestureRecognizer: UITapGestureRecognizer) {
		// Only click if the finger stayed put; a moved finger was a cursor nudge, not a tap.
		if cursorDidMoveThisTouch { return }
		if touchEmulatedThisTouch { return }   // the touch modes click on lift themselves
		let location = gestureRecognizer.location(in: gestureRecognizer.view)
		let adjustedLocation = contentView.convert(location, from: view)
		touchController.onTap(typeOfTap: 1, location: adjustedLocation)
		haptic()
		showClickRipple(at: cursorScreenPoint)
	}

	@objc func handleTwoFingerTap(_ gestureRecognizer: UITapGestureRecognizer) {
		// A two-finger TAP is a right click; if the fingers moved (pinch/scroll) it wasn't a tap.
		if twoFingerDidMove { return }
		// dont leak a right-click to the host while backgrounding (app switch) or after a disconnect
		guard UIApplication.shared.applicationState == .active,
			  ParsecBackgroundManager.shared.hasActiveConnection else { return }

		let location: CGPoint
		switch SettingsHandler.rightClickPosition {
		case .firstFinger:
			location = gestureRecognizer.location(ofTouch: 0, in: gestureRecognizer.view)
			case .secondFinger:
			location = gestureRecognizer.location(ofTouch: 1, in: gestureRecognizer.view)
		default:
			location = gestureRecognizer.location(in: gestureRecognizer.view)
		}

		let adjustedLocation = contentView.convert(location, from: view)
		touchController.onTap(typeOfTap: 3, location: adjustedLocation)
		haptic(true)
		showClickRipple(at: SettingsHandler.cursorMode.isTouch ? location : cursorScreenPoint, secondary: true)
	}

	@objc func handleThreeFinderTap(_ gestureRecognizer: UITapGestureRecognizer) {
		if twoFingerDidMove { return }   // the fingers moved or pinched the view, not a tap
		guard SettingsHandler.threeFingerTap == .middleClick else {
			setKeyboardVisible(!keyboardVisible)
			return
		}
		guard UIApplication.shared.applicationState == .active,
			  ParsecBackgroundManager.shared.hasActiveConnection else { return }
		let location = gestureRecognizer.location(in: gestureRecognizer.view)
		touchController.onTap(typeOfTap: 2, location: contentView.convert(location, from: view))
		haptic(true)
		showClickRipple(at: SettingsHandler.cursorMode.isTouch ? location : cursorScreenPoint, secondary: true)
	}

	@objc func handleThreeFingerSwipe(_ gestureRecognizer: UISwipeGestureRecognizer) {
		// in Three-Finger Pan & Zoom three fingers move the view instead
		if SettingsHandler.cursorMode == .threeFingerPanZoom { return }
		if gestureRecognizer.direction == .up {
			if !keyboardVisible { setKeyboardVisible(true) }
		} else if keyboardVisible {
			setKeyboardVisible(false)
		} else {
			// nothing to hide: bring up the stream menu instead, also when the buttons are hidden
			flushAllTouches()
			onMenuEdgeSwipe?()
		}
	}

	// Two-finger pan mode: drag the zoomed picture around instead of scrolling the PC.
	private func panViewport(by delta: CGPoint) {
		let bottomInset = keyboardVisible ? keyboardHeight : 0.0
		let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
		let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + bottomInset)
		let off = scrollView.contentOffset
		let next = CGPoint(x: min(max(0, off.x + delta.x), maxX), y: min(max(0, off.y + delta.y), maxY))
		guard next != off else { return }
		scrollView.setContentOffset(next, animated: false)
		if SettingsHandler.cursorMode == .touchpad {
			// park the cursor in the middle of what's visible now, as zooming does, so the next
			// one-finger move doesn't yank the view back to where the cursor used to be
			let zoom = scrollView.zoomScale
			cursorContentPos = clampToContent(CGPoint(x: (scrollView.bounds.width / 2 + next.x) / zoom,
													  y: ((scrollView.bounds.height - bottomInset) / 2 + next.y) / zoom))
			if !CParsec.mouseInfo.mousePositionRelative {
				CParsec.sendMousePosition(Int32(cursorContentPos.x), Int32(cursorContentPos.y))
			}
		}
		positionCursorOverlay()
	}

	private func startHoldIndicator(at point: CGPoint) {
		cancelHoldIndicator()
		// a game that captured the mouse has no visible cursor to put the circle under
		guard SettingsHandler.clickRipple, !CParsec.mouseInfo.mousePositionRelative else { return }
		let size: CGFloat = 56
		let circle = CAShapeLayer()
		circle.path = UIBezierPath(ovalIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)).cgPath
		circle.position = point
		circle.fillColor = UIColor.systemGray.withAlphaComponent(0.35).cgColor
		circle.strokeColor = UIColor.systemGray.withAlphaComponent(0.85).cgColor
		circle.lineWidth = 2
		circle.opacity = 0
		view.layer.addSublayer(circle)

		// waits a moment (a plain tap never shows it), then fills in exactly as the hold completes
		let grow = CABasicAnimation(keyPath: "transform.scale")
		grow.fromValue = 0.2
		grow.toValue = 1.0
		let show = CABasicAnimation(keyPath: "opacity")
		show.fromValue = 0.0
		show.toValue = 1.0
		let group = CAAnimationGroup()
		group.animations = [grow, show]
		group.beginTime = circle.convertTime(CACurrentMediaTime(), from: nil) + holdIndicatorDelay
		group.duration = holdToDragDuration - holdIndicatorDelay
		group.timingFunction = CAMediaTimingFunction(name: .easeOut)
		group.fillMode = .both
		group.isRemovedOnCompletion = false
		circle.add(group, forKey: "hold")
		holdIndicator = circle
	}

	private func cancelHoldIndicator() {
		holdIndicator?.removeFromSuperlayer()
		holdIndicator = nil
	}

	// where the cursor is drawn on screen right now (zoom and pan applied)
	var cursorScreenPoint: CGPoint {
		let zoom = scrollView.zoomScale
		let off = scrollView.contentOffset
		return CGPoint(x: cursorContentPos.x * zoom - off.x, y: cursorContentPos.y * zoom - off.y)
	}

	// A quick ring that pops where a click landed, so you see that (and where) it clicked even when
	// the host cursor is tiny or hidden. Accent blue for right / middle clicks and drags.
	func showClickRipple(at point: CGPoint, secondary: Bool = false) {
		guard SettingsHandler.clickRipple else { return }
		let color: UIColor = secondary ? .systemBlue : .white
		let size: CGFloat = 46
		let ring = CAShapeLayer()
		ring.path = UIBezierPath(ovalIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)).cgPath
		ring.position = point
		ring.fillColor = color.withAlphaComponent(0.22).cgColor
		ring.strokeColor = color.withAlphaComponent(0.9).cgColor
		ring.lineWidth = 2
		ring.shadowColor = UIColor.black.cgColor
		ring.shadowOpacity = 0.35
		ring.shadowRadius = 2
		ring.shadowOffset = .zero
		ring.opacity = 0   // the end state, the animation below runs from visible to this
		view.layer.addSublayer(ring)

		let grow = CABasicAnimation(keyPath: "transform.scale")
		grow.fromValue = 0.35
		grow.toValue = 1.0
		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = 1.0
		fade.toValue = 0.0
		let group = CAAnimationGroup()
		group.animations = [grow, fade]
		group.duration = 0.38
		group.timingFunction = CAMediaTimingFunction(name: .easeOut)
		CATransaction.begin()
		CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
		ring.add(group, forKey: "ripple")
		CATransaction.commit()
	}

	@objc func handleLongPress(_ gestureRecognizer: UIGestureRecognizer) {
		if touchEmulatedThisTouch && !clickHoldActive {
			return   // the touch modes turn a hold into a right click / drag themselves
		}
		switch gestureRecognizer.state {
		case .began:
			// Click-and-hold (file drag): hold the left button; the overlay keeps moving the cursor.
			cancelHoldIndicator()
			clickHoldActive = true
			CParsec.sendMouseClickMessage(ParsecMouseButton.init(rawValue: 1), true)
			// without this there's no way to tell the hold turned into a drag until the cursor moves
			haptic(true)
			showClickRipple(at: cursorScreenPoint, secondary: true)
		case .ended, .cancelled, .failed:
			releaseClickHoldIfNeeded()
		default:
			break
		}
	}

    // UIScrollViewDelegate
	func viewForZooming(in scrollView: UIScrollView) -> UIView? {
		return contentView
	}

	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		positionCursorOverlay()
	}

	func scrollViewDidZoom(_ scrollView: UIScrollView) {
		// Centering is handled on cursor movement (updateImage) and at the end of a pinch.
	}

	func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
		centerViewportOnCursorPos()
	}

	func keepCursorAboveKeyboard() {
		guard scrollView.zoomScale <= 1.0, keyboardVisible, scrollView.contentInset.bottom > 0, !pinnedToKeyboard,
			  !SettingsHandler.cursorMode.isTouch, let cursor = u, !cursor.isHidden else { return }
		let visibleBottom = view.bounds.height - keyboardHeight
		let margin = min(50, max(0, (visibleBottom - cursor.frame.height) / 2 - 1))
		let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
		var target = scrollView.contentOffset.y
		if cursor.frame.maxY > visibleBottom - margin {
			target += cursor.frame.maxY - (visibleBottom - margin)
		} else if cursor.frame.minY < margin {
			target -= margin - cursor.frame.minY
		}
		target = min(max(0, target), maxOffsetY)
		guard target != scrollView.contentOffset.y else { return }
		scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
		positionCursorOverlay()
	}

	// Slides the viewport so the host cursor stays centered on screen while zoomed in,
	// clamped so the cursor can still reach the true edges of the host screen.
	func centerViewportOnCursorPos() {
		guard scrollView.zoomScale > 1.0 else { return }
		let zoom = scrollView.zoomScale
		let bottomInset = keyboardVisible ? keyboardHeight : 0.0
		let visibleWidth = view.bounds.width
		let visibleHeight = view.bounds.height - bottomInset
		let cursorX = cursorContentPos.x * zoom
		let cursorY = cursorContentPos.y * zoom
		var targetX = cursorX - visibleWidth / 2
		var targetY = cursorY - visibleHeight / 2
		let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
		let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + bottomInset)
		targetX = min(max(0, targetX), maxX)
		targetY = min(max(0, targetY), maxY)
		scrollView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: false)
	}

	private func edgeScrollVelocity(at p: CGPoint) -> CGPoint {
		guard scrollView.zoomScale > 1.0 else { return .zero }
		let visibleHeight = view.bounds.height - (keyboardVisible ? keyboardHeight : 0.0)
		func axis(_ v: CGFloat, _ length: CGFloat) -> CGFloat {
			if v < edgeScrollMargin {
				return -min(1, (edgeScrollMargin - v) / edgeScrollMargin) * edgeScrollMaxSpeed
			}
			if v > length - edgeScrollMargin {
				return min(1, (v - (length - edgeScrollMargin)) / edgeScrollMargin) * edgeScrollMaxSpeed
			}
			return 0
		}
		return CGPoint(x: axis(p.x, view.bounds.width), y: axis(p.y, visibleHeight))
	}

	private func stepEdgeScroll(_ dt: CGFloat) -> Bool {
		let v = edgeScrollVelocity(at: edgeScrollPoint)
		guard v != .zero, !CParsec.mouseInfo.mousePositionRelative else { return false }
		let bottomInset = keyboardVisible ? keyboardHeight : 0.0
		let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
		let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + bottomInset)
		let off = scrollView.contentOffset
		let next = CGPoint(x: min(max(0, off.x + v.x * dt), maxX), y: min(max(0, off.y + v.y * dt), maxY))
		guard next != off else { return false }
		scrollView.setContentOffset(next, animated: false)
		cursorContentPos = clampToContent(contentView.convert(edgeScrollPoint, from: view))
		CParsec.sendMousePosition(Int32(cursorContentPos.x), Int32(cursorContentPos.y))
		positionCursorOverlay()
		return true
	}

	// back to the whole picture without turning pinch-zoom off
	func resetZoom() {
		guard scrollView.zoomScale > 1.0 else { return }
		UIView.animate(withDuration: 0.25, animations: {
			self.scrollView.zoomScale = 1.0
			self.scrollView.contentOffset = .zero
		}, completion: { _ in
			self.setPanHandleAxes()
			self.positionCursorOverlay()
		})
	}

	func setZoomEnabled(_ enabled: Bool) {
		// Pinch is driven manually in touchOverlay; just gate it with this flag.
		zoomEnabled = enabled
		guard !enabled, scrollView.zoomScale > 1.0 else { return }
		UIView.animate(withDuration: 0.25, animations: {
			self.scrollView.zoomScale = 1.0
			self.scrollView.contentOffset = .zero
		}, completion: { _ in
			self.positionCursorOverlay()
		})
	}

}

extension ParsecViewController: UIPointerInteractionDelegate {
	func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
		return UIPointerStyle.hidden()
	}

	func pointerInteraction(_ inter: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
		let loc = request.location
		if let iv = view!.hitTest(loc, with: nil) {
			let rect = view!.convert(iv.bounds, from: iv)
			let region = UIPointerRegion(rect: rect, identifier: iv.tag)
			return region
		}
		return nil
	}

}

class KeyboardButton: UIButton {
	let keyText: String
	let isToggleable: Bool
	var isOn = false

	// on Liquid Glass the keys are light tinted pills sitting on the glass bar, a latched
	// modifier glows in the accent colour; before iOS 26 it's the classic black / grey keys
	func applyStyle() {
		if supportsLiquidGlass {
			backgroundColor = isOn ? UIColor.systemBlue.withAlphaComponent(0.45) : UIColor.label.withAlphaComponent(0.08)
			setTitleColor(.label, for: .normal)
			layer.cornerRadius = 18
		} else {
			backgroundColor = isOn ? .lightGray : .black
			setTitleColor(.white, for: .normal)
			layer.cornerRadius = 6
		}
		layer.cornerCurve = .continuous
	}

	required init(keyText: String, isToggleable: Bool) {
		self.keyText = keyText
		self.isToggleable = isToggleable
		super.init(frame: .zero)
		addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
		addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchDragExit, .touchCancel])

	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// Add a press-down animation for feedback
	@objc private func handleTouchDown() {
		self.alpha = 0.5
	}

	// Restore to normal state when touch ends
	@objc private func handleTouchUp() {
		UIView.animate(withDuration: 0.2) {
			self.alpha = 1.0
		}
	}
}

// MARK: - Virtual Keyboard
extension ParsecViewController: UIKeyInput, UITextInputTraits {
	var hasText: Bool {
		return true
	}

	var keyboardType: UIKeyboardType {
		get {
			return .asciiCapable
		}
		set {

		}
	}

	// passthrough keyboard: send raw input, dont let iOS autocorrect / smart-substitute / inject text
	var autocorrectionType: UITextAutocorrectionType {
		get { .no }
		set { }
	}
	var spellCheckingType: UITextSpellCheckingType {
		get { .no }
		set { }
	}
	var smartQuotesType: UITextSmartQuotesType {
		get { .no }
		set { }
	}
	var smartDashesType: UITextSmartDashesType {
		get { .no }
		set { }
	}
	var smartInsertDeleteType: UITextSmartInsertDeleteType {
		get { .no }
		set { }
	}
	var autocapitalizationType: UITextAutocapitalizationType {
		get { .none }
		set { }
	}

	override var canBecomeFirstResponder: Bool {
		return true
	}

	func insertText(_ text: String) {
		CParsec.sendVirtualKeyboardInput(text: text)
	}

	func deleteBackward() {
		CParsec.sendVirtualKeyboardInput(text: "BACKSPACE")
	}

    // copied from moonlight https://github.com/moonlight-stream/moonlight-ios/blob/022352c1667788d8626b659d984a290aa5c25e17/Limelight/Input/StreamView.m#L393
	override var inputAccessoryView: UIView? {

		if let keyboardAccessoriesView {
			if keyBarBuiltWithExtraRow == SettingsHandler.extraKeysRow {
				return keyboardAccessoriesView
			}
			// the Extra Keys Row setting changed: rebuild, letting go of any latched modifier first
			clearToolbarModifiers(sendToHost: true)
			self.keyboardAccessoriesView = nil
		}
		let extraRow = SettingsHandler.extraKeysRow
		keyBarBuiltWithExtraRow = extraRow
		extraKeyScrollView = nil
        // Refactored to UIView with autoresizing mask for better landscape support
        // Using frame-based layout for the container to avoid constraint conflicts with keyboard
		let containerView = AccessoryContainerView(frame: CGRect(x: 0, y: 0, width: self.view.bounds.width, height: 94))
        containerView.autoresizingMask = [.flexibleWidth]
        containerView.backgroundColor = .clear

		// Use a simple UIView instead of UIToolbar to avoid constraint conflicts
		let toolbarBackground = UIView(frame: CGRect(x: 0, y: 50, width: containerView.bounds.width, height: 44))
		toolbarBackground.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
		toolbarBackground.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
		applyLiquidGlass(toKeyBar: toolbarBackground, in: containerView, y: 50)

		let scrollView = UIScrollView(frame: CGRect(x: 8, y: 0, width: toolbarBackground.bounds.width - 80, height: 44))
		scrollView.autoresizingMask = [.flexibleWidth]
		scrollView.showsHorizontalScrollIndicator = false

		let buttonStackView = UIStackView()
		buttonStackView.axis = .horizontal
		buttonStackView.distribution = .equalSpacing
		buttonStackView.alignment = .center
		buttonStackView.spacing = 8
		buttonStackView.translatesAutoresizingMaskIntoConstraints = false

		// named keys: ⌃ ⌥ ⌘ mean nothing to most Windows users. A modifier stays held (lit up)
		// until it's tapped again, so Ctrl, Alt, Shift and Win combine with any other key.
		let mac = SettingsHandler.optionAsCommand
		let shiftBarButton = createKeyboardButton(displayText: "Shift", keyText: "SHIFT", isToggleable: true)
		let windowsBarButton = createKeyboardButton(displayText: mac ? "Cmd" : "Win", keyText: "LGUI", isToggleable: true)
		let tabBarButton = createKeyboardButton(displayText: "Tab", keyText: "TAB", isToggleable: false)
		let escapeBarButton = createKeyboardButton(displayText: "Esc", keyText: "UIKeyInputEscape", isToggleable: false)
		let controlBarButton = createKeyboardButton(displayText: "Ctrl", keyText: "CONTROL", isToggleable: true)
		let altBarButton = createKeyboardButton(displayText: mac ? "Opt" : "Alt", keyText: "LALT", isToggleable: true)
		let deleteBarButton = createKeyboardButton(displayText: "Del", keyText: "DELETE", isToggleable: false)
		let f1Button = createKeyboardButton(displayText: "F1", keyText: "F1", isToggleable: false)
		let f2Button = createKeyboardButton(displayText: "F2", keyText: "F2", isToggleable: false)
		let f3Button = createKeyboardButton(displayText: "F3", keyText: "F3", isToggleable: false)
		let f4Button = createKeyboardButton(displayText: "F4", keyText: "F4", isToggleable: false)
		let f5Button = createKeyboardButton(displayText: "F5", keyText: "F5", isToggleable: false)
		let f6Button = createKeyboardButton(displayText: "F6", keyText: "F6", isToggleable: false)
		let f7Button = createKeyboardButton(displayText: "F7", keyText: "F7", isToggleable: false)
		let f8Button = createKeyboardButton(displayText: "F8", keyText: "F8", isToggleable: false)
		let f9Button = createKeyboardButton(displayText: "F9", keyText: "F9", isToggleable: false)
		let f10Button = createKeyboardButton(displayText: "F10", keyText: "F10", isToggleable: false)
		let f11Button = createKeyboardButton(displayText: "F11", keyText: "F11", isToggleable: false)
		let f12Button = createKeyboardButton(displayText: "F12", keyText: "F12", isToggleable: false)
		let upButton = createKeyboardButton(displayText: "↑", keyText: "UP", isToggleable: false)
		let downButton = createKeyboardButton(displayText: "↓", keyText: "DOWN", isToggleable: false)
		let leftButton = createKeyboardButton(displayText: "←", keyText: "LEFT", isToggleable: false)
		let rightButton = createKeyboardButton(displayText: "→", keyText: "RIGHT", isToggleable: false)

		// one-tap shortcuts; PRIMARY is Ctrl on a PC host and Cmd on a Mac host (see resolveComboKey)
		let shortcutButtons = [
			createKeyboardButton(displayText: "Copy", keyText: "PRIMARY+C", isToggleable: false),
			createKeyboardButton(displayText: "Paste", keyText: "PRIMARY+V", isToggleable: false),
			createKeyboardButton(displayText: "Cut", keyText: "PRIMARY+X", isToggleable: false),
			createKeyboardButton(displayText: "Undo", keyText: "PRIMARY+Z", isToggleable: false),
			createKeyboardButton(displayText: "All", keyText: "PRIMARY+A", isToggleable: false),
			createKeyboardButton(displayText: "Alt+Tab", keyText: "SWITCHER+TAB", isToggleable: false),
			createKeyboardButton(displayText: "Desktop", keyText: "LGUI+D", isToggleable: false),
			createKeyboardButton(displayText: "Task Mgr", keyText: "CONTROL+SHIFT+UIKeyInputEscape", isToggleable: false)
		]
		let navButtons = [
			createKeyboardButton(displayText: "Home", keyText: "HOME", isToggleable: false),
			createKeyboardButton(displayText: "End", keyText: "END", isToggleable: false),
			createKeyboardButton(displayText: "PgUp", keyText: "PAGEUP", isToggleable: false),
			createKeyboardButton(displayText: "PgDn", keyText: "PAGEDOWN", isToggleable: false)
		]

		let specialKeys = [escapeBarButton, tabBarButton, controlBarButton, altBarButton, shiftBarButton, windowsBarButton, deleteBarButton, leftButton, upButton, downButton, rightButton]
		let fKeys = [f1Button, f2Button, f3Button, f4Button, f5Button, f6Button, f7Button, f8Button, f9Button, f10Button, f11Button, f12Button]
		// with the extra row the special keys get a line of their own, always one swipe away from
		// the keyboard; without it everything shares the one bar as before
		let buttons = extraRow ? shortcutButtons + fKeys + navButtons : specialKeys + shortcutButtons + fKeys + navButtons
		if extraRow {
			let extraBar = UIView(frame: CGRect(x: 0, y: 0, width: containerView.bounds.width, height: 44))
			extraBar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
			extraBar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
			applyLiquidGlass(toKeyBar: extraBar, in: containerView, y: 0)
			let extraScroll = UIScrollView(frame: CGRect(x: 8, y: 0, width: extraBar.bounds.width - 16, height: 44))
			extraScroll.showsHorizontalScrollIndicator = false
			let extraStack = UIStackView(arrangedSubviews: specialKeys)
			extraStack.axis = .horizontal
			extraStack.alignment = .center
			extraStack.spacing = 6
			extraStack.translatesAutoresizingMaskIntoConstraints = false
			extraScroll.addSubview(extraStack)
			NSLayoutConstraint.activate([
				extraStack.leadingAnchor.constraint(equalTo: extraScroll.contentLayoutGuide.leadingAnchor),
				extraStack.trailingAnchor.constraint(equalTo: extraScroll.contentLayoutGuide.trailingAnchor),
				extraStack.topAnchor.constraint(equalTo: extraScroll.contentLayoutGuide.topAnchor),
				extraStack.bottomAnchor.constraint(equalTo: extraScroll.contentLayoutGuide.bottomAnchor),
				extraStack.heightAnchor.constraint(equalTo: extraScroll.frameLayoutGuide.heightAnchor)
			])
			extraBar.addSubview(extraScroll)
			containerView.addSubview(extraBar)
			extraKeyScrollView = extraScroll
		}

		for button in buttons {
			buttonStackView.addArrangedSubview(button)
		}

		scrollView.addSubview(buttonStackView)

		// Set constraints for the stack view inside the scroll view
		NSLayoutConstraint.activate([
			buttonStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
			buttonStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
			buttonStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
			buttonStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
			buttonStackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
		])

		// Done button with frame-based layout
		let doneButton = UIButton(type: .system)
		doneButton.frame = CGRect(x: toolbarBackground.bounds.width - 70, y: 0, width: 60, height: 44)
		doneButton.autoresizingMask = [.flexibleLeftMargin]
		doneButton.setTitle("Done", for: .normal)
		doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

		let handle = UIImageView(image: UIImage(systemName: "arrow.up.and.down"))
		handle.frame = CGRect(x: 4, y: 0, width: 40, height: 44)
		handle.contentMode = .center
		handle.tintColor = .label
		handle.isUserInteractionEnabled = true
		handle.isHidden = true
		handle.isAccessibilityElement = true
		handle.accessibilityLabel = "Move screen up or down"
		handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePanHandle(_:))))
		let handleDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handlePanHandleDoubleTap(_:)))
		handleDoubleTap.numberOfTapsRequired = 2
		handle.addGestureRecognizer(handleDoubleTap)
		panHandle = handle
		keyScrollView = scrollView
		keyBarDone = doneButton
		containerView.onLayout = { [weak self] in self?.layoutKeyBar() }

		toolbarBackground.addSubview(scrollView)
		toolbarBackground.addSubview(handle)
		toolbarBackground.addSubview(doneButton)

		containerView.addSubview(toolbarBackground)

		keyboardAccessoriesView = containerView
		return containerView
	}

	func createKeyboardButton(displayText: String, keyText: String, isToggleable: Bool) -> UIButton {
		let button = KeyboardButton(keyText: keyText, isToggleable: isToggleable)

		// bigger, padded keys: the old 36pt / 10pt-font keys were easy to miss on a phone
		button.setTitle(displayText, for: .normal)
		button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
		button.titleLabel?.textAlignment = .center
		button.applyStyle()
		button.accessibilityLabel = displayText
		// padding goes into the intrinsic size the stack view lays out with
		button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
		button.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
			button.heightAnchor.constraint(equalToConstant: 36)
		])

		// Set target and action for button
		button.addTarget(self, action: #selector(toolbarButtonClicked(_:)), for: .touchUpInside)

		return button
	}

	@objc private func inputWasReleased() {
		clearToolbarModifiers(sendToHost: false)
	}

	private func clearToolbarModifiers(sendToHost: Bool) {
		guard let bar = keyboardAccessoriesView else { return }
		for button in toolbarButtons(in: bar) where button.isOn {
			button.isOn = false
			button.applyStyle()
			if sendToHost {
				CParsec.sendVirtualKeyboardInput(text: button.keyText, isOn: false)
			}
		}
	}

	private func toolbarButtons(in view: UIView) -> [KeyboardButton] {
		let own = (view as? KeyboardButton).map { [$0] } ?? []
		return own + view.subviews.flatMap { toolbarButtons(in: $0) }
	}

	// Mac hosts (Option as Command on) use Cmd where a PC uses Ctrl, and Cmd+Tab for the app switcher
	private func resolveComboKey(_ name: String) -> String {
		let mac = SettingsHandler.optionAsCommand
		switch name {
		case "PRIMARY": return mac ? "LGUI" : "CONTROL"
		case "SWITCHER": return mac ? "LGUI" : "LALT"
		default: return name
		}
	}

	// press every key of a shortcut in order, then let go in reverse, like a person would
	func sendKeyCombo(_ keyText: String) {
		let codes = keyText.split(separator: "+").compactMap { KeyCodeTranslators.parsecKeyCodeTranslator(resolveComboKey(String($0))) }
		guard !codes.isEmpty else { return }
		for code in codes {
			CParsec.sendKeyboardMessage(keyCode: code.rawValue, pressed: true)
		}
		// same short hold the virtual keys use, some apps ignore an instant release
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
			for code in codes.reversed() {
				CParsec.sendKeyboardMessage(keyCode: code.rawValue, pressed: false)
			}
		}
	}

	@objc func toolbarButtonClicked(_ sender: KeyboardButton) {
		haptic()
		if !sender.isToggleable && sender.keyText.contains("+") {
			sendKeyCombo(sender.keyText)
			return
		}
		let isToggleable = sender.isToggleable
		var isOn = sender.isOn

		if isToggleable {
			isOn.toggle()
		}

		sender.isOn = isOn
		sender.applyStyle()
		let keyText = sender.keyText

		if isToggleable {
			if isOn {
				CParsec.sendVirtualKeyboardInput(text: keyText, isOn: true)
			} else {
				CParsec.sendVirtualKeyboardInput(text: keyText, isOn: false)
			}
		} else {
			CParsec.sendVirtualKeyboardInput(text: keyText)
		}

	}

	// iOS 26+: the key bar becomes a floating Liquid Glass bar above the keyboard
	#if compiler(>=6.2)
	private func applyLiquidGlass(toKeyBar bar: UIView, in container: UIView, y: CGFloat) {
		guard #available(iOS 26.0, *) else { return }
		bar.frame = CGRect(x: 8, y: y, width: container.bounds.width - 16, height: 44)
		bar.backgroundColor = .clear
		let glass = UIVisualEffectView(effect: UIGlassEffect())
		glass.frame = bar.bounds
		glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		// glass picks its own rounded shape on iOS 26 (it ignores layer.cornerRadius), so no clipping
		// here, that would only cut off the edge highlights
		bar.insertSubview(glass, at: 0)
	}
	#else
	private func applyLiquidGlass(toKeyBar bar: UIView, in container: UIView, y: CGFloat) { }
	#endif

	@objc func doneTapped() {
		// Resign first responder to dismiss the keyboard
		resignFirstResponder()
	}

	// CRITICAL: This is the robust way to show the keyboard.
    // 1. Dispatch async to ensure view is attached to window.
    // 2. call reloadInputViews() to ensure updated accessory view (especially for rotation).
    // 3. call becomeFirstResponder().
    // 4. Do NOT simplify this to a synchronous call, or it will fail in some race conditions.
	func setKeyboardVisible(_ visible: Bool) {
		keyboardVisible = visible
		if visible {
            DispatchQueue.main.async {
                self.reloadInputViews()
                let success = self.becomeFirstResponder()
                if !success {
                   // Fallback: try again? or just log (can't log).
                   // Maybe ensure user interaction is on on window?
                }
            }
		} else {
			resignFirstResponder()
		}
	}

}

protocol ParsecTouchInputDelegate: AnyObject {
	// Called on every touch change with the authoritative set of currently-active touches.
	func parsecTouchesUpdated(_ activeTouches: Set<UITouch>, moved: Bool)
}

// A transparent overlay that owns every raw touch and forwards it to the controller. Sitting on
// top of (not inside) the scroll view, it gives deterministic, unfiltered touch delivery with no
// UIScrollView gesture races - the controller decides 1-finger cursor vs 2-finger pinch / scroll.
class TouchOverlayView: UIView {
	weak var inputDelegate: ParsecTouchInputDelegate?

	// Forward the live touch set (excluding ended/cancelled) on every event. External mouse /
	// trackpad input arrives as indirect-pointer touches but is handled entirely by GCMouse, so it's
	// dropped here — otherwise it warps the direct-mode cursor and fights touchpad-mode drags.
	private func forward(_ event: UIEvent?, moved: Bool) {
		let active = (event?.allTouches ?? []).filter { touch in
			guard touch.phase != .ended && touch.phase != .cancelled else { return false }
			if #available(iOS 13.4, *), touch.type == .indirectPointer { return false }
			return true
		}
		inputDelegate?.parsecTouchesUpdated(active, moved: moved)
	}
	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(event, moved: false) }
	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(event, moved: true) }
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(event, moved: false) }
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(event, moved: false) }
}

final class AccessoryContainerView: UIView {
	var onLayout: (() -> Void)?

	override func layoutSubviews() {
		super.layoutSubviews()
		onLayout?()
	}

	override func safeAreaInsetsDidChange() {
		super.safeAreaInsetsDidChange()
		setNeedsLayout()
	}

	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		subviews.contains { $0.frame.contains(point) }
	}
}
