import SwiftUI
import ParsecSDK
import Foundation
import AVFoundation

struct ParsecStatusBar: View {
	@Binding var showMenu: Bool
	@State var metricInfo: String = "Loading..."
	@Binding var showDCAlert: Bool
	@Binding var DCAlertText: String
	@Binding var isReconnecting: Bool
	@Binding var connectionLost: Bool
	@Binding var waitingForNetwork: Bool
	@Binding var waitingForStream: Bool
	@State var networkFailureSince: Date?
	@State var frameHeld = false
	@State var parsecViewController: ParsecViewController?
	@State var wasDisconnected: Bool = true
	@State var liveSince: CFTimeInterval?
	@State var seenInterfaceChanges = NetworkWatcher.shared.interfaceChanges
	let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
	let onSilentDisconnect: () -> Void

	init(showMenu: Binding<Bool>, showDCAlert: Binding<Bool>, DCAlertText: Binding<String>, parsecViewController: ParsecViewController, isReconnecting: Binding<Bool>, connectionLost: Binding<Bool>, waitingForNetwork: Binding<Bool>, waitingForStream: Binding<Bool>, onSilentDisconnect: @escaping () -> Void) {
		_showMenu = showMenu
		_showDCAlert = showDCAlert
		_DCAlertText = DCAlertText
		_isReconnecting = isReconnecting
		_connectionLost = connectionLost
		_waitingForNetwork = waitingForNetwork
		_waitingForStream = waitingForStream
		self.parsecViewController = parsecViewController
		self.onSilentDisconnect = onSilentDisconnect
	}

	var body: some View {
		// Overlay elements
		if showMenu || SettingsHandler.alwaysShowStatus {
			VStack {
				Text(metricInfo)
					.frame(minWidth: 200, maxWidth: .infinity, maxHeight: 20)
					.multilineTextAlignment(.leading)
					.font(.system(size: 10))
					.lineSpacing(20)
					.lineLimit(nil)
			}
			.liquidGlass(in: Rectangle(), fallback: Color("BackgroundPrompt").opacity(0.75))
			.foregroundColor(Color("Foreground"))
			.frame(maxHeight: .infinity, alignment: .top)
			.zIndex(1)
			.edgesIgnoringSafeArea(.all)

		}
		EmptyView()
			.onReceive(timer) { _ in
				poll()
			}
	}

	func holdFrame(_ hold: Bool) {
		var pumping = false
		if #available(iOS 15.0, *) { pumping = PictureInPictureManager.shared.isPumping }
		if hold {
			frameHeld = true
			if !pumping { ParsecBackgroundManager.shared.glkViewController?.isPaused = true }
		} else if frameHeld {
			frameHeld = false
			if !pumping { ParsecBackgroundManager.shared.glkViewController?.isPaused = false }
		}
	}

	func pictureBack() {
		guard isReconnecting, liveSince != nil else { return }
		ParsecBackgroundManager.shared.onNextFrame = nil
		liveSince = nil
		withAnimation(.easeOut(duration: 0.3)) {
			isReconnecting = false
			waitingForStream = false
		}
		appNote("[reconnect] picture back")
	}

	func poll() {
		if showDCAlert || ParsecBackgroundManager.shared.isPaused || ParsecBackgroundManager.shared.endedByUser {
			return
		}

		var pcs = ParsecClientStatus()
		var status = CParsec.getStatusEx(&pcs)

		var pipActive = false
		if #available(iOS 15.0, *) {
			pipActive = PictureInPictureManager.shared.isPiPActive
		}
		let offline = NetworkWatcher.shared.noNetwork

		if waitingForNetwork {
			if offline {
				holdFrame(true)
				return
			}
			waitingForNetwork = false
			ParsecBackgroundManager.shared.resumedAt = Date()
			if let peerId = ParsecBackgroundManager.shared.lastPeerId {
				let mgr = ParsecBackgroundManager.shared
				mgr.reconnectAttempts = 1
				appNote("[reconnect] network back, reconnecting")
				isReconnecting = true
				parsecViewController?.resetKeyState()
				CParsec.reconnect(peerId)
				mgr.reconnectStartTime = Date()
				return
			}
		}

		if status == PARSEC_OK && !isReconnecting && !pipActive {
			if offline {
				appNote("[stream] no network, not waiting on sdk")
				status = NETWORK_ERR_INTERRUPTED
			} else if SettingsHandler.autoReconnect && NetworkWatcher.shared.interfaceChanges != seenInterfaceChanges {
				appNote("[stream] network interface changed, reconnecting")
				status = NETWORK_ERR_INTERRUPTED
			}
		}
		seenInterfaceChanges = NetworkWatcher.shared.interfaceChanges

		if status == PARSEC_OK && pcs.networkFailure && !isReconnecting && !pipActive {
			if networkFailureSince == nil { networkFailureSince = Date() }
			let lost = Date().timeIntervalSince(networkFailureSince!)
			let justResumed = Date().timeIntervalSince(ParsecBackgroundManager.shared.resumedAt ?? .distantPast) < 10
			connectionLost = true
			if lost >= 3 || justResumed {
				networkFailureSince = nil
				connectionLost = false
				ParsecBackgroundManager.shared.resumedAt = nil
				status = NETWORK_ERR_INTERRUPTED
				appNote("[stream] network failure held, treating it as a lost connection")
			}
		} else {
			networkFailureSince = nil
			connectionLost = false
		}

