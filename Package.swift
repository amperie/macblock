// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "orbit-agent", targets: ["OrbitAgent"])],
    targets: [.executableTarget(
        name: "OrbitAgent",
        path: "agent",
        exclude: ["install.sh", "install-monitor.sh", "com.side-forge.orbit.agent.plist", "com.side-forge.orbit.foreground.plist", "FocusTracker.swift", "ForegroundMonitor.swift"],
        sources: ["main.swift"],
        linkerSettings: [.linkedFramework("Security")]
    )]
)
