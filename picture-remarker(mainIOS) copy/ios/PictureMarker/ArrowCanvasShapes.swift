import SwiftUI

struct LineShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }
}

struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let headLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        guard let headPoints = AnnotationRenderingGeometry.arrowHeadPoints(
            start: start,
            end: end,
            headLength: headLength
        ) else {
            return path
        }

        path.move(to: end)
        path.addLine(to: headPoints.first)
        path.move(to: end)
        path.addLine(to: headPoints.second)
        return path
    }
}

struct ArrowHitAreaShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let hitWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = hypot(deltaX, deltaY)
        let halfWidth = hitWidth / 2

        guard length > 0 else {
            return Path(
                ellipseIn: CGRect(
                    x: start.x - halfWidth,
                    y: start.y - halfWidth,
                    width: hitWidth,
                    height: hitWidth
                )
            )
        }

        let unitX = deltaX / length
        let unitY = deltaY / length
        let perpendicularX = -unitY * halfWidth
        let perpendicularY = unitX * halfWidth
        let extendedStart = CGPoint(
            x: start.x - unitX * halfWidth,
            y: start.y - unitY * halfWidth
        )
        let extendedEnd = CGPoint(
            x: end.x + unitX * halfWidth,
            y: end.y + unitY * halfWidth
        )

        var path = Path()
        path.move(
            to: CGPoint(
                x: extendedStart.x + perpendicularX,
                y: extendedStart.y + perpendicularY
            )
        )
        path.addLine(
            to: CGPoint(
                x: extendedEnd.x + perpendicularX,
                y: extendedEnd.y + perpendicularY
            )
        )
        path.addLine(
            to: CGPoint(
                x: extendedEnd.x - perpendicularX,
                y: extendedEnd.y - perpendicularY
            )
        )
        path.addLine(
            to: CGPoint(
                x: extendedStart.x - perpendicularX,
                y: extendedStart.y - perpendicularY
            )
        )
        path.closeSubpath()
        return path
    }
}
