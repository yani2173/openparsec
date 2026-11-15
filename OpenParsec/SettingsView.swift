import SwiftUI

struct SettingsView: View {
	@Binding var visible: Bool
	@ObservedObject private var settings = SettingsStore.shared

	let resolutionChoices: [Choice<ParsecResolution>]

	init(visible: Binding<Bool>) {
		_visible = visible
		var tmp: [Choice<ParsecResolution>] = []
		for res in ParsecResolution.resolutions {
			tmp.append(Choice(res.desc, res))
		}
		resolutionChoices = tmp
	}

	var body: some View {
		ZStack {
			if visible {
				// Background
				Rectangle()
					.fill(Color.init(red: 0, green: 0, blue: 0, opacity: 0.67))
					.edgesIgnoringSafeArea(.all)
			}
		}

		ZStack {
			if visible {
				// Main controls
				VStack {
					// Navigation controls
					ZStack {
						// iOS 26+: no header strip, the glass close button sits straight on the panel
						// (glass on top of glass is what Apple's guidelines say to avoid)
						Rectangle()
							.fill(supportsLiquidGlass ? Color.clear : Color("BackgroundTab"))
							.frame(height: 52)
							.shadow(color: supportsLiquidGlass ? .clear : Color("Shading"), radius: 4, y: 6)
						ZStack {
							HStack {
								Button(action: saveAndExit, label: {
									Image(systemName: "xmark")
										.scaleEffect(x: -1)
										.frame(width: 36, height: 36)
										.liquidGlass(in: Circle(), interactive: true, fallback: .clear)
								})
								 .padding(.horizontal, 8)
								Spacer()
							}
							Text("Settings")
								.multilineTextAlignment(.center)
								.foregroundColor(Color("Foreground"))
								.font(.system(size: 20, weight: .medium))
							Spacer()
						}
						.foregroundColor(Color("AccentColor"))
					}
					.zIndex(1)

					ScrollView {
						VStack(spacing: 4) {
							CatTitle("Touch Input")
							CatList {
								TouchModeCards(selection: $settings.cursorMode)
							}
							CatTitle("Trackpad")
							CatList {
								CatSlider("Pointer Speed", icon: "speedometer", tint: .blue, value: $settings.mouseSensitivity, in: 0.1...4, step: 0.1)
								CatItem("Pointer Acceleration", icon: "hare.fill", tint: .orange) {
									Toggle("", isOn: $settings.pointerAcceleration)
										.frame(width: 80)
								}
								CatSlider("Cursor Size", icon: "cursorarrow", tint: .gray, value: $settings.cursorScale, in: 0.1...4, step: 0.1)
								CatItem("Right Click", icon: "cursorarrow.click.2", tint: Color(UIColor.systemIndigo)) {
									MultiPicker(selection: $settings.rightClickPosition, options:
									[
										Choice("First Finger", RightClickPosition.firstFinger),
										Choice("Middle", RightClickPosition.middle),
										Choice("Second Finger", RightClickPosition.secondFinger)
									])
								}
								CatItem("Two-Finger Drag", icon: "hand.draw.fill", tint: Color(UIColor.systemTeal)) {
									MultiPicker(selection: $settings.twoFingerDrag, options:
									[
										Choice("Scroll", TwoFingerDrag.scroll),
										Choice("Pan View When Zoomed", TwoFingerDrag.panView)
									])
								}
								CatItem("Pinch to Zoom", icon: "plus.magnifyingglass", tint: .green) {
									Toggle("", isOn: $settings.zoomEnabled)
										.frame(width: 80)
								}
							}
							CatTitle("Gestures & Feedback")
							CatList {
								CatSlider("Scroll Speed", icon: "arrow.up.arrow.down", tint: .blue, value: $settings.scrollSensitivity, in: 0.5...5, step: 0.5)
								CatItem("Reverse Scrolling", icon: "arrow.uturn.down", tint: Color(UIColor.systemIndigo)) {
									Toggle("", isOn: $settings.reverseScrollDirection)
										.frame(width: 80)
								}
								CatItem("Three-Finger Tap", icon: "3.circle.fill", tint: .purple) {
									MultiPicker(selection: $settings.threeFingerTap, options:
									[
										Choice("Keyboard", ThreeFingerTapAction.keyboard),
										Choice("Middle Click", ThreeFingerTapAction.middleClick)
									])
								}
								CatItem("Haptic Feedback", icon: "waveform", tint: .pink) {
									Toggle("", isOn: $settings.hapticFeedback)
										.frame(width: 80)
								}
								CatItem("Click Ripple", icon: "smallcircle.circle", tint: .orange) {
									Toggle("", isOn: $settings.clickRipple)
										.frame(width: 80)
								}
							}
							CatTitle("Keyboard")
							CatList {
								CatItem("Show Keyboard Button", icon: "keyboard", tint: .gray) {
									Toggle("", isOn: $settings.showKeyboardButton)
										.frame(width: 80)
								}
								CatItem("Option Key as Command", icon: "command", tint: .gray) {
									Toggle("", isOn: $settings.optionAsCommand)
										.frame(width: 80)
								}
							}
							CatTitle("Video")
							CatList {
								CatItem("Renderer", icon: "cpu", tint: .blue) {
									SegmentPicker(selection: $settings.renderer, options: [
										Choice("OpenGL", RendererType.opengl),
										Choice("Metal", RendererType.metal)
									])
									.frame(width: 165)
								}
								CatItem("Resolution", icon: "display", tint: Color(UIColor.systemTeal)) {
									MultiPicker(selection: $settings.resolution, options: resolutionChoices)
								}
								CatItem("Bitrate", icon: "chart.bar.fill", tint: .green) {
									MultiPicker(selection: $settings.bitrate, options: [Choice("Host Default", 0)] + ParsecResolution.bitrates.map { Choice("\($0) Mbps", $0) })
								}
								CatItem("Frame Rate", icon: "timer", tint: .orange) {
									MultiPicker(selection: $settings.preferredFramesPerSecond, options:
									[
										Choice("Auto (Device Max)", 0),
										Choice("120 FPS", 120),
										Choice("60 FPS", 60),
										Choice("30 FPS", 30)
									])
								}
								CatItem("Constant Frame Rate", icon: "equal.circle.fill", tint: .orange) {
									Toggle("", isOn: $settings.constantFps)
										.frame(width: 80)
								}
								CatItem("Codec", icon: "film", tint: .purple) {
									MultiPicker(selection: $settings.decoder, options:
									[
										Choice("H.264", DecoderPref.h264),
										Choice("Prefer H.265", DecoderPref.h265)
									])
								}
							}
							CatTitle("During a Stream")
							CatList {
								CatItem("Show Stream Stats", icon: "waveform.path.ecg", tint: .green) {
									Toggle("", isOn: $settings.alwaysShowStatus)
										.frame(width: 80)
								}
								CatItem("Quick Actions Button", icon: "ellipsis.circle.fill", tint: .blue) {
									Toggle("", isOn: $settings.showQuickActions)
										.frame(width: 80)
								}
								CatItem("Show Menu Button", icon: "list.bullet", tint: .blue) {
									Toggle("", isOn: Binding(get: { !settings.noOverlay }, set: { settings.noOverlay = !$0 }))
										.frame(width: 80)
								}
								CatItem("Menu Edge Swipe", icon: "arrow.right.to.line", tint: Color(UIColor.systemIndigo)) {
									MultiPicker(selection: $settings.menuSwipeEdge, options:
									[
										Choice("Off", MenuSwipeEdge.off),
										Choice("Left Edge", MenuSwipeEdge.left),
										Choice("Right Edge", MenuSwipeEdge.right)
									])
								}
								CatItem(UIDevice.current.userInterfaceIdiom == .pad ? "Hide iPad Status Bar" : "Hide iPhone Status Bar", icon: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone", tint: .gray) {
									Toggle("", isOn: $settings.hideStatusBar)
										.frame(width: 80)
								}
								CatItem("Picture in Picture", icon: "pip", tint: Color(UIColor.systemTeal)) {
									Toggle("", isOn: $settings.enablePiP)
										.frame(width: 80)
								}
								CatItem("Start Muted", icon: "speaker.slash.fill", tint: .red) {
									Toggle("", isOn: $settings.startMuted)
										.frame(width: 80)
								}
							}
							CatTitle("Developer")
							CatList {
								CatItem("Auto Reconnect", icon: "arrow.clockwise", tint: .green) {
									Toggle("", isOn: $settings.autoReconnect)
										.frame(width: 80)
								}
								if settings.autoReconnect {
									CatItem("Show Reconnect Errors", icon: "exclamationmark.triangle.fill", tint: .orange) {
										Toggle("", isOn: $settings.errorPrompts)
											.frame(width: 80)
									}
								}
								CatItem("Show Connection Log", icon: "doc.text.fill", tint: .gray) {
									Toggle("", isOn: $settings.showConnectionLog)
										.frame(width: 80)
								}
							}
							Text(getVersionInfo())
								.multilineTextAlignment(.center)
								.opacity(0.5)
								.padding()
						}
					}
                    .foregroundColor(Color("Foreground"))
				}
				.background(Rectangle().fill(Color("BackgroundGray")))
				.cornerRadius(supportsLiquidGlass ? 28 : 8)
				.padding()
			}
		}
        .preferredColorScheme(appScheme)
		.scaleEffect(visible ? 1 : 0, anchor: .zero)
	}

	func saveAndExit() {
		// SettingsHandler.renderer = renderer
		withAnimation(.easeInOut(duration: 0.24)) {
			visible = false
		}
	}

	func getVersionInfo() -> String {
		let info = Bundle.main.infoDictionary
		let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown version"
		let commit = info?["GitCommitInfo"] as? String ?? "Unknown commit"
		return "Version \(version)-\(commit)"
	}
}

struct SettingsView_Previews: PreviewProvider {
	@State static var value: Bool = true

	static var previews: some View {
		SettingsView(visible: $value)
	}
}
