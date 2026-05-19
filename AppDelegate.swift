import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var currentPID: String?
    
    var statusMenuItem: NSMenuItem!
    var toggleMenuItem: NSMenuItem!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🛡️" // Иконка по умолчанию
        }
        
        let menu = NSMenu()
        
        statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        toggleMenuItem = NSMenuItem(title: "Connect", action: #selector(toggleConnection), keyEquivalent: "c")
        menu.addItem(toggleMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc func toggleConnection() {
        if currentPID != nil { stopVPN() } else { startVPN() }
    }
    
    func startVPN() {
        statusMenuItem.title = "Status: Connecting..."
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MiniVPN")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
        
        let configPath = appSupport.appendingPathComponent("config.json").path
        let logPath = appSupport.appendingPathComponent("vpn.log").path
        let binaryPath = Bundle.main.path(forResource: "sing-box", ofType: nil)!
        
        // Базовый конфиг sing-box (затем ты сможешь вставить сюда свой)
        let configJSON = """
        {
            "log": { "level": "info" },
            "inbounds": [{ "type": "tun", "tag": "tun-in", "interface_name": "utun9", "inet4_address": "172.19.0.1/30", "auto_route": true, "strict_route": true }],
            "outbounds": [{ "type": "direct", "tag": "direct" }]
        }
        """
        try? configJSON.write(toFile: configPath, atomically: true, encoding: .utf8)
        
        let shellCommand = "nohup '\(binaryPath)' run -c '\(configPath)' > '\(logPath)' 2>&1 & echo $!"
        let scriptSource = "do shell script \"\(shellCommand)\" with administrator privileges"
        
        var errorInfo: NSDictionary?
        if let output = NSAppleScript(source: scriptSource)?.executeAndReturnError(&errorInfo),
           let pid = output.stringValue, !pid.isEmpty {
            currentPID = pid
            statusMenuItem.title = "Status: Connected"
            toggleMenuItem.title = "Disconnect"
            statusItem.button?.title = "🟢" // Иконка при подключении
        } else {
            statusMenuItem.title = "Status: Auth Failed"
        }
    }
    
    func stopVPN() {
        guard let pid = currentPID else { return }
        let scriptSource = "do shell script \"kill -9 \(pid)\" with administrator privileges"
        NSAppleScript(source: scriptSource)?.executeAndReturnError(nil)
        currentPID = nil
        statusMenuItem.title = "Status: Ready"
        toggleMenuItem.title = "Connect"
        statusItem.button?.title = "🛡️"
    }
    
    @objc func quitApp() {
        if currentPID != nil { stopVPN() }
        NSApplication.shared.terminate(self)
    }
}
