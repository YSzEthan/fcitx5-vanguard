// swift-tools-version: 6.4
import PackageDescription

// 引擎的 C 匯出層：fcitx5 外掛（C++）透過 include/vanguard.h 呼叫這顆動態庫。
let package = Package(
  name: "VGEngine",
  products: [
    .library(name: "VGEngine", type: .dynamic, targets: ["VGEngine"]),
  ],
  dependencies: [
    .package(path: "../vendor/vChewing-LibVanguard"),
  ],
  targets: [
    .target(
      name: "VGEngine",
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
