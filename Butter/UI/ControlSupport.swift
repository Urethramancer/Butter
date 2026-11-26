import SwiftUI
import AppKit

// Keep native list selection and keyboard handling, but let SwiftUI draw the
// transfer row's subdued selection background instead of the system accent.
struct TransferRowSelection: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let view = SelectionView(); view.setAccessibilityElement(false); return view
	}
	func updateNSView(_ view: NSView, context: Context) { (view as? SelectionView)?.configure() }
	private final class SelectionView: NSView {
		override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
		func configure() {
			var ancestor = superview
			while let view = ancestor {
				if let table = view as? NSTableView {
					if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
					return
				}
				ancestor = view.superview
			}
		}
	}
}

extension View {
	// Icon-only controls need an action name for both pointer and VoiceOver users.
	func controlHelp(_ label: String) -> some View {
		help(label).accessibilityLabel(label)
	}
}

struct PeerLimitField: View {
	let title: String
	@Binding var value: Int
	let range: ClosedRange<Int>
	private var boundedValue: Binding<Int> {
		Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
	}
	var body: some View {
		LabeledContent(title) {
			HStack(spacing: 8) {
				TextField(title, value: boundedValue, format: .number.grouping(.never))
					.labelsHidden()
					.frame(width: 80).multilineTextAlignment(.trailing)
					.accessibilityLabel(title)
					.accessibilityIdentifier(title)
					.accessibilityHint("Enter a whole number from \(range.lowerBound) to \(range.upperBound).")
					.help("Enter \(range.lowerBound)–\(range.upperBound) peers; values outside this range are limited automatically.")
				Stepper(title, value: $value, in: range).labelsHidden()
					.accessibilityLabel("Adjust \(title.lowercased())")
					.accessibilityValue("\(value) peers")
					.help("Increase or decrease the \(title.lowercased()).")
			}
		}
	}
}

struct TransferSearchField: NSViewRepresentable {
	@Binding var text: String
	func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
	func makeNSView(context: Context) -> NSSearchField {
		let field = NSSearchField()
		field.placeholderString = "Find transfers"
		field.sendsSearchStringImmediately = true
		field.delegate = context.coordinator
		field.target = context.coordinator
		field.action = #selector(Coordinator.searchChanged(_:))
		field.setAccessibilityLabel("Find transfers")
		field.setAccessibilityIdentifier("transfer-search")
		field.setAccessibilityHelp("Filter transfers by name.")
		return field
	}
	func updateNSView(_ field: NSSearchField, context: Context) {
		context.coordinator.text = $text
		if field.stringValue != text { field.stringValue = text }
	}
	final class Coordinator: NSObject, NSSearchFieldDelegate {
		var text: Binding<String>
		init(text: Binding<String>) { self.text = text }
		@objc func searchChanged(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
		func controlTextDidChange(_ notification: Notification) {
			guard let field = notification.object as? NSSearchField else { return }
			searchChanged(field)
		}
	}
}

struct InlineRenameField: NSViewRepresentable {
	let initialText: String
	let identifier: String
	let label: String
	let font: NSFont
	var onCommit: (String) -> Void
	var onCancel: () -> Void

	func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, onCancel: onCancel) }

	func makeNSView(context: Context) -> RenameTextField {
		let field = RenameTextField()
		field.stringValue = initialText
		field.font = font
		field.isBordered = true
		field.isBezeled = true
		field.bezelStyle = .roundedBezel
		field.focusRingType = .default
		field.usesSingleLineMode = true
		field.lineBreakMode = .byTruncatingTail
		field.cell?.sendsActionOnEndEditing = false
		field.setContentHuggingPriority(.defaultLow, for: .horizontal)
		field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		field.delegate = context.coordinator
		field.setAccessibilityLabel(label)
		field.setAccessibilityIdentifier(identifier)
		return field
	}

	func updateNSView(_ field: RenameTextField, context: Context) {
		context.coordinator.onCommit = onCommit
		context.coordinator.onCancel = onCancel
	}

	final class RenameTextField: NSTextField {
		private var didFocus = false
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard window != nil, !didFocus else { return }
			didFocus = true
			DispatchQueue.main.async { [weak self] in
				guard let self, let window = self.window else { return }
				window.makeFirstResponder(self)
				self.currentEditor()?.selectAll(nil)
			}
		}
	}

	final class Coordinator: NSObject, NSTextFieldDelegate {
		var onCommit: (String) -> Void
		var onCancel: () -> Void
		private var finished = false

		init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
			self.onCommit = onCommit
			self.onCancel = onCancel
		}

		func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
			if commandSelector == #selector(NSResponder.insertNewline(_:)) {
				guard !finished else { return true }
				finished = true
				onCommit(control.stringValue)
				return true
			}
			if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
				guard !finished else { return true }
				finished = true
				onCancel()
				return true
			}
			return false
		}

		func controlTextDidEndEditing(_ notification: Notification) {
			guard !finished, let field = notification.object as? NSTextField else { return }
			finished = true
			onCommit(field.stringValue)
		}
	}
}
