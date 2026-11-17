// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacBlock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "macblock-agent", targets: ["MacBlockAgent"])],
    targets: [.executableTarget(
        name: "MacBlockAgent",
        path: "agent",
        exclude: ["install.sh", "com.macblock.agent.plist"],
        sources: ["main.swift"],
        linkerSettings: [.linkedFramework("Security")]
    )]
)
