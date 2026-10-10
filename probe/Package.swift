// swift-tools-version: 6.4
import PackageDescription

// 階段 2a/2b 的主佇列探針：只依賴 VanguardSwiftExtension，不接引擎。
let package = Package(
  name: "VGProbe",
  products: [
    .library(name: "VGProbe", type: .dynamic, targets: ["VGProbe"]),
  ],
  dependencies: [
    .package(path: "../vendor/vChewing-LibVanguard/Deps/VanguardSwiftExtension"),
  ],
  targets: [
    .target(
      name: "VGProbe",
      dependencies: [
        .product(name: "VanguardSwiftExtension", package: "VanguardSwiftExtension"),
      ]
    ),
  ]
)