		if status != PARSEC_OK {
			liveSince = nil
			waitingForStream = false
			ParsecBackgroundManager.shared.onNextFrame = nil
			holdFrame(true)
			if ParsecBackgroundManager.shared.isMarkedForReconnect {
				return
			}

			if offline && !pipActive {
				isReconnecting = false
				connectionLost = false
				if SettingsHandler.autoReconnect && ParsecBackgroundManager.shared.lastPeerId != nil {
					ParsecBackgroundManager.shared.reconnectAttempts = 0
					waitingForNetwork = true
					appNote("[stream] no network, waiting")
					return
				}
				appNote("[stream] ended, no network, alert")
				DCAlertText = "No network connection"
				showDCAlert = true
				return
			}

			let setupFailure = isReconnecting ? CParsec.setupError.flatMap { $0.at > ParsecBackgroundManager.shared.reconnectStartTime ? $0.line : nil } : nil

			if status == PARSEC_CONNECTING && isReconnecting && setupFailure == nil {
				if Date().timeIntervalSince(ParsecBackgroundManager.shared.reconnectStartTime) < 15 {
					return
				}
			}

			if status == CONNECT_WRN_APPROVAL && isReconnecting && setupFailure == nil {
				if Date().timeIntervalSince(ParsecBackgroundManager.shared.reconnectStartTime) < 60 {
					return
				}
			}

			// PiP: connection died (screen lock killed GPU). Kill connection+audio once,
			// subsequent polls exit via isMarkedForReconnect above.
			if pipActive {
				appNote("[stream] lost during picture in picture, status \(status.rawValue), reconnect owed")
				CParsec.disconnect()
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
				ParsecBackgroundManager.shared.connectionDidEnd()
				ParsecBackgroundManager.shared.markForReconnect()
				wasDisconnected = true
				return
			}

			if SettingsHandler.autoReconnect, !status.isPermanentFailure || (status == CONNECT_WRN_APPROVAL && setupFailure != nil), let peerId = ParsecBackgroundManager.shared.lastPeerId {
				let mgr = ParsecBackgroundManager.shared
				if mgr.reconnectAttempts < 3 {
					let gap: TimeInterval = mgr.reconnectAttempts == 0 ? 0 : mgr.reconnectAttempts == 1 ? 2 : 5
					if Date().timeIntervalSince(mgr.reconnectStartTime) < gap {
						return
					}
					mgr.reconnectAttempts += 1
					appNote("[reconnect] attempt \(mgr.reconnectAttempts) after status \(status.rawValue)\(setupFailure.map { ", sdk setup failed: \($0)" } ?? "")")
					isReconnecting = true
					parsecViewController?.resetKeyState()
					CParsec.reconnect(peerId)
					mgr.reconnectStartTime = Date()
					return
				}
				mgr.reconnectAttempts = 0
			}

			isReconnecting = false
			wasDisconnected = true
			let silent = SettingsHandler.autoReconnect && !SettingsHandler.errorPrompts && !status.isPermanentFailure
			appNote("[stream] ended, status \(status.rawValue), \(silent ? "silent" : "alert")")
			if silent {
				// silent: auto-reconnect spent its retries, dont nag with an alert
				onSilentDisconnect()
			} else {
				DCAlertText = status.readable()
				showDCAlert = true
			}
			return
		}

		holdFrame(connectionLost)

		if isReconnecting {
			if liveSince == nil {
				liveSince = CACurrentMediaTime()
				withAnimation(.easeInOut(duration: 0.2)) { waitingForStream = true }
				ParsecBackgroundManager.shared.onNextFrame = { pictureBack() }
				ParsecBackgroundManager.shared.reconnectAttempts = 0
				appNote("[reconnect] live again")
				ParsecView.getHostUserData()
				// SDK forgets stream dims on reconnect, re-send them so the frame fills not corners
				if let vc = parsecViewController {
					CParsec.setFrame(vc.view.bounds.width, vc.view.bounds.height, UIScreen.main.scale)
				}
			}
			if CParsec.runningRenderer != .metal || CACurrentMediaTime() - liveSince! > 6 {
				pictureBack()
			}
		}

		if showMenu || SettingsHandler.alwaysShowStatus {
			let str = String.fromBuffer(&pcs.decoder.0.name.0, length: 16)
			metricInfo = "Decode \(String(format: "%.2f", pcs.`self`.metrics.0.decodeLatency))ms    Encode \(String(format: "%.2f", pcs.`self`.metrics.0.encodeLatency))ms    Network \(String(format: "%.2f", pcs.`self`.metrics.0.networkLatency))ms    Bitrate \(String(format: "%.2f", pcs.`self`.metrics.0.bitrate))Mbps    RTx \(pcs.`self`.metrics.0.fastRTs + pcs.`self`.metrics.0.slowRTs)    Queue \(pcs.`self`.metrics.0.queuedFrames)    Draw \(String(format: "%.0f", CParsec.drawRate))fps \(CParsec.rendererName)    \(pcs.decoder.0.h265 ? "H265" : "H264") \(pcs.decoder.0.width)x\(pcs.decoder.0.height) \(pcs.decoder.0.color444 ? "4:4:4" : "4:2:0") \(str)"
		}
	}


}

// CRITICAL: This class exists to PERSIST the ParsecViewController instance across SwiftUI view updates.
// Do not remove or change to a struct. If ParsecViewController is recreated, the keyboard responder chain breaks.
class ParsecSession: ObservableObject {
    let controller: ParsecViewController

    init() {
        self.controller = ParsecViewController()
    }
}

struct MenuRowsHeightKey: PreferenceKey {
	static let defaultValue: CGFloat = 0

	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = max(value, nextValue())
	}
}

