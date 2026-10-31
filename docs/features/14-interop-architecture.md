# 14 · 互操作架构：两条格式通道必须互相独立

> 决策稿，2026-10-27。依据：`11-interop-omniplan.md`（.oplx 解剖 + PoC）、`12-interop-msproject.md`（.mpp/MSPDI/MPX 对比）、`13-interop-mapping.md`（字段映射与差距）。
> 约束来源（用户 2026-10-27）：「OmniPlan 与 Project 的格式兼容，在架构设计上要**相互独立**，以便对方格式更新时能快速适配。」

## 1. 可行性结论

| 通道 | 读 | 写 | 依据 |
| --- | --- | --- | --- |
| **MS Project XML（MSPDI）** | ✅ 可行，零第三方依赖 | ✅ 可行 | 微软官方 schema；实测把 298 任务 / 180 依赖 / 21 日历 / 278 基线导出后回读逐项相等 |
| **OmniPlan `.oplx`** | ✅ 可行（已解析真实样本） | ⚠️ 有条件可行 | zip 内 2–4 个自定义 XML；885 B 最小容器已被 OmniPlan 4.10.3 打开并回读字段 |
| **MS Project `.mpp` 二进制** | ❌ **不做** | ❌ **不做** | 无公开规范；唯一参考实现 MPXJ 自认写不了、读「相对不完整」；自研 ≥60 人日且失败面不可控；走 MPXJ 要背 JVM（+50 MB、沙箱与公证复杂化） |
| **MS Project MPX** | ❌ 不做 | ❌ 不做 | 实测中文变 `????`（ANSI 代码页硬伤）、无基线日期、已废弃 |

**一句话**：两条通道都能做，但**都不是「直接读对方原生二进制」**——OmniPlan 走自研 `.oplx`（已跑通），MS Project 走官方 MSPDI XML，`.mpp` 交给用户侧「另存为 XML」。

## 2. 架构：IR + 适配器，两条通道零耦合

```
        UI / CLI / MCP
              │  （只认 capability，不认格式实现）
        ┌─────▼──────────────────────────────┐
        │ ZenoInterop                       │
        │  InteropDocument        供应商无关 IR │
        │  FidelityLedger         有损登记     │
        │  FormatAdapter (protocol)           │
        │  AdapterRegistry                    │
        │  ZenoBridge   IR ↔ Zeno 模型       │
        └───┬──────────────────┬─────────────┘
            │                  │
   ┌────────▼───────┐  ┌───────▼──────────┐
   │ InteropMSPDI   │  │ InteropOmniPlan  │   ← 两个 target，互不 import
   │ 读 / 写 / 预检  │  │ 读 / 写 / 预检    │
   └────────────────┘  └──────────────────┘
```

四条硬规则（违反即评审不通过）：

1. **适配器之间零依赖**：`InteropMSPDI` 与 `InteropOmniPlan` 互不 import，删掉任意一个，另一个仍能编译并全绿。厂商格式变更只会落在它自己的 target 里。
2. **适配器不 import ZenoCore 的业务模型**：只对 `InteropDocument` 说话。所有「工作日 ↔ 日历天」「Summary ↔ 阶段门」这类语义换算，**只在 `ZenoBridge` 一处**实现 —— 否则每加一个格式就要重写一遍换算，且会出现三份不一致的口径。
3. **版本前置，不猜**：适配器声明 `supportedVersions`；读到未知版本必须抛 `unsupportedFormatVersion` 明确拒绝（与 `.zeno` 同一条原则），禁止 best-effort 部分解析后「看起来成功」。
4. **同一套契约测试跑所有适配器**：`AdapterConformanceSuite`（往返、空计划、单任务、四类依赖、lag、里程碑、群组、多日历、基线、超长标题、中文/emoji、畸形输入）对每个 target 各跑一遍。新增通道不改测试集——这正是「独立」的可验证形式。

## 3. `InteropDocument`（IR）应有的最小面

