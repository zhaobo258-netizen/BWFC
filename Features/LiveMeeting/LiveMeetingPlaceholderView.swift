import SwiftUI

/// 会中界面占位（康奈尔三分区与状态栏将在阶段 1–4 逐步实现）
struct LiveMeetingPlaceholderView: View {
    @Environment(AppRouter.self) private var router
    let meetingID: UUID

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("会中界面")
                .font(.title2)
                .fontWeight(.semibold)
            Text("录音、同声转写、左侧结构总结与右侧谈判分析\n将在阶段 1–4 逐步实现。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("返回会议列表") {
                router.showMeetingList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("会中")
    }
}
