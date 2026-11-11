import Cocoa

class TextView: NSView {
    @IBOutlet var containerView: NSView!
    @IBOutlet var descriptionLabel: NSTextField!
    @IBOutlet var copyrightLabel: NSTextField!
    @IBOutlet var button: NSButton!
    @IBOutlet var visualEffectView: NSVisualEffectView!
    private var trackingArea: NSTrackingArea?
    private let submenuIndicator = NSImageView()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        loadNib()
        setupVisualEffectView()
        setupSubmenuIndicator()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        loadNib()
        setupVisualEffectView()
        setupSubmenuIndicator()
    }
    
    private func loadNib() {
        guard Bundle.main.loadNibNamed(String(describing: type(of: self)), owner: self, topLevelObjects: nil) else { return }
        addSubview(containerView)
        containerView.frame = bounds
        containerView.autoresizingMask = [.width, .height]
        autoresizingMask = [.width, .height]
    }
    
    private func setupVisualEffectView() {
        guard visualEffectView != nil else { return }
        visualEffectView.isHidden = true
        visualEffectView.state = .active
        visualEffectView.material = .selection
        visualEffectView.isEmphasized = true
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 5
    }

    private func setupSubmenuIndicator() {
        guard containerView != nil else { return }

        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        submenuIndicator.image = NSImage(systemSymbolName: "chevron.right",
                                         accessibilityDescription: L("Image actions"))?
            .withSymbolConfiguration(configuration)
        submenuIndicator.imageScaling = .scaleProportionallyDown
        submenuIndicator.contentTintColor = .tertiaryLabelColor
        submenuIndicator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(submenuIndicator)

        NSLayoutConstraint.activate([
            submenuIndicator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            submenuIndicator.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            submenuIndicator.widthAnchor.constraint(equalToConstant: 7),
            submenuIndicator.heightAnchor.constraint(equalToConstant: 12)
        ])
    }
    
    var highlighted: Bool = false {
        didSet {
            if oldValue != highlighted {
                needsDisplay = true
            }
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if highlighted {
            descriptionLabel.textColor = NSColor.selectedMenuItemTextColor
            copyrightLabel.textColor = NSColor.selectedMenuItemTextColor
            submenuIndicator.contentTintColor = NSColor.selectedMenuItemTextColor
            visualEffectView.isHidden = false
        } else {
            descriptionLabel.textColor = NSColor.labelColor
            copyrightLabel.textColor = NSColor.tertiaryLabelColor
            submenuIndicator.contentTintColor = NSColor.tertiaryLabelColor
            visualEffectView.isHidden = true
        }
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        trackingArea = NSTrackingArea(rect: bounds,
                                      options: [.activeAlways, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
    
    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }
}
