import Foundation

/// Sample data shown on first launch: a realistic mixed-language project
/// with varied statuses, priorities, tags and dates relative to now.
public enum SeedData {
    public static func makeProject() -> Project {
        let project = Project()
        let now = Date()
        let calendar = Calendar.current

        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: now) ?? now
        }

        let backend = TaskItem(
            title: "实现搜索后端",
            notes: "接入 FindController 与分词匹配，支持 ⌘F 全列表查找",
            startDate: day(-2),
            dueDate: day(0),
            priority: .critical,
            status: .inProgress,
            tags: ["后端", "搜索"],
            assignee: "Bob",
            progress: 0.6
        )
        let review = TaskItem(
            title: "Code Review 搜索模块",
            notes: "重点检查 wrap-around 与大小写匹配",
            dueDate: day(0),
            priority: .high,
            status: .blocked,
            tags: ["评审"],
            assignee: "Bob",
            dependencies: [TaskDependency(predecessorID: backend.id)],
            progress: 0.1
        )
        let release = TaskItem(
            title: "发布 v1.0",
            notes: "里程碑：功能冻结后打包并发布",
            dueDate: day(30),
            priority: .high,
            status: .pending,
            tags: ["里程碑"],
            assignee: "Mei",
            dependencies: [TaskDependency(predecessorID: review.id)],
            progress: 0
        )
        let design = TaskItem(
            title: "设计首页原型",
            notes: "覆盖任务列表、筛选栏与详情面板",
            startDate: day(-4),
            dueDate: day(-1),
            priority: .high,
            status: .pending,
            tags: ["设计"],
            assignee: "Alice",
            progress: 0.3
        )
        let loginCrash = TaskItem(
            title: "修复登录崩溃",
            notes: "用户反馈偶发闪退，根因已定位",
            dueDate: day(-2),
            priority: .critical,
            status: .done,
            tags: ["Bug", "前端"],
            assignee: "Alice",
            progress: 1
        )
        let perf = TaskItem(
            title: "优化启动性能",
            notes: "冷启动从 1.8s 降到 0.9s",
            dueDate: day(-3),
            priority: .high,
            status: .inProgress,
            tags: ["性能"],
            assignee: "Bob",
            progress: 0.5
        )
        let feedback = TaskItem(
            title: "整理用户反馈",
            notes: "汇总内测反馈并按主题聚类",
            dueDate: day(7),
            priority: .normal,
            status: .pending,
            tags: ["调研"],
            assignee: "Alice",
            progress: 0
        )
        let ci = TaskItem(
            title: "搭建 CI 流水线",
            notes: "swift build + swift test 门禁",
            dueDate: day(14),
            priority: .normal,
            status: .pending,
            tags: ["工程"],
            assignee: "Mei",
            progress: 0
        )
        let interview = TaskItem(
            title: "用户访谈记录",
            notes: "完成 5 场访谈并输出纪要",
            dueDate: day(-5),
            priority: .low,
            status: .done,
            tags: ["调研"],
            assignee: "Alice",
            progress: 1
        )
        let spec = TaskItem(
            title: "撰写技术方案文档",
            notes: "明确搜索架构与筛选语义",
            dueDate: day(3),
            priority: .normal,
            status: .pending,
            tags: ["文档"],
            assignee: "Mei",
            progress: 0
        )

        // 演示项目时间线锚定到当前周：排期引擎未设项目起点时从 1970 纪元起算，
        // 会让甘特显示 1970 年日期、时限违例无法用常规日期触发（D-002）。
        project.metadata.projectStart = day(-2)
        project.metadata.projectEnd = day(30)

        for task in [backend, review, release, design, loginCrash, perf, feedback, ci, interview, spec] {
            project.add(task)
        }
        return project
    }
}
