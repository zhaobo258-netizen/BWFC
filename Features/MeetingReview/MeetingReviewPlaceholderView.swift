import SwiftUI

/// 会后查看占位（完整转写、回放、修订、导出与删除将在阶段 5 实现）
struct MeetingReviewPlaceholderView: View {
    @Environment(AppRouter.self) private var router
    let meetingID: UUID

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("会后整理")
                .font(.title2)
                .fontWeight(.semibold)
            Text("完整转写、证据回放、Markdown / JSON 导出与会议删除\n将在阶段 5 实现。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("返回会议列表") {
                router.showMeetingList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("会后")
    }
}
