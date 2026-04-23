# 001 — 标注工具 (Annotation Tools) 实现计划

## 概述

在截图完成后，弹出一个**标注编辑窗口**，用户可以在截图上叠加**箭头、文字、矩形框、序号标记**，编辑完成后保存带标注的最终图片。

> **重要**: 本计划基于对当前代码库的完整分析编写。所有文件路径和接口引用均指向现有实现。

---

## 当前架构分析

当前的截图流程：

```
HotkeyManager → CaptureCoordinator → OverlayWindow/SelectionOverlayView → ScreenCapture → ScreenshotStore
```

详细流程：

1. `HotkeyManager.onHotkeyPressed()` 触发
2. `CaptureCoordinator.startCapture()` 创建全屏透明 `OverlayWindow`
3. `SelectionOverlayView` 显示区域选择覆盖层
4. 用户确认选区后，`onConfirm(rect)` 回调
5. `CaptureCoordinator.finishCapture()` 关闭覆盖层
6. `ScreenCapture.captureRegion(rect, displayID)` 截取屏幕
7. 截图 → 复制到剪贴板 → 保存到磁盘 → 发送通知

**关键插入点**：在 `CaptureCoordinator.swift` 的 `performCapture` 方法中（第99-123行），
截图完成后（`ScreenCapture.captureRegion` 返回 `NSImage`）、保存到磁盘之前，插入标注编辑窗口。

---

## 目标架构

```
截图完成 → 打开标注编辑窗口 → 用户编辑 → 保存带标注的图片
                                  ↓
                            用户跳过标注 → 直接保存原图
```

新的状态机：

```
idle → capturing → annotating (新增) → confirmed → idle
                       ↓
                   cancelled → idle
```

---

## 分阶段实现

### Phase 1：数据模型层 (Annotation Model)

> 新建文件: `Annotation/AnnotationModel.swift`

定义所有标注元素的数据结构。采用 **协议 + 枚举** 的混合设计，便于序列化和 SwiftUI 渲染。

```swift
import SwiftUI

/// 标注元素的唯一标识
typealias AnnotationID = UUID

/// 所有标注类型的枚举
enum AnnotationType: String, CaseIterable {
    case arrow      // 箭头
    case text       // 文字
    case rectangle  // 矩形框
    case stepNumber // 序号标记
}

/// 单个标注元素
struct AnnotationItem: Identifiable {
    let id: AnnotationID = UUID()
    var type: AnnotationType
    
    // 通用属性
    var color: Color = .red
    var lineWidth: CGFloat = 3.0
    var opacity: Double = 1.0
    
    // 空间属性 (相对于图片坐标系，归一化到 0...1)
    var startPoint: CGPoint = .zero   // 起点 (箭头起点 / 矩形左上角)
    var endPoint: CGPoint = .zero     // 终点 (箭头终点 / 矩形右下角)
    
    // 文字专属
    var textContent: String = ""
    var fontSize: CGFloat = 16.0
    var fontWeight: Font.Weight = .medium
    
    // 序号专属
    var stepNumber: Int = 1
    var stepPosition: CGPoint = .zero  // 序号圆圈的中心点
    
    // 交互状态 (不持久化)
    var isSelected: Bool = false
}

/// 标注画布的完整状态
class AnnotationCanvas: ObservableObject {
    @Published var items: [AnnotationItem] = []
    @Published var selectedItemID: AnnotationID? = nil
    @Published var activeTool: AnnotationType = .arrow
    @Published var activeColor: Color = .red
    @Published var activeLineWidth: CGFloat = 3.0
    
    /// 下一个序号 (自动递增)
    var nextStepNumber: Int {
        let maxStep = items
            .filter { $0.type == .stepNumber }
            .map(\.stepNumber)
            .max() ?? 0
        return maxStep + 1
    }
    
    // Undo/Redo 栈
    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []
}
```

**设计决策**：
- 坐标归一化到 `0...1`，这样无论编辑窗口大小如何缩放，标注位置都是正确的
- `AnnotationCanvas` 作为 `ObservableObject`，驱动 SwiftUI 的响应式更新
- 内置 Undo/Redo 栈，每次操作前 snapshot 当前状态

---

