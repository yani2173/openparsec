import SwiftUI

// MARK: - Liquid Glass

/// true when Apple's Liquid Glass material can be used: built with the iOS 26+ SDK and running on
/// iOS 26 or later. Everything below falls back to the classic flat look otherwise.
let supportsLiquidGlass: Bool = {
	#if compiler(>=6.2)
	if #available(iOS 26.0, *) { return true }
	#endif
	return false
}()

/// Rounded rectangle that keeps the classic radius on old iOS and uses the rounder, concentric
/// radius Liquid Glass is designed around on iOS 26+.
func glassRounded(_ classic: CGFloat, glass: CGFloat) -> RoundedRectangle {
	RoundedRectangle(cornerRadius: supportsLiquidGlass ? glass : classic, style: .continuous)
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
func liquidGlassMaterial(interactive: Bool, tint: Color?) -> Glass {
	var glass = Glass.regular
	if let tint = tint {
		glass = glass.tint(tint)
	}
	if interactive {
		glass = glass.interactive()
	}
	return glass
}

extension View {
	/// The official Liquid Glass material on iOS 26+, `fallback` painted in `shape` before that.
	/// `interactive` makes the glass react to touches (use it on buttons), `tint` colours it.
	@ViewBuilder
	func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil, fallback: Color) -> some View {
		if #available(iOS 26.0, *) {
			self.glassEffect(liquidGlassMaterial(interactive: interactive, tint: tint), in: shape)
		} else {
			self.background(shape.fill(fallback))
		}
	}
}
#else
extension View {
	// SDK without Liquid Glass (Xcode 16 or older): always the classic look
	func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil, fallback: Color) -> some View {
		self.background(shape.fill(fallback))
	}
}
#endif

/**
 * Category Title
 *
 * Displays a title before the start of a list.
 */
struct CatTitle: View {
	var text: String

	init(_ text: String) {
		self.text = text
	}

	var body: some View {
		HStack {
			Text(text)
				.font(.system(size: 13, weight: .semibold))
				.opacity(0.6)
			Spacer()
		}
		.padding(.horizontal, 28)
		.padding(.top, 14)
		.padding(.bottom, 2)
	}
}

/// The small coloured rounded square with a white symbol that leads a settings row, as in the
/// iOS Settings app, so a long list can be scanned by colour and shape.
struct IconBadge: View {
	var symbol: String
	var tint: Color

	var body: some View {
		Image(systemName: symbol)
			.font(.system(size: 14, weight: .semibold))
			.foregroundColor(.white)
			.frame(width: 28, height: 28)
			.background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
	}
}

/**
 * Category List
 *
 * Displays a list of items. Acts as a container.
 * Use of `CatItem`s is recommended.
 */
struct CatList<Content: View>: View {
	var content: () -> Content

	init(@ViewBuilder content: @escaping () -> Content) {
		self.content = content
	}

	var body: some View {
		VStack(spacing: 10, content: content)
			.padding(.vertical, 12)
			.background(glassRounded(10, glass: 20).fill(Color("BackgroundTab")))
			.padding(.horizontal)
	}
}

/**
 * Category Item
 *
 * Displays a new item with a label in a list.
 * Should be used within `CatList`s.
 */
struct CatItem<Content: View>: View {
	var title: String
	var icon: String?
	var tint: Color
	var content: () -> Content

	init(_ title: String, icon: String? = nil, tint: Color = Color("AccentColor"), @ViewBuilder content: @escaping () -> Content) {
		self.title = title
		self.icon = icon
		self.tint = tint
		self.content = content
	}

	var body: some View {
		HStack(spacing: 12) {
			if let icon = icon {
				IconBadge(symbol: icon, tint: tint)
			}
			Text(title)
				.lineLimit(1)
			Spacer()
			content()
		}
		.padding(.horizontal)
	}
}

struct CatSlider: View {
	var title: String
	var icon: String?
	var tint: Color
	var value: Binding<Double>
	var range: ClosedRange<Double>
	var step: Double

	init(_ title: String, icon: String? = nil, tint: Color = Color("AccentColor"), value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
		self.title = title
		self.icon = icon
		self.tint = tint
		self.value = value
		self.range = range
		self.step = step
	}

	var body: some View {
		VStack(spacing: 4) {
			HStack(spacing: 12) {
				if let icon = icon {
					IconBadge(symbol: icon, tint: tint)
				}
				Text(title)
					.lineLimit(1)
				Spacer()
				Text(String(format: "%.1f", value.wrappedValue))
					.font(.system(size: 15, weight: .medium).monospacedDigit())
					.opacity(0.6)
			}
			Slider(value: value, in: range, step: step)
		}
		.padding(.horizontal)
	}
}

/// The four touch input modes as tappable cards, two by two, with what the chosen one does
/// written underneath.
struct TouchModeCards: View {
	@Binding var selection: CursorMode

