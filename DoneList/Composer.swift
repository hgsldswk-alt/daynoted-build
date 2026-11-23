import SwiftUI
import UIKit

@MainActor
struct Composer: View {
    @ObservedObject var model: AppModel
    var editing = false
    @Binding var focused: Bool
    @State private var pickingDate = false
    @State private var input = InputReference()

    var body: some View {
        if let value = editing ? model.editing : model.draft {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t(editing ? "edit.label" : "entry.label"))
                    .font(.subheadline.weight(.semibold))
                ZStack(alignment: .topLeading) {
                    if value.text.isEmpty {
                        Text(L.t("entry.placeholder")).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    EntryInput(
                        text: value.text, focused: $focused, editing: editing, reference: input,
                        changed: { model.setText($0, editing: editing) },
                        submit: { save(continuous: !editing) }
                    )
                }
                .frame(minHeight: editing ? 125 : 74)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.accent).allowsHitTesting(false))
                ViewThatFits(in: .horizontal) {
                    HStack { dateButton(value); Spacer(minLength: 4); count(value) }
                    VStack(alignment: .leading, spacing: 3) { dateButton(value); count(value) }
                }
                if model.error == nil && value.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 240 {
                    ErrorLine(text: LogError.tooLong.message)
                } else {
                    ErrorLine(text: model.error)
                }
                ActionButton(title: L.t("common.save"), id: editing ? "edit.save" : "entry.save", style: .primary) {
                    save(continuous: false)
                }
                .disabled(model.busy || (try? DoneEntry.cleaned(value.text)) == nil)
            }
            .sheet(isPresented: $pickingDate, onDismiss: { focused = true }) {
                NavigationStack {
                    DatePicker(L.t("entry.date"), selection: Binding(
                        get: { (Day(key: value.dayKey) ?? model.today).date() },
                        set: { model.setDay(Day($0), editing: editing) }
                    ), in: ...model.today.date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .accessibilityIdentifier("entry.datePicker")
                    .navigationTitle(L.t("entry.date"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            ActionButton(title: L.t("common.done"), id: "entry.dateDone") { pickingDate = false }
                        }
                    }
                    .pageSurface()
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func dateButton(_ value: Draft) -> some View {
        ActionButton(title: (Day(key: value.dayKey) ?? model.today).formatted(.dateTime.month(.abbreviated).day().year()),
                     id: editing ? "edit.date" : "entry.date", icon: "calendar") {
            focused = false
            pickingDate = true
        }
    }

    private func count(_ value: Draft) -> some View {
        let count = value.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return Text(L.format("entry.count", count))
            .font(.caption.monospacedDigit())
            .foregroundStyle(count > 240 ? .red : Palette.muted)
    }

    private func save(continuous: Bool) {
        if !continuous, let view = input.view, view.markedTextRange != nil {
            view.unmarkText()
            model.setText(view.text, editing: editing)
        }
        Task {
            if await model.save(continuous: continuous, editing: editing), !continuous {
                focused = false
            }
        }
    }
}

private final class InputReference {
    weak var view: UITextView?
}

private final class ComposerTextView: UITextView {
    var wantsFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        focusIfReady()
    }

    func focusIfReady() {
        guard wantsFocus && !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, self.window != nil else { return }
            self.becomeFirstResponder()
        }
    }
}

@MainActor
private struct EntryInput: UIViewRepresentable {
    let text: String
    @Binding var focused: Bool
    let editing: Bool
    let reference: InputReference
    let changed: (String) -> Void
    let submit: () -> Void

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.wantsFocus = focused
        reference.view = view
        view.backgroundColor = .clear
        view.textColor = UIColor(Palette.ink)
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 8, right: 8)
        view.returnKeyType = editing ? .default : .done
        view.keyboardDismissMode = .interactive
        view.text = text
        view.accessibilityIdentifier = editing ? "edit.text" : "entry.text"
        view.accessibilityLabel = L.t(editing ? "edit.label" : "entry.label")
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        if view.markedTextRange == nil && view.text != text { view.text = text }
        view.wantsFocus = focused
        if focused {
            view.focusIfReady()
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let minimum: CGFloat = editing ? 125 : 74
        return CGSize(width: width, height: min(max(size.height, minimum), editing ? 260 : 130))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EntryInput
        init(_ parent: EntryInput) { self.parent = parent }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { DispatchQueue.main.async { self.parent.focused = true } }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { DispatchQueue.main.async { self.parent.focused = false } }
        }

        func textViewDidChange(_ textView: UITextView) {
            if textView.markedTextRange == nil { parent.changed(textView.text) }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.markedTextRange == nil, textView.text != parent.text {
                let expected = textView.text
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView, textView.markedTextRange == nil,
                          textView.text == expected, expected != self.parent.text else { return }
                    self.parent.changed(expected ?? "")
                }
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !parent.editing, text == "\n", textView.markedTextRange == nil else { return true }
            parent.changed(textView.text)
            parent.submit()
            return false
        }
    }
}

