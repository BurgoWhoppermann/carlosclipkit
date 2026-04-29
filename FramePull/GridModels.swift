import Foundation
import CoreGraphics

// MARK: - Layout

/// Cell arrangement for a grid: cols × rows.
struct GridLayout: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let cols: Int
    let rows: Int
    var slots: Int { cols * rows }

    static let oneByOne   = GridLayout(name: "1×1", cols: 1, rows: 1)
    static let oneByTwo   = GridLayout(name: "1×2", cols: 1, rows: 2)
    static let twoByOne   = GridLayout(name: "2×1", cols: 2, rows: 1)
    static let oneByThree = GridLayout(name: "1×3", cols: 1, rows: 3)
    static let threeByOne = GridLayout(name: "3×1", cols: 3, rows: 1)
    static let twoByTwo   = GridLayout(name: "2×2", cols: 2, rows: 2)
    static let twoByThree = GridLayout(name: "2×3", cols: 2, rows: 3)
    static let threeByTwo = GridLayout(name: "3×2", cols: 3, rows: 2)

    static let all: [GridLayout] = [
        .oneByOne, .oneByTwo, .twoByOne, .oneByThree, .threeByOne, .twoByTwo, .twoByThree, .threeByTwo
    ]
}

// MARK: - Output ratio

/// Output canvas aspect ratio. Always renders at 1080 on the shorter side.
struct OutputRatio: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let width: CGFloat
    let height: CGFloat
    var aspectRatio: CGFloat { width / height }

    /// Resolved canvas size. Default short side is 2160 — this lands 9:16 grids at
    /// 2160×3840 (true 4K vertical), 1:1 at 2160×2160, and 16:9 at 3840×2160.
    func outputSize(shortSide: CGFloat = 2160) -> CGSize {
        return width >= height
            ? CGSize(width: shortSide * width / height, height: shortSide)
            : CGSize(width: shortSide, height: shortSide * height / width)
    }

    static let square   = OutputRatio(name: "1:1",  width: 1, height: 1)
    static let fourFive = OutputRatio(name: "4:5",  width: 4, height: 5)
    static let nineSixteen = OutputRatio(name: "9:16", width: 9, height: 16)
    static let sixteenNine = OutputRatio(name: "16:9", width: 16, height: 9)

    static let all: [OutputRatio] = [.square, .fourFive, .nineSixteen, .sixteenNine]
}

// MARK: - Cell source

/// What a grid cell shows. References by ID so transforms survive cell reordering.
enum GridCellSource: Equatable, Hashable {
    case still(UUID)
    case clip(UUID)

    var isClip: Bool {
        if case .clip = self { return true }
        return false
    }
}

// MARK: - Cell transform

/// Per-cell pan & zoom, resolution-independent.
struct CellTransform: Equatable, Hashable {
    /// Horizontal pan, normalized [-1, 1] within the cell's slack room
    var offsetX: CGFloat = 0
    /// Vertical pan, normalized [-1, 1]
    var offsetY: CGFloat = 0
    /// Zoom factor, 1.0 = base fill, max 4.0
    var scale: CGFloat = 1.0

    static let identity = CellTransform()

    /// Computes the source-image draw rect inside a given cell rect.
    /// Single source of truth for crop math — used by both preview and export so they always match.
    func drawRect(srcSize: CGSize, cellRect: CGRect) -> CGRect {
        let baseScale = max(cellRect.width / srcSize.width,
                            cellRect.height / srcSize.height)
        let baseW = srcSize.width  * baseScale
        let baseH = srcSize.height * baseScale
        let s = max(1.0, min(4.0, scale))
        let scaledW = baseW * s
        let scaledH = baseH * s
        let maxPanX = max(0, (scaledW - cellRect.width)  / 2)
        let maxPanY = max(0, (scaledH - cellRect.height) / 2)
        let cx = cellRect.midX + maxPanX * max(-1, min(1, offsetX))
        let cy = cellRect.midY + maxPanY * max(-1, min(1, offsetY))
        return CGRect(x: cx - scaledW / 2,
                      y: cy - scaledH / 2,
                      width: scaledW,
                      height: scaledH)
    }
}

// MARK: - Grid config

/// One grid configuration. A session may have many.
///
/// **Sparse cells:** `selectedCells.count` is always `layout.slots`. Empty positions are `nil`,
/// so removing a cell at index N leaves a hole at N — other cells don't shift.
struct GridConfig: Identifiable, Equatable {
    let id: UUID
    var layout: GridLayout {
        didSet { resizeCellsForLayout() }
    }
    var ratio: OutputRatio
    /// One entry per slot in row-major order. Length is always `layout.slots`. `nil` = empty.
    private(set) var selectedCells: [GridCellSource?]
    /// Per-cell pan/zoom — keyed by source so transforms persist across reorders.
    var cellTransforms: [GridCellSource: CellTransform] = [:]
    /// Per-clip-cell loop count. Output duration = max(clip.duration × loopCount).
    /// Stills are unaffected. Missing key means 1× (default behavior).
    var cellLoopCounts: [GridCellSource: Int] = [:]

