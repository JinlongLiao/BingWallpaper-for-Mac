import Cocoa

class ImageSelectorView: NSView {
    @IBOutlet var containerView: NSView!
    @IBOutlet var imageView: NSImageView!
    @IBOutlet var rightButton: NSButton!
    @IBOutlet var leftButton: NSButton!
    var imageClickAction: (() -> Void)?
    private var imageClickRecognizer: NSClickGestureRecognizer?
    private var imageTrackingArea: NSTrackingArea?
    private let imageHoverOverlay = CALayer()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        loadNib()
        setupImageView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        loadNib()
        setupImageView()
    }
    
    private func loadNib() {
        if Bundle.main.loadNibNamed(String(describing: type(of: self)), owner: self, topLevelObjects: nil) {
            addSubview(containerView)
            containerView.frame = bounds
            containerView.autoresizingMask = [.width, .height]
            autoresizingMask = [.width]
        }
    }
    
    private func setupImageView() {
        guard let imageView = imageView else { return }
        
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5.0
        imageView.layer?.masksToBounds = true

        imageHoverOverlay.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        imageHoverOverlay.cornerRadius = 5.0
        imageHoverOverlay.opacity = 0
        imageHoverOverlay.frame = imageView.bounds
        imageHoverOverlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageView.layer?.addSublayer(imageHoverOverlay)
        imageView.toolTip = L("Open image source")

        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(imageClicked(_:)))
        imageView.addGestureRecognizer(recognizer)
        imageClickRecognizer = recognizer
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard let imageView else { return }

        if let imageTrackingArea {
            imageView.removeTrackingArea(imageTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        imageView.addTrackingArea(trackingArea)
        imageTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === imageTrackingArea else { return }
        setImageHighlighted(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === imageTrackingArea else { return }
        setImageHighlighted(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard event.trackingArea === imageTrackingArea else {
            super.cursorUpdate(with: event)
            return
        }
        NSCursor.pointingHand.set()
    }

    private func setImageHighlighted(_ highlighted: Bool) {
        imageHoverOverlay.opacity = highlighted ? 1 : 0
        imageView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        imageView.layer?.borderWidth = highlighted ? 2 : 0
    }

    @objc private func imageClicked(_ recognizer: NSClickGestureRecognizer) {
        imageClickAction?()
    }
}
