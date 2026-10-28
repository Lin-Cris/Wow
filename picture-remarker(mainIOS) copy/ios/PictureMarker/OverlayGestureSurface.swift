import SwiftUI
import UIKit

struct OverlayGestureSurface: UIViewRepresentable {
    @Binding var layer: OverlayImageLayer
    let displayScale: CGFloat
    let originalImageSize: CGSize
    let isAccessibilityElement: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    let onEditingBegan: () -> Void
    let onSelect: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = isAccessibilityElement
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityHint = accessibilityHint

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        let rotation = UIRotationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRotation(_:))
        )
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )

        pan.delegate = context.coordinator
        pinch.delegate = context.coordinator
        rotation.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(rotation)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        uiView.isAccessibilityElement = isAccessibilityElement
        uiView.accessibilityLabel = accessibilityLabel
        uiView.accessibilityHint = accessibilityHint
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: OverlayGestureSurface
        private var panStartCenter = CGPoint.zero
        private var pinchStartSize = CGSize.zero
        private var rotationStart: CGFloat = 0
        private var activeEditingGestures: Set<ObjectIdentifier> = []

        init(parent: OverlayGestureSurface) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onSelect()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.displayScale > 0 else { return }

            if recognizer.state == .began {
                beginEditing(with: recognizer)
                parent.onSelect()
                panStartCenter = CGPoint(
                    x: parent.layer.centerX,
                    y: parent.layer.centerY
                )
            }

            if recognizer.state == .ended ||
                recognizer.state == .cancelled ||
                recognizer.state == .failed {
                endEditing(with: recognizer)
                return
            }

            guard recognizer.state == .began || recognizer.state == .changed else {
                return
            }

            let translation = recognizer.translation(in: recognizer.view?.window)
            parent.layer.centerX = min(
                max(panStartCenter.x + translation.x / parent.displayScale, 0),
                parent.originalImageSize.width
            )
            parent.layer.centerY = min(
                max(panStartCenter.y + translation.y / parent.displayScale, 0),
                parent.originalImageSize.height
            )
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began {
                beginEditing(with: recognizer)
                parent.onSelect()
                pinchStartSize = CGSize(
                    width: parent.layer.width,
                    height: parent.layer.height
                )
            }

            if recognizer.state == .ended ||
                recognizer.state == .cancelled ||
                recognizer.state == .failed {
                endEditing(with: recognizer)
                return
            }

            guard recognizer.state == .began || recognizer.state == .changed else {
                return
            }

            guard parent.displayScale > 0 else { return }

            let minimumShortEdge =
                minimumOverlayDisplayShortEdge / parent.displayScale
            let maximumLongEdge = max(
                parent.originalImageSize.width,
                parent.originalImageSize.height
            ) * 3
            let originalShortEdge = min(pinchStartSize.width, pinchStartSize.height)
            let originalLongEdge = max(pinchStartSize.width, pinchStartSize.height)
            guard originalShortEdge > 0, originalLongEdge > 0 else { return }

            let minimumScale = minimumShortEdge / originalShortEdge
            let maximumScale = maximumLongEdge / originalLongEdge
            let constrainedScale = min(
                max(recognizer.scale, minimumScale),
                maximumScale
            )

            parent.layer.width = pinchStartSize.width * constrainedScale
            parent.layer.height = pinchStartSize.height * constrainedScale
        }

        @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
            if recognizer.state == .began {
                beginEditing(with: recognizer)
                parent.onSelect()
                rotationStart = parent.layer.rotation
            }

            if recognizer.state == .ended ||
                recognizer.state == .cancelled ||
                recognizer.state == .failed {
                endEditing(with: recognizer)
                return
            }

            guard recognizer.state == .began || recognizer.state == .changed else {
                return
            }

            parent.layer.rotation = normalizedAngle(
                rotationStart + recognizer.rotation
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            let isPinchAndRotation =
                (gestureRecognizer is UIPinchGestureRecognizer &&
                    otherGestureRecognizer is UIRotationGestureRecognizer) ||
                (gestureRecognizer is UIRotationGestureRecognizer &&
                    otherGestureRecognizer is UIPinchGestureRecognizer)
            return isPinchAndRotation
        }

        private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
            var result = angle.truncatingRemainder(dividingBy: .pi * 2)
            if result > .pi {
                result -= .pi * 2
            } else if result < -.pi {
                result += .pi * 2
            }
            return result
        }

        private func beginEditing(with recognizer: UIGestureRecognizer) {
            let identifier = ObjectIdentifier(recognizer)
            guard activeEditingGestures.insert(identifier).inserted else { return }

            if activeEditingGestures.count == 1 {
                parent.onEditingBegan()
            }
        }

        private func endEditing(with recognizer: UIGestureRecognizer) {
            activeEditingGestures.remove(ObjectIdentifier(recognizer))
        }
    }
}
