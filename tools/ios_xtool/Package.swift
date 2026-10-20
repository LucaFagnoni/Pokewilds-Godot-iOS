// swift-tools-version: 6.0
// The app xtool builds: an empty Swift target linked against Godot's iOS engine
// library, which brings main(). build_ipa.sh exports the game's Xcode project
// next to this file, so the two .xcframeworks below come from that export.
import PackageDescription

let package = Package(
    name: "Pokewilds",
    platforms: [.iOS("15.0")],
    products: [.library(name: "Pokewilds", targets: ["Pokewilds"])],
    targets: [
        // Swift, empty: the engine has Swift code, so the app needs the Swift runtime.
        .target(
            name: "Pokewilds",
            dependencies: ["GodotPlugins", "GodotEngine", "MoltenVK"],
            linkerSettings: [.unsafeFlags([
                // The engine's Swift code auto-links SwiftUICore, which only iOS 18+
                // has; Apple's linker skips it and binds through SwiftUI, lld must be told.
                "-Xlinker", "--ignore-auto-link-option=SwiftUICore",
                // The stripped engine is LTO bitcode: keep lld's codegen in the
                // work folder's cache, so links after the first take seconds.
                "-Xlinker", "-cache_path_lto", "-Xlinker", Context.packageDirectory + "/../cache/lto",
            ])]
        ),
        // The export's dummy.cpp: the plugin init functions the engine calls (C++).
        .target(name: "GodotPlugins", publicHeadersPath: "."),
        .binaryTarget(name: "GodotEngine", path: "Pokewilds.xcframework"),
        .binaryTarget(name: "MoltenVK", path: "MoltenVK.xcframework"),
    ]
)
