import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory означает, что приложение не появится в Dock (только в верхнем меню)
app.setActivationPolicy(.accessory)
app.run()