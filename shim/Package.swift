// swift-tools-version: 6.4
import PackageDescription

// 階段 2c：把引擎包成最小 C API（建立 session、送按鍵、取回組字區與送出的字）。
let package = Package(
  name: "VGShim",
  products: [
    .library(name: "VGShim", type: .dynamic, targets: ["VGShim"]),
  ],
  dependencies: [
    .package(path: "../vendor/vChewing-LibVanguard"),
  ],
  targets: [
    .target(
      name: "VGShim",
      dependencies: [
        .product(name: "Vanguard", package: "vChewing-LibVanguard"),
      ],
      swiftSettings: [
        // 跟上游一致：session 相關型別全都隔離在 MainActor。
        .defaultIsolation(MainActor.self),
      ]
    ),
  ]
)