    init(id: UUID = UUID(),
         layout: GridLayout = .oneByThree,
         ratio: OutputRatio = .nineSixteen,
         selectedCells: [GridCellSource?] = [],
         cellTransforms: [GridCellSource: CellTransform] = [:],
         cellLoopCounts: [GridCellSource: Int] = [:]) {
        self.id = id
        self.layout = layout
        self.ratio = ratio
        // Pad / truncate to layout.slots so the invariant holds from construction.
        var cells = selectedCells
        if cells.count < layout.slots {
            cells.append(contentsOf: Array(repeating: nil, count: layout.slots - cells.count))
        } else if cells.count > layout.slots {
            cells = Array(cells.prefix(layout.slots))
        }
        self.selectedCells = cells
        self.cellTransforms = cellTransforms
        self.cellLoopCounts = cellLoopCounts
    }

    private mutating func resizeCellsForLayout() {
        if selectedCells.count < layout.slots {
            selectedCells.append(contentsOf: Array(repeating: nil, count: layout.slots - selectedCells.count))
        } else if selectedCells.count > layout.slots {
            // Drop trailing slots when the layout shrinks.
            let dropped = selectedCells[layout.slots...].compactMap { $0 }
            selectedCells = Array(selectedCells.prefix(layout.slots))
            // Forget transforms / loop counts for sources that no longer exist anywhere.
            for source in dropped where !selectedCells.contains(source) {
                cellTransforms.removeValue(forKey: source)
                cellLoopCounts.removeValue(forKey: source)
            }
        }
    }

    /// All non-nil cells, preserving slot order.
    var filledCells: [GridCellSource] { selectedCells.compactMap { $0 } }

    /// All filled cells with their slot index, preserving slot order.
    var indexedFilledCells: [(index: Int, source: GridCellSource)] {
        selectedCells.enumerated().compactMap { idx, src in src.map { (idx, $0) } }
    }

    /// Cell at slot, or nil if empty / out of bounds.
    func cell(at index: Int) -> GridCellSource? {
        guard selectedCells.indices.contains(index) else { return nil }
        return selectedCells[index]
    }

    /// First empty slot index, or nil if grid is full.
    var firstEmptyIndex: Int? { selectedCells.firstIndex(where: { $0 == nil }) }

    /// Number of filled slots.
    var filledCount: Int { filledCells.count }

    /// True when every slot has a source assigned.
    var isComplete: Bool { selectedCells.allSatisfy { $0 != nil } }

    /// True if any filled cell sources a clip (export becomes video).
    var containsClip: Bool { filledCells.contains(where: \.isClip) }

    /// Place `source` at `index`. Returns the cell that was previously there (if any).
    @discardableResult
    mutating func setCell(_ source: GridCellSource?, at index: Int) -> GridCellSource? {
        guard selectedCells.indices.contains(index) else { return nil }
        let previous = selectedCells[index]
        selectedCells[index] = source
        // Drop transforms / loop counts for sources that no longer appear anywhere.
        if let previous, previous != source, !selectedCells.contains(previous) {
            cellTransforms.removeValue(forKey: previous)
            cellLoopCounts.removeValue(forKey: previous)
        }
        return previous
    }

    /// Swap the contents of two slots.
    mutating func swapCells(_ a: Int, _ b: Int) {
        guard selectedCells.indices.contains(a), selectedCells.indices.contains(b), a != b else { return }
        selectedCells.swapAt(a, b)
    }

    /// Find the slot index containing `source`, if any.
    func index(of source: GridCellSource) -> Int? {
        selectedCells.firstIndex(of: source)
    }

    /// True if `source` is currently in any slot.
    func contains(_ source: GridCellSource) -> Bool {
        selectedCells.contains(source)
    }

    /// Cell rect for a given index inside an output canvas (zero gutter; thin gutters added at draw time if desired).
    func cellRect(index: Int, in canvas: CGSize, gutter: CGFloat = 0) -> CGRect {
        let col = index % layout.cols
        let row = index / layout.cols
        let cellW = (canvas.width  - gutter * CGFloat(layout.cols + 1)) / CGFloat(layout.cols)
        let cellH = (canvas.height - gutter * CGFloat(layout.rows + 1)) / CGFloat(layout.rows)
        let x = gutter + CGFloat(col) * (cellW + gutter)
        let y = gutter + CGFloat(row) * (cellH + gutter)
        return CGRect(x: x, y: y, width: cellW, height: cellH)
    }

    func transform(for source: GridCellSource) -> CellTransform {
        cellTransforms[source] ?? .identity
    }

    /// Loop count for a clip cell (1–8). Stills always return 1 (no looping concept).
    func loopCount(for source: GridCellSource) -> Int {
        guard case .clip = source else { return 1 }
        let raw = cellLoopCounts[source] ?? 1
        return max(1, min(8, raw))
    }
}