### Phase 2：标注渲染层 (Annotation Rendering)

> 新建文件: `Annotation/AnnotationRenderer.swift`

负责将 `AnnotationItem` 数组渲染到 SwiftUI Canvas 或最终合成为 `NSImage`。

#### SwiftUI 渲染层

```swift
/// SwiftUI 视图 — 在图片上叠加所有标注
struct AnnotationOverlayView: View {
    @ObservedObject var canvas: AnnotationCanvas
    let imageSize: CGSize  // 显示区域的实际像素尺寸
    
    var body: some View {
        ZStack {
            ForEach(canvas.items) { item in
                switch item.type {
                case .arrow:
                    ArrowShape(from: denormalize(item.startPoint),
                               to: denormalize(item.endPoint))
                        .stroke(item.color, lineWidth: item.lineWidth)
                case .rectangle:
                    RectangleAnnotation(rect: denormalizedRect(item))
                        .stroke(item.color, lineWidth: item.lineWidth)
                case .text:
                    TextAnnotation(item: item, position: denormalize(item.startPoint))
                case .stepNumber:
                    StepNumberBadge(number: item.stepNumber,
                                    color: item.color,
                                    position: denormalize(item.stepPosition))
                }
            }
        }
    }
}
```

#### 各标注类型的渲染细节

| 类型 | 渲染方式 | 交互方式 |
|:---|:---|:---|
| **箭头** | `Path` + 三角形箭头尖端 (12pt) | 拖拽起点/终点调整方向和长度 |
| **矩形** | `Rectangle().stroke()` + 可选圆角 | 拖拽四角调整大小，拖拽中间移动 |
| **文字** | `TextField` 叠加在画布上 | 双击进入编辑，拖拽移动位置 |
| **序号** | 圆形背景 (28pt) + 居中数字 | 拖拽移动，自动递增编号 |

#### 最终合成 (导出为 NSImage)

```swift
struct AnnotationCompositor {
    /// 将原始截图 + 标注合成为最终图片
    static func composite(
        baseImage: NSImage,
        annotations: [AnnotationItem]
    ) -> NSImage {
        // 1. 创建与原图同尺寸的 NSImage
        // 2. lockFocus
        // 3. 绘制原始图片
        // 4. 遍历 annotations，用 NSBezierPath / NSAttributedString 绘制每个元素
        // 5. unlockFocus
        // 6. 返回合成图
    }
}
```

> **注意**: 合成时必须使用 **原始图片的分辨率**（不是显示尺寸），确保导出的标注图片是高清的。坐标从归一化值 × 原图尺寸反算。

---

### Phase 3：标注编辑窗口 (Annotation Editor Window)

> 新建文件:
> - `Annotation/AnnotationEditorView.swift` — SwiftUI 主视图
> - `Annotation/AnnotationEditorWindow.swift` — NSWindow 容器

这是用户交互的核心界面。

#### 界面结构

```
┌─────────────────────────────────────────────────────┐
│  AnnotationEditorWindow                             │
│ ┌─────────────────────────────────────────────────┐ │
│ │ Toolbar 工具栏                                    │ │
│ │ [🔴箭头] [🔤文字] [▢矩形] [①序号] │ 🎨颜色 │ ↩↪ │ │
│ └─────────────────────────────────────────────────┘ │
│ ┌─────────────────────────────────────────────────┐ │
│ │                                                 │ │
│ │                  Canvas 画布                     │ │
│ │              (底图 + 标注叠加层)                   │ │
│ │                                                 │ │
│ └─────────────────────────────────────────────────┘ │
│ ┌─────────────────────────────────────────────────┐ │
│ │ Action Bar: [✕ 取消] [⌘↵ 跳过标注]     [✓ 保存] │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

#### 工具栏设计

```swift
struct AnnotationToolbar: View {
    @ObservedObject var canvas: AnnotationCanvas
    