- 任务树：`id / title / notes / kind(task|group|milestone) / outlineLevel / 顺序`
- 时间：`plannedStart / plannedFinish / duration / effortHours / progress / actualStart / actualFinish`
- 依赖：`predID / type(FS|SS|FF|SF) / lag（以**秒**存，避免各格式单位来回截断）`
- 约束：`start-no-earlier / start-no-later / end-no-earlier / end-no-later / asap / alap`
- 资源与分配：`resource(id,name,type,units,calendar) / assignment(taskID,resourceID,units)`
- 日历：`workingDays[] + exceptions[]`（缺失即「全周 7 天」，与 Zeno 现状一致）
- 基线：`baseline(id,name,createdAt,entries[taskID,start,finish])`
- **`FidelityLedger`**：每条「丢了什么 / 换算过什么 / 降级成什么」都带字段名、任务计数、原值样例 —— 预检报告与导出旁注都从它渲染，不各写一套

## 4. 分期与工作量（人日，不含 UI 细节）

| 阶段 | 内容 | 工作量 |
| --- | --- | --- |
| **P0** | `ZenoInterop` 骨架（IR / 适配器协议 / 契约测试 / 版本闸门）+ **MSPDI 读** | 10–12 |
| **P1** | **MSPDI 写** + 往返对拍 + 导出旁注文件 | 7–9 |
| **P2** | **OmniPlan `.oplx` 读**（真实样本 + 4 类依赖 + 工时换算） | 3–4 |
| **P3** | **OmniPlan `.oplx` 写**（最小容器已验通，补基线 scenario / 日历 / 分配） | 5–7 |
| **P4** | 导入预检与导出旁注的 UI（两通道共用组件） | 3–4 |
| 合计 | | **28–36** |

顺序刻意如此：**先把 IR 与契约立起来，再上第二个格式**。反过来（先各写各的解析器）就再也拆不开了。

## 5. 语义鸿沟（导入必读，逐条会进预检报告）

1. **工作日 ↔ 日历天**（最严重）：对方按 5 天/周排，Zeno 按 7 天/周。5 天任务导入后连周末排，FS 链每周右移约 2 天，偏差随链长线性放大；导出则相反。
2. **Summary ↔ 阶段门**：Zeno 群组依赖下推到子树全部叶子；对方 Summary 依赖只落汇总行。只还原单边会复现 issue #16「下游只顺延一部分」。
3. **软约束 ↔ 硬约束**：Zeno 的 `noLater` 只出违例不改期；对方会改期或报冲突。
4. **`dueDate` ≠ Deadline**：Zeno 的 `dueDate` 不参与排期（只做逾期展示），映射成对方 Deadline 会「看起来成功、含义已换」。
5. **工时基准**：OmniPlan 一律存 effort 秒，换算看 `duration-format` 的 `hours-per-day`——用户样本是 **16**，不是默认 8。写死 8 会差一倍。
6. **资源与成本**：Zeno 无费率/成本/资源日历/资源平衡；对方有。导入时降级为纯分配，成本信息进 `FidelityLedger`。
7. **基线**：Zeno 无硬上限但同屏 3 条、8 色；对方最多 10 条且带 work/cost 基线。超出部分丢弃并登记。

## 6. 明确不做

- `.mpp` 二进制读写（理由见 `12` §7）；用户侧路径：请对方「另存为 XML」。
- MPX（读/写）。
- 对方文件里的**视图/呈现数据**（列宽、筛选、绘图，占 `.mpp` 体积 44.7%）——Zeno 有自己的列模型与甘特。
- 「导入后再导出能原样还原对方文件」这种承诺：只承诺 **语义等价**，不承诺字节级往返。

## 7. 待决事项（需产品决策，不是技术决策）

1. 排入哪个版本：1.1 先做 MSPDI（P0–P1，17–21 人日），还是两通道一起上（28–36 人日）。
2. MSPDI 写出的文件能否被 MS Project 实机接受：本机无 Windows，**必须**在 Windows 虚拟机做一次性验收后才能宣称「支持 Project」。
3. `.oplx` 属**逆向**（无官方 schema，`file-format-version="3"`）：接受「OmniPlan 升级后可能失效」的风险，还是先只做导入、导出等有明确需求再上。