// one tile in the control panel
struct QuickAction: Identifiable {
	let id: String
	let icon: String
	let label: String
	var destructive: Bool = false
	var active: Bool = false
	let run: () -> Void
}

struct ParsecView: View {
	var controller: ContentView?

	@State var showDCAlert: Bool = false
	@State var DCAlertText: String = "Disconnected (reason unknown)"
	@State var metricInfo: String = "Loading..."

	@State var hideOverlay: Bool = false
	@State var hideKeyboardButton: Bool = false
	@AppStorage("keyboardHintShown") var keyboardHintShown: Bool = false
	@AppStorage("keyboardPanHintShown") var keyboardPanHintShown: Bool = false
	@State var hint: String?
	@State var showMenu: Bool = false
	@State var menuRowsHeight: CGFloat = 0
	@AppStorage("menuSwipeHintShown") var menuSwipeHintShown: Bool = false

	@State var showKeyboard: Bool = false
	@State var showModePicker: Bool = false
	@State var modeRowsHeight: CGFloat = 0
	@State var cursorModeAtOpen: CursorMode = .touchpad
	@State var zoomEnabled: Bool = false
	@Environment(\.verticalSizeClass) var verticalSizeClass

	@State var muted: Bool = false
	@State var preferH265: Bool = true
	@State var isReconnecting: Bool = false
	@State var connectionLost: Bool = false
	@State var showSettings: Bool = false
	@State var decoderAtOpen: DecoderPref = .h264
	@State var fpsAtOpen: Int = 0
	@State var pipAtOpen: Bool = false
	@State var resolutionAtOpen: ParsecResolution = .client
	@State var bitrateAtOpen: Int = 0
	@State var waitingForNetwork: Bool = false
	@State var waitingForStream: Bool = false

	@State var resolutions: [ParsecResolution]
	@State var bitrates: [Int]

    // Persist the VC across view updates using StateObject.
    // CRITICAL: Changing this to @State or a simple var will break the keyboard after menu interactions.
	@StateObject var session = ParsecSession()

    // Observer shared state for updates
    @ObservedObject var dataModel = DataManager.model
	@ObservedObject var settingsStore = SettingsStore.shared

    // Computed property for convenience refactoring
    var parsecViewController: ParsecViewController {
        return session.controller
    }

	// @State var showDisplays: Bool = false

	init(_ controller: ContentView?) {
		self.controller = controller

		_muted = State(initialValue: SettingsHandler.startMuted)
		_zoomEnabled = State(initialValue: SettingsHandler.zoomEnabled)
		_resolutions = State(initialValue: ParsecResolution.resolutions)
		_bitrates = State(initialValue: ParsecResolution.bitrates)

    }

    // We need to set up the callback somewhere safer than init.
    // 'onAppear' is a good place, or inside the init of ParsecSession if possible (but it doesn't have access to binding).
    // Let's use onAppear/post.

	var body: some View {
		ZStack {

			UIViewControllerWrapper(self.parsecViewController)
				.zIndex(1)
				.prefersPersistentSystemOverlaysHidden()

			ParsecStatusBar(showMenu: $showMenu, showDCAlert: $showDCAlert, DCAlertText: $DCAlertText, parsecViewController: parsecViewController, isReconnecting: $isReconnecting, connectionLost: $connectionLost, waitingForNetwork: $waitingForNetwork, waitingForStream: $waitingForStream, onSilentDisconnect: { disconnect() })

			if isReconnecting || connectionLost || waitingForNetwork {
				VStack(spacing: 12) {
					if waitingForNetwork {
						Image(systemName: "wifi.slash")
							.font(.system(size: 34, weight: .medium))
							.foregroundColor(.white)
					} else {
						ActivityIndicator(isAnimating: .constant(true), style: .large, tint: .white)
					}
					Text(overlayTitle)
						.font(.system(size: 16, weight: .medium))
						.foregroundColor(.white)
						.id(waitingForStream)
						.transition(.opacity)
					if waitingForNetwork {
						Text("OpenParsec will reconnect when you're back online")
							.font(.system(size: 13))
							.foregroundColor(.white)
							.opacity(0.7)
					}
					Button(action: { disconnect() }) {
						Text("Close")
							.font(.system(size: 15, weight: .semibold))
							.foregroundColor(.white)
							.padding(.horizontal, 20)
							.frame(minHeight: 44)
							.liquidGlass(in: glassRounded(8, glass: 22), interactive: true, fallback: Color.white.opacity(0.2))
					}
					.padding(.top, 4)
					if settingsStore.showConnectionLog {
						ConnectionLogPanel()
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color.black.opacity(0.6))
				.transition(.asymmetric(insertion: .identity, removal: .opacity))
				.zIndex(10)
			}

			if dataModel.isBlocked {
				Text("Host is using the machine")
					.foregroundColor(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
					.liquidGlass(in: glassRounded(8, glass: 20), tint: Color.black.opacity(0.3), fallback: Color("BackgroundPrompt").opacity(0.85))
					.zIndex(3)
			}

			if let hint = hint {
				Text(hint)
					.multilineTextAlignment(.center)
					.foregroundColor(.white)
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
					.liquidGlass(in: glassRounded(8, glass: 20), tint: Color.black.opacity(0.3), fallback: Color("BackgroundPrompt").opacity(0.85))
					.padding(.top, showKeyboard ? 100 : 0)
					.frame(maxHeight: .infinity, alignment: showKeyboard ? .top : .center)
					.allowsHitTesting(false)
					.zIndex(3)
			}

			if showMenu {
				// tap anywhere to fold the panel away again
				Color.black.opacity(0.2)
					.edgesIgnoringSafeArea(.all)
					.onTapGesture { setMenu(open: false) }
					.zIndex(4)
			}

			if !hideOverlay || showMenu {
				controlPanel
					.zIndex(5)
			}

			if showModePicker {
				modePicker
					.transition(.opacity.combined(with: .scale(scale: 0.96)))
					.zIndex(6)
			}
		}
		.statusBarHidden(SettingsHandler.hideStatusBar)
		.alert(isPresented: $showDCAlert) {
			Alert(title: Text(DCAlertText),
				  primaryButton: .default(Text("Reconnect"), action: {
					guard let peerId = ParsecBackgroundManager.shared.lastPeerId else {
						disconnect()
						return
					}
					if NetworkWatcher.shared.noNetwork {
						DispatchQueue.main.async {
							DCAlertText = "No network connection"
							showDCAlert = true
						}
						return
					}
					showDCAlert = false
					reconnectTo(peerId)
				  }),
				  secondaryButton: .cancel(Text("Close"), action: {disconnect()}))
		}
		.onChange(of: showSettings) { open in
			if !open { applyStreamSettings() }
		}
		.onChange(of: isReconnecting) { reconnecting in
			if !reconnecting {
				CParsec.setMuted(muted)
				if muted { CParsec.pause(video: false, audio: true) }
			}
		}
		.onAppear(perform: post)
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ParsecBackgroundDisconnect"))) { _ in
			if #available(iOS 15.0, *) {
				if PictureInPictureManager.shared.isPiPActive {
					return
				}
			}
			disconnect(isBackgroundDisconnect: true)
		}
		.edgesIgnoringSafeArea(.all)
		.overlay(SettingsView(visible: $showSettings))

	}

