import Foundation

// M4 损坏恢复演练（欠账清理）：验证 projects.json 解码失败后的完整人工恢复路径。
// 只在临时目录里操作调用方传入的副本，绝不触碰真实容器目录。
//
// 用法：BangWoFenXiDrill <工作目录>（该目录下须已有一份 projects.json 副本）

let args = CommandLine.arguments
guard args.count > 1 else {
    print("DRILL FAIL: 缺少工作目录参数")
    exit(1)
}
let workDir = URL(fileURLWithPath: args[1], isDirectory: true)
let projectsURL = workDir.appending(path: "projects.json", directoryHint: .notDirectory)

var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if condition { print("  ok  \(message)") } else { failures.append(message) }
}

func backupFileNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        .filter { $0.hasPrefix("projects.corrupt-") }
        .sorted()
}

do {
    // 步骤 0：健康基线——先确认副本本身能读，否则后面的「损坏」结论不成立
    let healthyBytes = try Data(contentsOf: projectsURL)
    let baselineCount = try JSONProjectStore(directory: workDir).loadProjects().count
    print("==> 基线：副本 \(healthyBytes.count) 字节，\(baselineCount) 个项目可正常读取")
    check(baselineCount > 0, "基线副本至少有一个项目")

    // 步骤 1：制造损坏——截断成半个 JSON（最接近「写入中崩溃」的真实损坏形态）
    let corruptBytes = healthyBytes.prefix(healthyBytes.count / 2)
    try corruptBytes.write(to: projectsURL, options: .atomic)
    print("==> 已把副本截断为 \(corruptBytes.count) 字节（模拟写入中崩溃）")

    // 步骤 2：损坏读取——必须抛出带备份文件名的 dataCorrupted，而不是静默返回空库
    let store = try JSONProjectStore(directory: workDir)
    var reportedBackupName: String?
    do {
        _ = try store.loadProjects()
        failures.append("损坏文件竟然读取成功，未抛出 dataCorrupted")
    } catch let ProjectStoreError.dataCorrupted(backupFileName) {
        reportedBackupName = backupFileName
        check(backupFileName != nil, "抛出 dataCorrupted 且带回备份文件名")
    } catch {
        failures.append("抛出的不是 dataCorrupted：\(type(of: error))")
    }

    // 步骤 3：备份完整性——备份里必须是原始损坏字节，一个 byte 都不能被改写
    let backups = try backupFileNames()
    check(backups.count == 1, "生成了恰好 1 份损坏备份（实际 \(backups.count)）")
    if let name = reportedBackupName {
        check(backups.first == name, "备份文件名与界面提示一致：\(name)")
        let backupBytes = try Data(contentsOf: workDir.appending(path: name, directoryHint: .notDirectory))
        check(backupBytes == corruptBytes, "备份保留了原始损坏字节（\(backupBytes.count) 字节）")
    }
    check(!FileManager.default.fileExists(atPath: projectsURL.path),
          "原 projects.json 已被移走（不是复制后留下损坏原件）")

    // 步骤 4：备份完成后可安全重建空库——这是用户重启 App 后应看到的状态
    let rebuilt = try JSONProjectStore(directory: workDir)
    check(try rebuilt.loadProjects().isEmpty, "备份完成后读取得到空库而非再次抛错")
    try rebuilt.saveProjects([])
    check(FileManager.default.fileExists(atPath: projectsURL.path), "空库可以正常写回磁盘")

    // 步骤 5：人工恢复——这一步是演练的真正目的。
    // 真实恢复手段：修好备份文件的 JSON 后改名回 projects.json。
    // 演练用「把截断的备份补回完整字节」代表人工修复，验证恢复后项目全部回来。
    guard let name = reportedBackupName else { throw ProjectStoreError.directoryUnavailable }
    let backupURL = workDir.appending(path: name, directoryHint: .notDirectory)
    try healthyBytes.write(to: backupURL, options: .atomic)   // 代表「人工把 JSON 修好」
    try FileManager.default.removeItem(at: projectsURL)       // 移除 App 重建的空库
    try FileManager.default.moveItem(at: backupURL, to: projectsURL)
    let recovered = try JSONProjectStore(directory: workDir).loadProjects()
    check(recovered.count == baselineCount,
          "恢复后项目数回到基线：\(recovered.count)/\(baselineCount)")
    check(try backupFileNames().isEmpty, "恢复后目录里不再残留备份文件")

    // 步骤 6：恢复后仍可正常写入（写保护标志没有粘住）
    let recoveredStore = try JSONProjectStore(directory: workDir)
    let list = try recoveredStore.loadProjects()
    try recoveredStore.saveProjects(list)
    check(try JSONProjectStore(directory: workDir).loadProjects().count == baselineCount,
          "恢复后可正常读写，项目数不变")
} catch {
    failures.append("演练异常：\(type(of: error))")
}

if failures.isEmpty {
    print("DRILL PASS")
    exit(0)
} else {
    for failure in failures { print("DRILL FAIL: \(failure)") }
    exit(1)
}
