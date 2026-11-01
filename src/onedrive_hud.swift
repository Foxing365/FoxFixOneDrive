import Cocoa

// FoxFixOneDrive - Native Top-Right HUD Banner
// - Pierces macOS Do Not Disturb / Focus modes via WindowServer NSPanel (.statusBar level)
// - Non-activating (.nonactivatingPanel): never steals keyboard focus while typing or working
// - Zero background footprint: fades out and terminates completely after displaying

final class HUDAppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    let titleText: String
    let subtitleText: String
    let bodyText: String
    let duration: Double

    init(title: String, subtitle: String, body: String, duration: Double = 6.5) {
        self.titleText = title
        self.subtitleText = subtitle
        self.bodyText = body
        self.duration = duration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }

        let width: CGFloat = 360
        let height: CGFloat = 92
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.maxX - width - 16
        let y = visibleFrame.maxY - height - 12
        let rect = NSRect(x: x, y: y, width: width, height: height)

        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.alphaValue = 0.0

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.8
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let iconLabel = NSTextField(labelWithString: "☁️")
        iconLabel.font = NSFont.systemFont(ofSize: 26)
        iconLabel.frame = NSRect(x: 14, y: height - 52, width: 34, height: 34)
        visualEffect.addSubview(iconLabel)

        let titleField = NSTextField(labelWithString: titleText)
        titleField.font = NSFont.boldSystemFont(ofSize: 13.5)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = NSRect(x: 52, y: height - 28, width: width - 66, height: 18)
        visualEffect.addSubview(titleField)

        let subField = NSTextField(labelWithString: subtitleText)
        subField.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        subField.textColor = NSColor(calibratedRed: 0.55, green: 0.82, blue: 1.0, alpha: 0.95)
        subField.lineBreakMode = .byTruncatingTail
        subField.frame = NSRect(x: 52, y: height - 46, width: width - 66, height: 16)
        visualEffect.addSubview(subField)

        let bodyField = NSTextField(wrappingLabelWithString: bodyText)
        bodyField.font = NSFont.systemFont(ofSize: 11.5)
        bodyField.textColor = NSColor.white.withAlphaComponent(0.88)
        bodyField.frame = NSRect(x: 52, y: 10, width: width - 64, height: 32)
        visualEffect.addSubview(bodyField)

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(dismissNow))
        visualEffect.addGestureRecognizer(clickGesture)

        panel.contentView = visualEffect
        panel.orderFrontRegardless()

        NSSound(named: NSSound.Name("Glass"))?.play()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            self.panel.animator().alphaValue = 0.98
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.dismissNow()
        }
    }

    @objc func dismissNow() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            self.panel.animator().alphaValue = 0.0
        }, completionHandler: {
            NSApp.terminate(nil)
        })
    }
}

let args = CommandLine.arguments
let title = args.count > 1 ? args[1] : "FoxFixOneDrive"
let subtitle = args.count > 2 ? args[2] : ""
let body = args.count > 3 ? args[3] : ""
let duration = args.count > 4 ? (Double(args[4]) ?? 6.5) : 6.5

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = HUDAppDelegate(title: title, subtitle: subtitle, body: body, duration: duration)
app.delegate = delegate
app.run()