	// MARK: - Control panel
	// One button in the corner opens everything: the actions you reach for most as tiles on top,
	// the stream's own settings as rows under them, Disconnect at the bottom.

	var quickActions: [QuickAction] {
		let mode = settingsStore.cursorMode
		var list = [
			QuickAction(id: "keyboard", icon: "keyboard", label: "Keyboard", active: showKeyboard, run: toggleKeyboard),
			QuickAction(id: "mode", icon: mode.icon, label: mode.shortTitle, run: openModePicker),
			QuickAction(id: "cad", icon: "lock.shield", label: "Ctrl+Alt+Del", run: { parsecViewController.sendKeyCombo("CONTROL+LALT+DELETE") }),
			QuickAction(id: "start", icon: "square.grid.2x2", label: "Start", run: { parsecViewController.sendKeyCombo("LGUI") }),
			// asks the host to switch to this phone's screen size, so the desktop fills it edge to edge
			QuickAction(id: "resize", icon: "arrow.up.left.and.arrow.down.right", label: "Resize to Fit", run: { changeResolution(res: .client) })
		]
		// only the modes that can zoom the picture need a way back to the whole desktop
		if (mode == .touchpad && zoomEnabled) || mode == .twoFingerPanZoom || mode == .threeFingerPanZoom {
			list.append(QuickAction(id: "fit", icon: "arrow.down.right.and.arrow.up.left", label: "Fit to Screen", run: { parsecViewController.resetZoom() }))
		}
		return list
	}