	private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			LazyVGrid(columns: columns, spacing: 10) {
				ForEach(CursorMode.allCases, id: \.self) { mode in
					card(mode)
				}
			}
			Text(selection.summary)
				.font(.system(size: 13))
				.opacity(0.7)
				.fixedSize(horizontal: false, vertical: true)
				.id(selection)
				.transition(.opacity)
		}
		.padding(.horizontal)
	}

	func card(_ mode: CursorMode) -> some View {
		let selected = selection == mode
		let accent = Color("AccentColor")
		return Button(action: {
			withAnimation(.easeInOut(duration: 0.18)) { selection = mode }
		}) {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Image(systemName: mode.icon)
						.font(.system(size: 20, weight: .medium))
						.foregroundColor(selected ? .white : accent)
						.frame(width: 38, height: 38)
						.background(Circle().fill(selected ? accent : accent.opacity(0.15)))
					Spacer()
					Image(systemName: selected ? "checkmark.circle.fill" : "circle")
						.font(.system(size: 18))
						.foregroundColor(selected ? accent : Color("Foreground").opacity(0.25))
				}
				Text(mode.title)
					.font(.system(size: 14, weight: .semibold))
					.lineLimit(2)
					.multilineTextAlignment(.leading)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 0)
			}
			.padding(12)
			.frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
			.background(RoundedRectangle(cornerRadius: 16, style: .continuous)
				.fill(selected ? accent.opacity(0.14) : Color("Foreground").opacity(0.05)))
			.overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
				.stroke(selected ? accent.opacity(0.6) : Color.clear, lineWidth: 1.5))
			.contentShape(Rectangle())
		}
		.buttonStyle(PlainButtonStyle())
		.foregroundColor(Color("Foreground"))
		.accessibilityLabel(Text(mode.title))
		.accessibilityHint(Text(mode.summary))
		.accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
	}
}

struct ConnectionLogPanel: View {
	@ObservedObject var log = ConnectionLog.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			ForEach(Array(log.lines.suffix(14).enumerated()), id: \.offset) { _, line in
				Text(line)
					.font(.system(size: 10, design: .monospaced))
					.foregroundColor(.white.opacity(0.85))
					.lineLimit(2)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.padding(10)
		.frame(maxWidth: 640)
		// dark-tinted glass keeps the white log text readable over a bright stream
		.liquidGlass(in: glassRounded(8, glass: 16), tint: Color.black.opacity(0.35), fallback: Color.black.opacity(0.55))
		.padding(.horizontal, 16)
		.padding(.top, 8)
	}
}

/**
 * Choice
 *
 * Used to depict a single choice with a given label and value.
 */
struct Choice<T: Hashable> {
	var label: String
	var value: T

	init(_ label: String, _ value: T) {
		self.label = label
		self.value = value
	}
}

/**
 * Segmented Picker
 *
 * Displays a segmented picker with a given list of choices.
 */
struct SegmentPicker<SelectionValue: Hashable>: View {
	var selection: Binding<SelectionValue>
	var options: [Choice<SelectionValue>]

	init(selection: Binding<SelectionValue>, options: [Choice<SelectionValue>]) {
		self.selection = selection
		self.options = options
	}

	var body: some View {
		Picker("", selection: selection) {
			ForEach(options.indices, id: \.self) { i in
				Text(options[i].label).tag(options[i].value)
			}
		}
		.pickerStyle(.segmented)
	}
}

/**
 * Multiple Choice Picker
 *
 * Displays a button that opens a menu to pick from a given list of choices.
 */
struct MultiPicker<SelectionValue: Hashable>: View {
	var selection: Binding<SelectionValue>
	var options: [Choice<SelectionValue>]

	@State var showChoices: Bool = false
	@State var valueText: String = "Choose..."

	init(selection: Binding<SelectionValue>, options: [Choice<SelectionValue>]) {
		self.selection = selection
		self.options = options
	}

	var body: some View {
		if #available(iOS 15, *) {
			Picker("", selection: selection) {
				ForEach(options.indices, id: \.self) { i in
					Text(options[i].label).tag(options[i].value)
				}
			}
			.pickerStyle(.menu)
		} else {
			// Dumb workaround for older iOS versions. -Angel
			Button(action: {showChoices.toggle()}) {
				HStack {
					Text(valueText)
						.multilineTextAlignment(.center)
						.padding(.trailing, -4)
					Image(systemName: "chevron.up.chevron.down")
						.font(.system(size: 12))
				}
				.foregroundColor(Color("AccentColor"))
			}
			.actionSheet(isPresented: $showChoices) {
				genActionSheet()
			}
			.onAppear {
				for option in options {
					if option.value == selection.wrappedValue {
						valueText = option.label
						break
					}
				}
			}
		}
	}

	func genActionSheet() -> ActionSheet {
		let buttons = options.map { option in
			Alert.Button.default(Text(option.value == selection.wrappedValue ? "    \(option.label)  ✓" : option.label), action: {select(option)})
		}
		return ActionSheet(title: Text("Pick your preference:"), buttons: buttons + [Alert.Button.cancel()])
	}

	func select(_ option: Choice<SelectionValue>) {
		valueText = option.label
		selection.wrappedValue = option.value
	}
}

struct ExUI_Previews: PreviewProvider {
	@State static var value1 = false
	@State static var value2 = true

	static var previews: some View {
		VStack {
			CatTitle("Category Title")
			CatList {
				CatItem("Category Item") {
					Toggle("", isOn: .constant(true))
						.frame(width: 80)
				}
			}
			CatTitle("Other Controls")
			CatList {
				CatItem("Segmented Picker") {
					SegmentPicker(selection: $value1, options:
					[
						Choice("False", false),
						Choice("True", true)
					])
					.frame(width: 180)
				}
				CatItem("Multiple Choice Picker") {
					MultiPicker(selection: $value2, options:
					[
						Choice("False", false),
						Choice("True", true)
					])
				}
			}
			Spacer()
		}
		.background(Rectangle().fill(Color("BackgroundGray")).edgesIgnoringSafeArea(.all))
		.foregroundColor(Color("Foreground"))
		.colorScheme(appScheme)
	}
}
