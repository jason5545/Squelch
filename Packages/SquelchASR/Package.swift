// swift-tools-version: 5.10
// Squelch 的即時字幕用的語音辨識（Qwen3-ASR，跑在 MLX 上）。
// 獨立成套件：MLX 的程式碼用 Swift 5 模式編，不受 App 的 Swift 6／預設主執行緒隔離影響。

import PackageDescription

let package = Package(
    name: "SquelchASR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SquelchASR", targets: ["SquelchASR"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3")
    ],
    targets: [
        .target(
            name: "SquelchASR",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift")
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        )
    ]
)
