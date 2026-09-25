import AppKit

/// Header row above a menu section (e.g. "Installed", "Recommended for your
/// Mac"). Shows the section title, optionally followed by a link (e.g. the
/// running server's /models endpoint above the Installed section).
final class SectionHeaderView: ItemView {
  private var linkUrl: URL?
  private let linkLabel = Theme.secondaryLabel()
  private let onToggle: (() -> Void)?

  init(
    title: String = "Installed",
    linkText: String? = nil,
    linkUrl: URL? = nil,
    expanded: Bool? = nil,
    onToggle: (() -> Void)? = nil
  ) {
    self.linkUrl = linkUrl
    self.onToggle = onToggle
    super.init(frame: .zero)

    let titleLabel = Theme.secondaryLabel()
    titleLabel.textColor = Theme.Colors.textPrimary
    titleLabel.stringValue = title
    titleLabel.maximumNumberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.cell?.truncatesLastVisibleLine = true
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let titleRow: NSView
    if let linkText, linkUrl != nil {
      linkLabel.attributedStringValue = NSAttributedString(
        string: linkText,
        attributes: [
          .foregroundColor: NSColor.linkColor,
          .font: Theme.Fonts.secondary,
        ])
      linkLabel.isSelectable = false
      let click = NSClickGestureRecognizer(target: self, action: #selector(openLink))
      linkLabel.addGestureRecognizer(click)

      let row = NSStackView(views: [titleLabel, linkLabel])
      row.orientation = .horizontal
      row.spacing = 4
      row.alignment = .firstBaseline
      titleRow = row
    } else {
      titleRow = titleLabel
    }

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    var rootViews: [NSView] = [titleRow, spacer]

    // Collapsible section: a trailing chevron marks the header as a toggle
    // (down = collapsed/wound, up = expanded) and the whole row becomes clickable.
    if let onToggle, let expanded {
      let chevron = NSImageView()
      Theme.configure(
        chevron, symbol: expanded ? "chevron.up" : "chevron.down", color: .tertiaryLabelColor
      )
      Layout.constrainToIconSize(chevron)
      rootViews.append(chevron)
      addGesture(action: #selector(didToggle))
    }

    let rootStack = NSStackView(views: rootViews)
    rootStack.orientation = .horizontal
    rootStack.alignment = .centerY
    rootStack.spacing = 6

    contentView.addSubview(rootStack)
    rootStack.pinToSuperview()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var highlightEnabled: Bool { onToggle != nil }

  @objc private func openLink() {
    if let linkUrl {
      openInBrowser(linkUrl)
    }
  }

  @objc private func didToggle() {
    onToggle?()
  }
}