    var body: some View {
        HStack(spacing: 2) {
            // 工具按钮组
            ToolButton(icon: "arrow.up.right", tool: .arrow, canvas: canvas)
            ToolButton(icon: "character.textbox", tool: .text, canvas: canvas)
            ToolButton(icon: "rectangle", tool: .rectangle, canvas: canvas)
            ToolButton(icon: "number.circle", tool: .stepNumber, canvas: canvas)
            
            Divider().frame(height: 20)
            
            // 颜色选择 — 5个预设 + 自定义
            ColorPicker(colors: [.red, .orange, .yellow, .green, .blue],
                        selected: $canvas.activeColor)
            
            Divider().frame(height: 20)
            
            // 线宽
            LineWidthPicker(width: $canvas.activeLineWidth)
            
            Spacer()
            
            // 撤销/重做
            Button(action: canvas.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            Button(action: canvas.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
```

工具栏的设计参考 CleanShot X 的风格：
- 紧凑的图标按钮，选中时高亮
- 浮动在编辑窗口顶部
- 支持快捷键切换工具 (A=箭头, T=文字, R=矩形, N=序号)

#### 画布交互手势

```swift
struct AnnotationCanvasView: View {
    @ObservedObject var canvas: AnnotationCanvas
    let baseImage: NSImage
    @State private var dragState: DragState = .idle
    
    enum DragState {
        case idle
        case creating(startPoint: CGPoint)        // 正在创建新标注
        case moving(itemID: AnnotationID)          // 正在移动已有标注
        case resizing(itemID: AnnotationID, handle: HandlePosition)  // 正在调整大小
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 底图
                Image(nsImage: baseImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                
                // 标注覆盖层
                AnnotationOverlayView(canvas: canvas, imageSize: geo.size)
                
                // 选中标注的控制柄 (调整大小)
                if let selectedID = canvas.selectedItemID,
                   let item = canvas.items.first(where: { $0.id == selectedID }) {
                    SelectionHandles(item: item, imageSize: geo.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(canvasGesture(in: geo.size))
            .onTapGesture { location in
                handleTap(at: location, in: geo.size)
            }
        }
    }
}
```

#### 窗口容器

```swift
final class AnnotationEditorWindow: NSWindow {
    init(image: NSImage) {
        // 窗口尺寸：图片等比缩放，最大不超过屏幕的 80%
        let maxSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let scale = min(maxSize.width * 0.8 / image.size.width,
                        maxSize.height * 0.8 / image.size.height,
                        1.0)
        let windowSize = NSSize(width: image.size.width * scale,
                                height: image.size.height * scale + 52) // +52 for toolbar
        
        super.init(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.title = "Annotate Screenshot"
        self.center()
        self.isReleasedWhenClosed = false
    }
}
```

---

### Phase 4：集成到 CaptureCoordinator

> 修改文件: `Core/CaptureCoordinator.swift`

#### 状态机扩展

```diff
 enum CaptureState {
     case idle
     case capturing
+    case annotating    // 新增：标注编辑中
     case confirmed
     case cancelled
 }
```

#### 流程修改

在 `performCapture` 中，截图成功后不再直接保存，而是先打开标注编辑窗口：

```diff
 private func performCapture(rect: CGRect, screen: NSScreen) {
     Task {
         do {
             let image = try await ScreenCapture.captureRegion(rect, displayID: screen.displayID)
-            // Copy to clipboard
-            let pb = NSPasteboard.general
-            pb.clearContents()
-            pb.writeObjects([image])
-            // Save to disk
-            let record = try await screenshotStore.save(image)
+            // 打开标注编辑器
+            state = .annotating
+            openAnnotationEditor(with: image)
         } catch {
             lastError = error
             state = .idle
         }
     }
 }
```

新增方法：

```swift
private var annotationWindow: AnnotationEditorWindow?

private func openAnnotationEditor(with image: NSImage) {
    let canvas = AnnotationCanvas()
    let editorView = AnnotationEditorView(
        baseImage: image,
        canvas: canvas,
        onSave: { [weak self] annotatedImage in
            self?.saveAnnotatedImage(annotatedImage)
        },
        onSaveOriginal: { [weak self] in
            self?.saveAnnotatedImage(image)  // 无标注，直接保存原图
        },
        onCancel: { [weak self] in
            self?.cancelAnnotation()
        }
    )
    
    let window = AnnotationEditorWindow(image: image)
    let hostingView = NSHostingView(rootView: editorView)
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    
    self.annotationWindow = window
}

private func saveAnnotatedImage(_ image: NSImage) {
    annotationWindow?.close()
    annotationWindow = nil
    
    Task {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        
        let record = try await screenshotStore.save(image)
        showNotification(title: "Screenshot Captured",
                         body: "Saved to \(record.url.lastPathComponent)")
        state = .idle
    }
}

private func cancelAnnotation() {
    annotationWindow?.close()
    annotationWindow = nil
    state = .idle
}
```

> **警告**: 注意 `state` 的线程安全性。`CaptureCoordinator` 是 `@MainActor` 的，所有状态变更都在主线程，这是正确的。但 `AnnotationCompositor.composite()` 的图片合成应该在后台线程执行，避免阻塞 UI。

---

### Phase 5：快捷键支持

在标注编辑窗口中监听键盘事件：

| 快捷键 | 功能 |
|:---|:---|
| `A` | 切换到箭头工具 |
| `T` | 切换到文字工具 |
| `R` | 切换到矩形工具 |
| `N` | 切换到序号工具 |
| `⌘Z` | 撤销 |
| `⇧⌘Z` | 重做 |
| `Delete` / `Backspace` | 删除选中的标注 |
| `⌘S` | 保存并关闭 |
| `⌘C` | 复制到剪贴板并关闭 |
| `Escape` | 取消并关闭 |
| `⌘↵` | 保存原图 (跳过标注) |

---

### Phase 6：新增文件结构

完成后的新增文件列表：

```
capture-your-screen/
├── Annotation/                          ← 新增目录
│   ├── AnnotationModel.swift            ← 数据模型 (AnnotationItem, AnnotationCanvas)
│   ├── AnnotationRenderer.swift         ← 渲染各类标注的 SwiftUI Shape
│   ├── AnnotationCompositor.swift       ← 合成最终图片 (NSImage 绘制)
│   ├── AnnotationEditorView.swift       ← 编辑窗口主视图
│   ├── AnnotationEditorWindow.swift     ← NSWindow 容器
│   ├── AnnotationToolbar.swift          ← 工具栏 UI
│   ├── AnnotationCanvasView.swift       ← 画布 + 手势交互
│   └── Shapes/                          ← 标注形状子目录
│       ├── ArrowShape.swift             ← 箭头 Path
│       ├── StepNumberBadge.swift        ← 序号圆圈
│       └── SelectionHandles.swift       ← 选中控制柄
├── Core/
│   └── CaptureCoordinator.swift         ← 修改：增加 .annotating 状态
```

---

## 实现顺序与工作量估计

| 阶段 | 内容 | 估计工时 | 依赖 |
|:---|:---|:---|:---|
| **Phase 1** | 数据模型 | 2h | 无 |
| **Phase 2** | 渲染层 (箭头、矩形、文字、序号) | 6h | Phase 1 |
| **Phase 3** | 编辑窗口 + 工具栏 + 手势交互 | 8h | Phase 1, 2 |
| **Phase 4** | 集成到 CaptureCoordinator | 2h | Phase 3 |
| **Phase 5** | 快捷键支持 | 1h | Phase 3 |
| **Phase 6** | 打磨 + 测试 | 3h | 全部 |
| | **总计** | **~22h** | |

---

## 验收标准 (Acceptance Criteria)

- [ ] 截图后自动弹出标注编辑窗口
- [ ] 可以画**箭头**：拖拽绘制，有清晰的三角形箭头尖端
- [ ] 可以画**矩形框**：拖拽绘制，支持调整大小和移动
- [ ] 可以添加**文字**：点击画布后弹出文字输入，支持拖拽移动
- [ ] 可以添加**序号**：点击画布自动放置下一个编号 (①②③…)，支持拖拽移动
- [ ] 支持**颜色选择**：至少 5 种预设颜色
- [ ] 支持**撤销/重做** (⌘Z / ⇧⌘Z)
- [ ] 支持**删除**选中的标注元素
- [ ] 保存后的图片是**高清的** (与原始截图分辨率一致)
- [ ] 保存后自动**复制到剪贴板** + 写入磁盘
- [ ] 可以选择**跳过标注**直接保存原图
- [ ] 编辑窗口支持键盘快捷键切换工具
