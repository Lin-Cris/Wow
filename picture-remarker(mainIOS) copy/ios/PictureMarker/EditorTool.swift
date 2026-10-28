enum EditorTool: String {
    case select
    case rectangle
    case line
    case arrow
    case ellipse
    case mosaic

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .ellipse: "oval"
        case .mosaic: "square.grid.3x3.fill"
        }
    }

    var hint: String {
        switch self {
        case .select: "轻点标注编辑，拖动标注移动"
        case .rectangle: "在图片上拖动以创建矩形"
        case .line: "从起点拖向终点以创建直线"
        case .arrow: "从起点拖向终点以创建箭头"
        case .ellipse: "在图片上拖动以创建椭圆"
        case .mosaic: "在图片上拖动以涂抹马赛克"
        }
    }
}
