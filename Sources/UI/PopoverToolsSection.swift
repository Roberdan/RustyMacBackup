import Cocoa

protocol ToolToggleDelegate: AnyObject {
    func toolPathToggled(_ path: String, enabled: Bool)
}

/// A collapsible category section with toggle rows for discovered tools.
/// Looks like EXO's "Nodes" section: category header with count + chevron.
class ToolsCategoryView: NSStackView {
    weak var toggleDelegate: ToolToggleDelegate?
    private let category: String
    private var items: [(label: String, paths: [String], sensitive: Bool)] = []
    private var enabledPaths: Set<String> = []
    private var expanded = true
    private let itemStack = NSStackView()
    private let chevronLabel = NSTextField(labelWithString: "")

    init(category: String) {
        self.category = category
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(items: [(label: String, paths: [String], sensitive: Bool)],
                   enabledPaths: Set<String>) {
        self.items = items
        self.enabledPaths = enabledPaths
        rebuild()
    }

    private func rebuild() {
        for v in arrangedSubviews { removeArrangedSubview(v); v.removeFromSuperview() }
        itemStack.arrangedSubviews.forEach { itemStack.removeArrangedSubview($0); $0.removeFromSuperview() }

        // Category header row
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: 272).isActive = true

        let titleLabel = NSTextField(labelWithString: category)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let enabledCount = items.flatMap(\.paths).filter { enabledPaths.contains($0) }.count
        let totalCount = items.flatMap(\.paths).count
        let countLabel = NSTextField(labelWithString: "(\(enabledCount)/\(totalCount))")
        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .tertiaryLabelColor

        chevronLabel.stringValue = expanded ? "Hide" : "Show"
        chevronLabel.font = .systemFont(ofSize: 10)
        chevronLabel.textColor = .controlAccentColor

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(countLabel)
        header.addArrangedSubview(headerSpacer)
        header.addArrangedSubview(chevronLabel)

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(toggleExpanded))
        header.addGestureRecognizer(clickGesture)

        addArrangedSubview(header)

        // Items
        itemStack.orientation = .vertical
        itemStack.alignment = .leading
        itemStack.spacing = 1
        itemStack.translatesAutoresizingMaskIntoConstraints = false

        if expanded {
            for item in items {
                let row = makeToolRow(item: item)
                itemStack.addArrangedSubview(row)
            }
        }

        itemStack.isHidden = !expanded
        addArrangedSubview(itemStack)
    }

    private func makeToolRow(item: (label: String, paths: [String], sensitive: Bool)) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 272).isActive = true

        // Checkbox -- on if ALL paths of this tool are in config
        let allEnabled = item.paths.allSatisfy { enabledPaths.contains($0) }
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
        check.state = allEnabled ? .on : .off
        // Store paths as represented object via tag mapping
        check.tag = items.firstIndex(where: { $0.label == item.label }) ?? 0
        row.addArrangedSubview(check)

        // Tool name
        let nameLabel = NSTextField(labelWithString: item.label)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(nameLabel)

        // Sensitive badge
        if item.sensitive {
            let badge = NSTextField(labelWithString: "key")
            badge.font = .systemFont(ofSize: 9)
            badge.textColor = .systemOrange
            row.addArrangedSubview(badge)
        }

        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(rowSpacer)

        // Path hint (first path, truncated)
        let shortPath = item.paths.first.map { p -> String in
            let contracted = ConfigDiscovery.contract(ConfigDiscovery.expand(p))
            if contracted.count > 25 {
                return "..." + String(contracted.suffix(22))
            }
            return contracted
        } ?? ""
        let pathLabel = NSTextField(labelWithString: shortPath)
        pathLabel.font = .systemFont(ofSize: 9)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        row.addArrangedSubview(pathLabel)

        return row
    }

    @objc private func toggleExpanded() {
        expanded.toggle()
        rebuild()
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard sender.tag < items.count else { return }
        let item = items[sender.tag]
        let enabled = sender.state == .on
        for path in item.paths {
            toggleDelegate?.toolPathToggled(path, enabled: enabled)
        }
    }
}