	func setMenu(open: Bool) {
		if open {
			showModePicker = false
			ParsecView.getHostUserData()
		}
		withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
			showMenu = open
		}
	}

	func runQuickAction(_ action: QuickAction) {
		setMenu(open: false)
		action.run()
	}

	var controlPanel: some View {
		GeometryReader { proxy in
			let top = max(proxy.safeAreaInsets.top, 12) + 8
			let bottom = max(proxy.safeAreaInsets.bottom, 12) + 12
			let width = min(320, proxy.size.width - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing - 32)
			Group {
				if verticalSizeClass == .compact {
					// landscape: the panel sits beside the button, above it would not fit
					HStack(alignment: .bottom, spacing: 12) {
						if showMenu {
							panelCard(width: width, maxHeight: proxy.size.height - top - bottom)
								.transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
						}
						menuToggle
					}
				} else {
					VStack(alignment: .trailing, spacing: 12) {
						if showMenu {
							panelCard(width: width, maxHeight: proxy.size.height - top - bottom - 52 - 12)
								.transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
						}
						menuToggle
					}
				}
			}
			// the stream ignores the safe area, the button must not sit under the home bar or notch
			.padding(.trailing, proxy.safeAreaInsets.trailing + 16)
			.padding(.bottom, bottom)
			.frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
		}
	}

	var menuToggle: some View {
		Button(action: { setMenu(open: !showMenu) }) {
			Image(systemName: showMenu ? "xmark" : "ellipsis")
				.font(.system(size: 20, weight: .semibold))
				.foregroundColor(Color("Foreground"))
				.frame(width: 52, height: 52)
				.liquidGlass(in: Circle(), interactive: true, tint: showMenu ? Color("AccentColor").opacity(0.6) : nil, fallback: Color("BackgroundPrompt").opacity(0.85))
				.opacity(showMenu ? 1 : (supportsLiquidGlass ? 0.6 : 0.45))
		}
		.accessibilityLabel(Text(showMenu ? "Close menu" : "Menu"))
	}

	func panelCard(width: CGFloat, maxHeight: CGFloat) -> some View {
		ScrollView {
			VStack(spacing: 12) {
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
					ForEach(quickActions) { action in
						actionTile(action)
					}
				}
				VStack(spacing: 0) {
					streamRows
				}
				.background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color("Foreground").opacity(0.06)))
				Button(action: { setMenu(open: false); disconnect() }) {
					HStack(spacing: 8) {
						Image(systemName: "power")
						Text("Disconnect")
					}
					.font(.system(size: 15, weight: .semibold))
					.foregroundColor(.red)
					.frame(maxWidth: .infinity, minHeight: 44)
					.background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.14)))
					.contentShape(Rectangle())
				}
				.buttonStyle(PlainButtonStyle())
			}
			.padding(12)
			.background(GeometryReader { inner in
				Color.clear.preference(key: MenuRowsHeightKey.self, value: inner.size.height)
			})
		}
		.frame(width: width)
		.frame(maxHeight: min(menuRowsHeight, max(maxHeight, 160)))
		.onPreferenceChange(MenuRowsHeightKey.self) { menuRowsHeight = $0 }
		.foregroundColor(Color("Foreground"))
		.liquidGlass(in: glassRounded(14, glass: 28), fallback: Color("BackgroundPrompt").opacity(0.94))
	}

	func actionTile(_ action: QuickAction) -> some View {
		Button(action: { runQuickAction(action) }) {
			VStack(spacing: 6) {
				Image(systemName: action.icon)
					.font(.system(size: 19, weight: .medium))
					.foregroundColor(action.active ? .white : Color("Foreground"))
					.frame(width: 46, height: 46)
					.background(Circle().fill(action.active ? Color("AccentColor") : Color("Foreground").opacity(0.1)))
				Text(action.label)
					.font(.system(size: 11, weight: .medium))
					.lineLimit(2)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, minHeight: 84, alignment: .top)
			.padding(.top, 4)
			.contentShape(Rectangle())
		}
		.buttonStyle(PlainButtonStyle())
		.foregroundColor(Color("Foreground"))
		.accessibilityLabel(Text(action.label))
	}

	func panelRow(_ title: String, icon: String, value: String? = nil, chevron: Bool = false) -> some View {
		HStack(spacing: 12) {
			Image(systemName: icon)
				.font(.system(size: 15, weight: .medium))
				.foregroundColor(Color("AccentColor"))
				.frame(width: 22)
			Text(title)
				.lineLimit(1)
			Spacer(minLength: 6)
			if let value = value {
				Text(value)
					.lineLimit(1)
					.opacity(0.55)
			}
			if chevron {
				Image(systemName: "chevron.up.chevron.down")
					.font(.system(size: 11, weight: .semibold))
					.opacity(0.4)
			}
		}
		.font(.system(size: 15))
		.foregroundColor(Color("Foreground"))
		.padding(.horizontal, 12)
		.frame(minHeight: 44)
		.contentShape(Rectangle())
	}

	var currentResolutionLabel: String? {
		resolutions.first { $0.width == dataModel.resolutionX && $0.height == dataModel.resolutionY }?.desc
	}

	@ViewBuilder var streamRows: some View {
		Button(action: toggleMute) {
			panelRow("Sound", icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", value: muted ? "Off" : "On")
		}
		.buttonStyle(PlainButtonStyle())
		Menu {
			ForEach(resolutions, id: \.self) { resolution in
				Button(action: {
					changeResolution(res: resolution)
				}) {
					if resolution.width == dataModel.resolutionX && resolution.height == dataModel.resolutionY {
						Label(resolution.desc, systemImage: "checkmark")
					} else {
						Text(resolution.desc)
					}
				}
			}
		} label: {
			panelRow("Resolution", icon: "display", value: currentResolutionLabel, chevron: true)
		}
		Menu {
			Button(action: {
				changeBitRate(bitrate: 0)
			}) {
				if settingsStore.bitrate == 0 {
					Label("Host Default", systemImage: "checkmark")
				} else {
					Text("Host Default")
				}
			}
			ForEach(bitrates, id: \.self) { bitrate in
				Button(action: {
					changeBitRate(bitrate: bitrate)
				}) {
					if bitrate == settingsStore.bitrate {
						Label("\(bitrate) Mbps", systemImage: "checkmark")
					} else {
						Text("\(bitrate) Mbps")
					}
				}
			}
		} label: {
			panelRow("Bitrate", icon: "chart.bar.fill", value: settingsStore.bitrate == 0 ? "Default" : "\(settingsStore.bitrate) Mbps", chevron: true)
		}
		if DataManager.model.displayConfigs.count > 1 {
			Menu {
				Button("Auto") {
					changeDisplay(displayId: "none")
				}
				ForEach(DataManager.model.displayConfigs, id: \.self) { config in
					Button("\(config.name) \(config.adapterName)") {
						changeDisplay(displayId: config.id)
					}
				}
			} label: {
				panelRow("Switch Display", icon: "rectangle.on.rectangle", chevron: true)
			}
		}
		Button(action: toggleConstantFps) {
			panelRow("Constant Frame Rate", icon: "timer", value: dataModel.constantFps ? "On" : "Off")
		}
		.buttonStyle(PlainButtonStyle())
		if settingsStore.cursorMode == .touchpad {
			// the other touch modes always zoom the view (or never, in Direct Touch)
			Button(action: toggleZoom) {
				panelRow("Pinch to Zoom", icon: "plus.magnifyingglass", value: zoomEnabled ? "On" : "Off")
			}
			.buttonStyle(PlainButtonStyle())
		}
		Button(action: { setMenu(open: false); disableOverlay() }) {
			panelRow("Hide Button", icon: "eye.slash")
		}
		.buttonStyle(PlainButtonStyle())
		Button(action: openSettings) {
			panelRow("Settings", icon: "gearshape.fill")
		}
		.buttonStyle(PlainButtonStyle())
	}

	// MARK: - Touch input chooser
	// The four ways to drive the PC, the same set Chrome Remote Desktop has, each with what it does
	// so you can pick without trying them all.

	func openModePicker() {
		showMenu = false
		withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { showModePicker = true }
	}

	func closeModePicker() {
		withAnimation(.easeOut(duration: 0.2)) { showModePicker = false }
	}

	func setCursorMode(_ mode: CursorMode) {
		closeModePicker()
		guard SettingsHandler.cursorMode != mode else { return }
		SettingsHandler.cursorMode = mode
		HostPrefs.save(for: ParsecBackgroundManager.shared.lastPeerId)
		parsecViewController.applyCursorMode()
		UISelectionFeedbackGenerator().selectionChanged()
		withAnimation { hint = mode.title }
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
			if hint == mode.title { withAnimation { hint = nil } }
		}
	}

	var modePicker: some View {
		ZStack {
			Color.black.opacity(0.35)
				.edgesIgnoringSafeArea(.all)
				.onTapGesture(perform: closeModePicker)
			VStack(spacing: 0) {
				HStack(spacing: 10) {
					Image(systemName: "hand.point.up.left.fill")
						.font(.system(size: 15, weight: .semibold))
						.foregroundColor(Color("AccentColor"))
					Text("Touch Input")
						.font(.system(size: 17, weight: .semibold))
					Spacer()
					Button(action: closeModePicker) {
						Image(systemName: "xmark")
							.font(.system(size: 13, weight: .bold))
							.frame(width: 30, height: 30)
							.liquidGlass(in: Circle(), interactive: true, fallback: Color("Foreground").opacity(0.1))
					}
					.accessibilityLabel(Text("Close"))
				}
				.padding(.horizontal, 16)
				.padding(.top, 14)
				.padding(.bottom, 10)
				ScrollView {
					VStack(spacing: 8) {
						ForEach(CursorMode.allCases, id: \.self) { mode in
							modeRow(mode)
						}
					}
					.padding(.horizontal, 10)
					.padding(.bottom, 10)
					.background(GeometryReader { proxy in
						Color.clear.preference(key: MenuRowsHeightKey.self, value: proxy.size.height)
					})
				}
				.frame(maxHeight: modeRowsHeight)
				.onPreferenceChange(MenuRowsHeightKey.self) { modeRowsHeight = $0 }
			}
			.foregroundColor(Color("Foreground"))
			.liquidGlass(in: glassRounded(14, glass: 28), fallback: Color("BackgroundPrompt").opacity(0.95))
			.frame(maxWidth: 460)
			.padding(.horizontal, 16)
			.padding(.vertical, 20)
		}
	}

	func modeRow(_ mode: CursorMode) -> some View {
		let selected = settingsStore.cursorMode == mode
		let accent = Color("AccentColor")
		return Button(action: { setCursorMode(mode) }) {
			HStack(alignment: .center, spacing: 12) {
				Image(systemName: mode.icon)
					.font(.system(size: 18, weight: .medium))
					.foregroundColor(selected ? .white : accent)
					.frame(width: 42, height: 42)
					.background(Circle().fill(selected ? accent : accent.opacity(0.15)))
				VStack(alignment: .leading, spacing: 3) {
					Text(mode.title)
						.font(.system(size: 15, weight: .semibold))
					Text(mode.summary)
						.font(.system(size: 12))
						.opacity(0.7)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 4)
				Image(systemName: selected ? "checkmark.circle.fill" : "circle")
					.font(.system(size: 20))
					.foregroundColor(selected ? accent : Color("Foreground").opacity(0.25))
			}
			.multilineTextAlignment(.leading)
			.padding(12)
			.background(RoundedRectangle(cornerRadius: 16, style: .continuous)
				.fill(selected ? accent.opacity(0.14) : Color("Foreground").opacity(0.05)))
			.overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
				.stroke(selected ? accent.opacity(0.55) : Color.clear, lineWidth: 1.5))
			.contentShape(Rectangle())
		}
		.buttonStyle(PlainButtonStyle())
		.foregroundColor(Color("Foreground"))
		.accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
	}

	var overlayTitle: String {
		if waitingForNetwork {
			return "No network connection"
		}
		if !isReconnecting {
			return "Connection lost..."
		}
		if waitingForStream {
			return "Reconnected, waiting for the stream..."
		}
		return ParsecBackgroundManager.shared.lastHostname.map { "Reconnecting to \($0)..." } ?? "Reconnecting..."
	}

	func post() {
		ParsecBackgroundManager.shared.onShouldDisconnect = {
			NotificationCenter.default.post(name: NSNotification.Name("ParsecBackgroundDisconnect"), object: nil)
		}
		ParsecBackgroundManager.shared.onEndedInBackground = { [self] in
			ParsecBackgroundManager.shared.onNextFrame = nil
			waitingForStream = false
			if showDCAlert || waitingForNetwork { return }
			isReconnecting = true
		}
		ParsecBackgroundManager.shared.onResumeEndedSession = { [self] in
			if showDCAlert || waitingForNetwork { return }
			guard let peerId = ParsecBackgroundManager.shared.lastPeerId else { return }
			appNote("[reconnect] back from the background, reconnecting")
			reconnectTo(peerId)
			ParsecBackgroundManager.shared.reconnectAttempts = 1
		}
		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.onPiPStopped = { [self] in
				if UIApplication.shared.applicationState != .active {
					ParsecBackgroundManager.shared.glkViewController?.isPaused = true
					CParsec.sendReleaseMessage()
					CParsec.pause()
					ParsecBackgroundManager.shared.isPaused = true
					if UIApplication.shared.applicationState == .background {
						ParsecBackgroundManager.shared.holdSessionInBackground()
					}
				} else {
					if ParsecBackgroundManager.shared.isReconnecting {
						return
					}
					// Check actual Parsec status — timers don't reliably fire in background
					var pcs = ParsecClientStatus()
					let currentStatus = CParsec.getStatusEx(&pcs)
					if currentStatus != PARSEC_OK || ParsecBackgroundManager.shared.isMarkedForReconnect {
						CParsec.disconnect()
						try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
						ParsecBackgroundManager.shared.markForReconnect()
						DispatchQueue.main.async {
							self.disconnect(isBackgroundDisconnect: true)
						}
					}
				}
			}
			PictureInPictureManager.shared.onPiPStartFailed = {
				if UIApplication.shared.applicationState != .active {
					ParsecBackgroundManager.shared.glkViewController?.isPaused = true
					CParsec.sendReleaseMessage()
					CParsec.pause()
					ParsecBackgroundManager.shared.isPaused = true
					if UIApplication.shared.applicationState == .background {
						ParsecBackgroundManager.shared.holdSessionInBackground()
					}
				}
			}
		}

		CParsec.applyConfig()
		CParsec.setMuted(muted)
		if muted { CParsec.pause(video: false, audio: true) }
		parsecViewController.setZoomEnabled(zoomEnabled)

		DataManager.model.constantFps = SettingsHandler.constantFps

		let screenSize: CGSize = self.parsecViewController.view.frame.size
		let scaleFactor = UIScreen.main.nativeScale
		ParsecResolution.updateClientResolution(width: Int(screenSize.width * scaleFactor), height: Int(screenSize.height * scaleFactor))

		ParsecView.getHostUserData()

		hideOverlay = SettingsHandler.noOverlay
		hideKeyboardButton = hideOverlay
		parsecViewController.updateMenuEdgeSwipe(menuHidden: hideOverlay)
		offerHint()

		let overlayHidden = $hideOverlay
		let keyboardButtonHidden = $hideKeyboardButton
		let menuShown = $showMenu
		parsecViewController.onMenuEdgeSwipe = {
			overlayHidden.wrappedValue = false
			keyboardButtonHidden.wrappedValue = false
			withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { menuShown.wrappedValue = true }
			ParsecView.getHostUserData()
		}

        let keyboardShown = $showKeyboard
        parsecViewController.onKeyboardVisibilityChanged = { visible in
            keyboardShown.wrappedValue = visible
        }
		let hint = $hint
		let panHintShown = $keyboardPanHintShown
		parsecViewController.onKeyboardCoversPicture = {
			guard !panHintShown.wrappedValue else { return }
			panHintShown.wrappedValue = true
			withAnimation { hint.wrappedValue = "Part of the screen is under the keyboard\nDrag ↕\u{FE0E} to move it into view" }
			DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
				withAnimation { hint.wrappedValue = nil }
			}
		}

		parsecViewController.setKeyboardVisible(showKeyboard)
	}

	func openSettings() {
		decoderAtOpen = SettingsHandler.decoder
		fpsAtOpen = SettingsHandler.preferredFramesPerSecond
		pipAtOpen = SettingsHandler.enablePiP
		resolutionAtOpen = SettingsHandler.resolution
		bitrateAtOpen = SettingsHandler.bitrate
		cursorModeAtOpen = SettingsHandler.cursorMode
		showMenu = false
		if showKeyboard { toggleKeyboard() }
		withAnimation(.easeInOut(duration: 0.24)) { showSettings = true }
	}

	func applyStreamSettings() {
		zoomEnabled = SettingsHandler.zoomEnabled
		parsecViewController.setZoomEnabled(zoomEnabled)
		if SettingsHandler.cursorMode != cursorModeAtOpen {
			parsecViewController.applyCursorMode()
		}
		parsecViewController.updatePanHandle()
		parsecViewController.positionCursorOverlay()
		hideOverlay = SettingsHandler.noOverlay
		hideKeyboardButton = hideOverlay
		parsecViewController.updateMenuEdgeSwipe(menuHidden: hideOverlay)
		offerHint()

		var hostConfigChanged = false
		if SettingsHandler.resolution != resolutionAtOpen {
			DataManager.model.resolutionX = SettingsHandler.resolution.width
			DataManager.model.resolutionY = SettingsHandler.resolution.height
			hostConfigChanged = true
		}
		if SettingsHandler.constantFps != DataManager.model.constantFps {
			DataManager.model.constantFps = SettingsHandler.constantFps
			hostConfigChanged = true
		}
		if hostConfigChanged { CParsec.updateHostVideoConfig() }
		if SettingsHandler.bitrate != bitrateAtOpen { applyBitrate() }
		HostPrefs.save(for: ParsecBackgroundManager.shared.lastPeerId)
		if SettingsHandler.preferredFramesPerSecond != fpsAtOpen { parsecViewController.applyFrameRate() }
		if SettingsHandler.enablePiP != pipAtOpen {
			ParsecBackgroundManager.shared.reconnectPending = true
			disconnect()
		} else if SettingsHandler.decoder != decoderAtOpen {
			reconnectToApply()
		}
	}

	func reconnectToApply() {
		guard let peerId = ParsecBackgroundManager.shared.lastPeerId else { return }
		appNote("[reconnect] to apply settings")
		reconnectTo(peerId)
	}

	func reconnectTo(_ peerId: String) {
		isReconnecting = true
		ParsecBackgroundManager.shared.reconnectAttempts = 0
		parsecViewController.resetKeyState()
		CParsec.reconnect(peerId)
		ParsecBackgroundManager.shared.reconnectStartTime = Date()
	}

	func disableOverlay() {
		hideOverlay = true
		hideKeyboardButton = true
		showMenu = false
		parsecViewController.updateMenuEdgeSwipe(menuHidden: true)
		offerHint(always: true)
	}

	func offerHint(always: Bool = false) {
		let menu = hideOverlay && (always || !menuSwipeHintShown)
		let keyboard = hideKeyboardButton && (always || !keyboardHintShown)
		guard menu || keyboard else { return }
		if menu { menuSwipeHintShown = true }
		if keyboard { keyboardHintShown = true }
		let text = [menu ? "Swipe from the left edge for the menu" : nil, keyboard ? "Swipe up with three fingers for the keyboard, down to hide it" : nil].compactMap { $0 }.joined(separator: "\n")
		withAnimation { hint = text }
		DispatchQueue.main.asyncAfter(deadline: .now() + (menu && keyboard ? 6 : 4)) {
			withAnimation { hint = nil }
		}
	}

	func toggleMute() {
		muted.toggle()
		CParsec.setMuted(muted)
		if muted {
			CParsec.pause(video: false, audio: true)
		} else {
			CParsec.resume()
		}
	}

		/*func genDisplaySheet() -> ActionSheet
	{
		let len:Int = 16
		var outputs = [ParsecOutput?](repeating:nil, count:len)
		ParsecGetOutputs(&outputs, UInt32(len))
		print("Listing \(outputs.count) displays")

		func getDeviceName(_ output:ParsecOutput) -> String
		{
			return withUnsafePointer(to:output.device)
			{
				$0.withMemoryRebound(to: UInt8.self, capacity:MemoryLayout.size(ofValue:$0))
				{
					String(cString:$0)
				}
			}
		}

		let buttons = outputs.enumerated().map
		{ i, output in
			Alert.Button.default(Text("\(i) - \(getDeviceName(output))"), action:{print("Selected device \(i)")})
		}
		return ActionSheet(title: Text("Select a Display:"), buttons:buttons + [Alert.Button.cancel()])
	}*/

	func disconnect(isBackgroundDisconnect: Bool = false) {
		appNote("[stream] disconnect\(isBackgroundDisconnect ? " in the background" : "")")
		if !isBackgroundDisconnect {
			ParsecBackgroundManager.shared.endSession()
		}
		ParsecBackgroundManager.shared.onResumeEndedSession = nil
		ParsecBackgroundManager.shared.onEndedInBackground = nil
		ParsecBackgroundManager.shared.onNextFrame = nil

		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.teardown()
		}

		CParsec.sendReleaseMessage()
		CParsec.disconnect()
		DataManager.model.output = "none"
		CParsec.drawRate = 0
		self.parsecViewController.glkView.cleanUp()

		parsecViewController.scrollView.zoomScale = 1.0
		parsecViewController.scrollView.contentOffset = .zero

		if let c = controller {
			c.setView(.main)
		}
	}

	func changeResolution(res: ParsecResolution) {
        SettingsHandler.resolution = res
		HostPrefs.save(for: ParsecBackgroundManager.shared.lastPeerId)
		DispatchQueue.main.async {
			DataManager.model.resolutionX = res.width
			DataManager.model.resolutionY = res.height
			CParsec.updateHostVideoConfig()
		}
	}

	func changeBitRate(bitrate: Int) {
		SettingsHandler.bitrate = bitrate
		HostPrefs.save(for: ParsecBackgroundManager.shared.lastPeerId)
		applyBitrate()
	}

	func applyBitrate() {
		let target = SettingsHandler.bitrate > 0 ? SettingsHandler.bitrate : DataManager.model.hostDefaultBitrate
		guard target > 0, target != DataManager.model.bitrate else { return }
		DataManager.model.bitrate = target
		CParsec.updateHostVideoConfig()
	}

	func toggleConstantFps() {
		DispatchQueue.main.async {
			DataManager.model.constantFps.toggle()
			CParsec.updateHostVideoConfig()
			SettingsHandler.constantFps = DataManager.model.constantFps
		}
	}

	func toggleKeyboard() {
		DispatchQueue.main.async {
			showKeyboard.toggle()
			parsecViewController.setKeyboardVisible(showKeyboard)
		}
	}

	func toggleZoom() {
		DispatchQueue.main.async {
			zoomEnabled.toggle()
			parsecViewController.setZoomEnabled(zoomEnabled)
			SettingsHandler.zoomEnabled = zoomEnabled
		}
	}

	func changeDisplay(displayId: String) {
		DispatchQueue.main.async {
			DataManager.model.output = displayId
			CParsec.updateHostVideoConfig()
		}
	}

	static func getHostUserData() {
		let data = Data()
		CParsec.sendUserData(type: .getVideoConfig, message: data)
		CParsec.sendUserData(type: .getAdapterInfo, message: data)
	}

}

// from https://github.com/utmapp/UTM/blob/117e3a962f2f46f7d847632d65fa7a85a2bb0cfa/Platform/iOS/VMWindowView.swift#L314
private extension View {
	func prefersPersistentSystemOverlaysHidden() -> some View {
		if #available(iOS 16, *) {
			return self.persistentSystemOverlays(.hidden)
		} else {
			return self
		}
	}
}
