import SwiftUI
import AppKit

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
					.frame(width: 80).multilineTextAlignment(.trailing)
					.accessibilityLabel(title)
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
