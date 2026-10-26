import UIKit

/// Shown while the workspace loads: Claude's warm paper colors, a terracotta spark and the app name.
final class StudioLaunchView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.149, blue: 0.141, alpha: 1)
            : UIColor(red: 0.98, green: 0.976, blue: 0.961, alpha: 1) }
        let mark = UIImageView(image: UIImage(systemName: "asterisk"))
        mark.tintColor = UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1); mark.contentMode = .scaleAspectFit
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .bold)
        mark.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = UILabel(); title.text = "AI Studio"
        let serif = UIFont.systemFont(ofSize: 30, weight: .regular).fontDescriptor.withDesign(.serif)
        title.font = serif.map { UIFont(descriptor: $0, size: 30) } ?? .systemFont(ofSize: 30)
        title.textColor = .label
        title.textAlignment = .center
        let subtitle = UILabel(); subtitle.text = "Your Claude team, ready to build."
        subtitle.font = .systemFont(ofSize: 14); subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [mark, title, subtitle])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     stack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.8)])
        isAccessibilityElement = true; accessibilityLabel = "AI Studio is loading"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
