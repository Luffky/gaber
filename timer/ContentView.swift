//
//  ContentView.swift
//  timer
//
//  Created by ByteDance on 2026/7/12.
//

import SwiftUI
import UIKit

enum SettingsKeys {
    static let keepScreenAwake = "keepScreenAwake"
    static let showMilliseconds = "showMilliseconds"
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SettingsKeys.keepScreenAwake) private var keepScreenAwake = true
    @AppStorage(SettingsKeys.showMilliseconds) private var showMilliseconds = true

    @State private var cardOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var containerSize: CGSize = .zero
    @StateObject private var pictureInPicture = PictureInPictureClock()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.035, blue: 0.07), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer()

                clockCard
                    .offset(cardOffset)
                    .gesture(dragGesture)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.35)) {
                            cardOffset = .zero
                            dragStartOffset = .zero
                        }
                    }

                Spacer()

                controls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            containerSize = newSize
            cardOffset = clampedOffset(cardOffset)
            dragStartOffset = cardOffset
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: updateIdleTimer)
        .alert("提示", isPresented: Binding(
            get: { pictureInPicture.errorMessage != nil },
            set: { if !$0 { pictureInPicture.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(pictureInPicture.errorMessage ?? "")
        }
        .onChange(of: keepScreenAwake) { _, _ in updateIdleTimer() }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active && keepScreenAwake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("秒杀时钟")
                    .font(.title2.bold())
                Text("与系统时间实时同步")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("本机时间", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.green.opacity(0.12), in: Capsule())
        }
    }

    private var clockCard: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            PreciseClockView(date: context.date, showMilliseconds: showMilliseconds)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .cyan.opacity(0.18), radius: 28, y: 12)
        // AVPictureInPictureController 要求源显示层已挂载到可见窗口。
        // 放在卡片背景中既能满足系统要求，也不会覆盖 SwiftUI 时钟。
        .background {
            PictureInPicturePreview(displayLayer: pictureInPicture.displayLayer)
                .allowsHitTesting(false)
                .opacity(0.001)
        }
        // .combine 让 VoiceOver 朗读卡片内实时更新的日期与时间；
        // 不要再叠加 accessibilityLabel，否则会覆盖掉时间内容。
        .accessibilityElement(children: .combine)
        .accessibilityHint("拖动可以移动时钟，双击可将时钟复位")
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Button {
                pictureInPicture.toggle()
            } label: {
                Label(
                    pictureInPicture.isActive ? "关闭跨 App 悬浮窗" : "开启跨 App 悬浮窗",
                    systemImage: pictureInPicture.isActive ? "pip.exit" : "pip.enter"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(pictureInPicture.isActive ? .orange : .cyan)
            .disabled(!pictureInPicture.isAvailable)

            Divider()

            Toggle(isOn: $showMilliseconds) {
                Label("显示毫秒", systemImage: "timer")
            }

            Divider()

            Toggle(isOn: $keepScreenAwake) {
                Label("保持屏幕常亮", systemImage: "sun.max.fill")
            }
        }
        .font(.subheadline.weight(.medium))
        .tint(.cyan)
        .padding(18)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                cardOffset = clampedOffset(CGSize(
                    width: dragStartOffset.width + value.translation.width,
                    height: dragStartOffset.height + value.translation.height
                ))
            }
            .onEnded { _ in
                dragStartOffset = cardOffset
            }
    }

    /// 限制拖动范围，保证时钟卡片始终有一部分留在屏幕内，不会被拖丢。
    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0 else { return proposed }
        let maxX = containerSize.width * 0.4
        let maxY = containerSize.height * 0.35
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }
}

private struct PreciseClockView: View {
    let date: Date
    let showMilliseconds: Bool

    private var components: DateComponents {
        Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
    }

    private var dateText: String {
        String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private var timeText: String {
        String(
            format: "%02d:%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    private var millisecondText: String {
        String(format: ".%03d", (components.nanosecond ?? 0) / 1_000_000)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(dateText)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    clockText(size: 48)
                }

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    clockText(size: 40)
                }
            }

            Text("拖动可移动 · 双击复位")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func clockText(size: CGFloat) -> some View {
        Text(timeText)
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .monospacedDigit()

        if showMilliseconds {
            Text(millisecondText)
                .font(.system(size: size * 0.48, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.cyan)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
