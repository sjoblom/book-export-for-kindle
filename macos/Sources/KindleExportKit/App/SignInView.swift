import AppKit

/// What the main window shows while Amazon's sign-in page is up: a slim
/// native bar that says what is going on (it is not part of Amazon's page),
/// and below it the reader's own web view, moved in with
/// `ReaderSession.present(in: readerSlot)`.
@MainActor
public final class SignInView: NSView {
  public static let title = "Sign in to Amazon to see your books"
  public static let detail =
    "This is Amazon’s own page — Book Export for Kindle never sees your password."
  static let barHeight: CGFloat = 56

  /// Where the reader's web view goes.
  public let readerSlot = NSView()
  public let titleLabel = NSTextField(labelWithString: SignInView.title)
  public let detailLabel = NSTextField(labelWithString: SignInView.detail)
  public let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  /// Cancel pressed: not now. (No Escape shortcut — Escape belongs to
  /// Amazon's page, and an accidental cancel would throw the sign-in away.)
  public var onCancel: (() -> Void)?

  private let bar = NSVisualEffectView()
  private let separator = NSBox()

  public override init(frame: NSRect) {
    super.init(frame: frame)

    bar.material = .titlebar
    // Behind the window, like a title bar: within the window it would blur
    // the library page lying underneath this view.
    bar.blendingMode = .behindWindow
    bar.state = .followsWindowActiveState

    titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    titleLabel.textColor = .labelColor
    detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    detailLabel.textColor = .secondaryLabelColor
    for label in [titleLabel, detailLabel] {
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    cancelButton.bezelStyle = .rounded
    cancelButton.target = self
    cancelButton.action = #selector(cancel)

    separator.boxType = .separator

    let text = NSStackView(views: [titleLabel, detailLabel])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 2

    for view in [text, cancelButton] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      bar.addSubview(view)
    }
    for view in [bar, separator, readerSlot] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: topAnchor),
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bar.heightAnchor.constraint(equalToConstant: Self.barHeight),

      text.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
      text.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      text.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),
      cancelButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
      cancelButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

      separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),

      readerSlot.topAnchor.constraint(equalTo: separator.bottomAnchor),
      readerSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
      readerSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
      readerSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  @objc func cancel() { onCancel?() }
}
