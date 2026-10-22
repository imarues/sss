import SwiftUI
import UIKit

/// UIKit-backed text renderer for Arabic/mixed descriptions.
/// SwiftUI's trailing alignment follows layout direction, which can place
/// multiline Arabic copy on the wrong physical edge. This forces both the
/// paragraph writing direction and the actual UIKit text alignment to RTL.
struct RTLDescriptionText: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 14
    var lineSpacing: CGFloat = 9

    func makeUIView(context: Context) -> IntrinsicRTLTextView {
        let view = IntrinsicRTLTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.semanticContentAttribute = .forceRightToLeft
        view.textAlignment = .right
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: IntrinsicRTLTextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.baseWritingDirection = .rightToLeft
        paragraph.lineSpacing = lineSpacing

        let font = UIFont(name: "PingARLT-Regular", size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize, weight: .regular)
        let color = UIColor(red: 154.0 / 255.0, green: 163.0 / 255.0, blue: 188.0 / 255.0, alpha: 1)

        view.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .writingDirection: [
                    NSWritingDirection.rightToLeft.rawValue
                        | NSWritingDirectionFormatType.override.rawValue
                ]
            ]
        )
        view.semanticContentAttribute = .forceRightToLeft
        view.textAlignment = .right
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: IntrinsicRTLTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fitting.height))
    }
}

final class IntrinsicRTLTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else { return super.intrinsicContentSize }
        let fitting = sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitting.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}
