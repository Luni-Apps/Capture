//
//  View_onCaptureEventInteraction.swift
//
//
//  Created by Quentin Fasquel on 27/05/2024.
//

import AVKit
import SwiftUI

@available(iOS 17.2, *)
typealias AVCaptureEventInteractionHandler = ((AVCaptureEvent) -> Void)

@available(iOS 17.2, *)
struct CaptureEventInteractionView: UIViewRepresentable {
    private enum Storage {
        case single(AVCaptureEventInteractionHandler)
        case pair(AVCaptureEventInteractionHandler, AVCaptureEventInteractionHandler)
    }

    private let storage: Storage
    var isEnabled: Bool

    init(
        isEnabled: Bool,
        handler: @escaping AVCaptureEventInteractionHandler
    ) {
        self.isEnabled = isEnabled
        self.storage = .single(handler)
    }

    init(
        isEnabled: Bool,
        primary: @escaping AVCaptureEventInteractionHandler,
        secondary: @escaping AVCaptureEventInteractionHandler
    ) {
        self.isEnabled = isEnabled
        self.storage = .pair(primary, secondary)
    }

    private func makeInteraction() -> AVCaptureEventInteraction {
        switch storage {
            case .single(let handler):
                return AVCaptureEventInteraction(handler: handler)
            case .pair(let primary, let secondary):
                return AVCaptureEventInteraction(primary: primary, secondary: secondary)
        }
    }

    // MARK: - View Representable

    class Coordinator {
        var interaction: AVCaptureEventInteraction?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        UIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let interaction = context.coordinator.interaction {
            interaction.isEnabled = isEnabled
        } else {
            let interaction = makeInteraction()
            interaction.isEnabled = isEnabled
            uiView.addInteraction(interaction)
            context.coordinator.interaction = interaction
        }
    }
}

public enum CaptureEventPhase: UInt, @unchecked Sendable {
    case began = 0, ended = 1, cancelled = 2

    @available(iOS 17.2, *)
    fileprivate init(phase: AVCaptureEventPhase) {
        switch phase {
            case .began: self = .began
            case .ended: self = .ended
            case .cancelled: self = .cancelled
            @unknown default: self = .cancelled
        }
    }
}

public struct CaptureEvent {
    public let phase: CaptureEventPhase

    @available(iOS 17.2, *)
    fileprivate init(_ event: AVCaptureEvent) {
        self.phase = .init(phase: event.phase)
    }
}

extension View {

    @ViewBuilder
    public func onCaptureEventInteraction(
        isEnabled: Bool = true,
        _ handler: @escaping ((CaptureEvent) -> Void)
    ) -> some View {
        if #available(iOS 17.2, *) {
            self.background(CaptureEventInteractionView(isEnabled: isEnabled, handler: { event in
                handler(CaptureEvent(event))
            }))
        } else {
            self
        }
    }

    @ViewBuilder
    public func onCaptureEventInteraction(
        isEnabled: Bool = true,
        volumeUp: @escaping ((CaptureEvent) -> Void),
        volumeDown: @escaping ((CaptureEvent) -> Void)
    ) -> some View {
        if #available(iOS 17.2, *) {
            self.background(CaptureEventInteractionView(isEnabled: isEnabled, primary: { event in
                volumeDown(CaptureEvent(event))
            }, secondary: { event in
                volumeUp(CaptureEvent(event))
            }))
        } else {
            self
        }
    }

}
