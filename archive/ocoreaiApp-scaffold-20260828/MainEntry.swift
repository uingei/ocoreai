// Main entry point: ocoreaiApp (appx) product.
// App body (OcoreaiApp, AppDelegate, AppState, AppTab...) 全部在 lm target (Sources/ocoreai),
// 这里只承载 @main 启动调用, 与 mlx-swift-lm (library+executable 双 target) 结构对齐。
import ocoreai

OcoreaiApp.main()
