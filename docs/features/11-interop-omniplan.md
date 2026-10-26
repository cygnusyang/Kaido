# 11 · OmniPlan `.oplx` 格式解剖与读取 PoC

> 调研日期 2026-10-27 ｜ OmniPlan 4.10.3（CFBundleVersion 232.6.0）｜ 未改动任何业务代码或 `.kairo` 格式
> 标注规则：**【实测】** = 本机跑过、有输出可复现；**【推断】** = 仅从二进制字符串/脚本字典读到的线索，未跑通验证。

## 1. 一句话结论

`.oplx` 是一个 **zip 容器里的 2–4 个自定义 XML（命名空间 `…/OmniPlan/v2`，`file-format-version="3"`）**；结构扁平、引用靠 `idref`、日期是 ISO-8601 字符串而非 2001 纪元数字。**导入可行、导出有条件可行**（最小文件已被 OmniPlan 4.10.3 成功打开并回读全部字段）。

## 2. 容器层【实测】

| 项 | 结论 |
| --- | --- |
| 形态 | 两种都合法：**单文件 zip**（用户样本 12 025 B，`file` 报 "Zip archive, deflate"）与**目录包**（MSP 转换临时目录、`save in` 产物） |
| 压缩 | deflate，origin=Unix；无 mimetype 首条目要求 |
| 必需成员 | `__TOC.xml`、`Actual.xml` |
| 可选成员 | `__changelog.xml`（样本 a 无）、`Preview.png` 或 `QuickLook/Preview.png`、每个基线一个 `<随机id>.xml` |

用户样本三件套：`Actual.xml` 12 093 B / `__TOC.xml` 29 513 B / `__changelog.xml` 30 325 B。

## 3. 序列化层【实测】

- 纯文本 UTF-8 XML，**不是** plist、**不是** gzip。根元素按文件不同：`<omniplan>`（TOC）/ `<scenario>`（场景）/ `<changelog>`。
- **schema 版本号写在 `__TOC.xml` 的 `<omniplan file-format-version="3">`**，当前为 **3**（4.10.3 写出；6 月旧样本同为 3）。
- `__TOC.xml` 存文档外壳：窗口/列宽/甘特比例、`<project>`（`next-task-id`、`next-resource-id`、`duration-format`、`<scenario>` 清单）。其中 `<filter>` 是 base64 的 NSKeyedArchiver 谓词块——**不透明，不可重建**。
- `Actual.xml` / 基线 xml 存业务数据；`__changelog.xml` 是逐次编辑的 `<change-set user date order>` 流水（可在导出时整体省略，见 §7）。

## 4. 结构模型与字段表

层级**不用 parent 引用**：父任务用 `<child-task idref="tN"/>` 有序列表表达大纲，根由 `<top-task idref="t-1"/>` 指定。全部为【实测】。

| 概念 | 编码 | 证据 |
| --- | --- | --- |
| 任务 | `<task id="tN">` + `<title>`、`<effort>`（**秒**）、`<recalculate>duration`、`<static-cost>` | 全部 5 个样本 |
| 群组 | `<type>group</type>` + 若干 `<child-task idref>` | 用户样本 10 个群组 |
| 里程碑 | `<type>milestone</type>`，无 `effort` | 用户样本"机械臂手板回样" |
| 依赖 | 挂在**后继任务**上：`<prerequisite-task idref="tX" kind="SS">` | 生成样本回读 startstart |
| 依赖类型 | `FS`(默认，`kind` **整个省略**)/`SS`/`FF`/`SF` | 手写 4 型 + OmniPlan 回读一致 |
| lead/lag | 子元素 `<lead-time is-percentage="false">3600</lead-time>`（秒，负值即 lag） | 同上，回读 3600.0 |
| 约束 | `start-no-earlier-than` / `start-no-later-than` / `end-no-earlier-than` / `end-no-later-than` / `locked-start-date` / `locked-end-date`；`<schedule-type>asap\|alap` | 用户样本 26 条约束日期 |
| 日期 | ISO-8601 带毫秒：`2026-09-30T00:00:00.000Z`；也接受 `+08:00` 偏移 | 样本 a 首行 `2025-11-26T08:00:00+08:00` |
| 资源 | `<resource id="rN">` + `<type>Project\|Staff\|Equipment\|Group\|Material`，`<child-resource idref>` 建树 | 用户样本 4 个资源 |
| 分配 | 挂在**任务**上：`<assignment idref="r6" units="0.5"/>`（`units` 缺省=1.0） | b 样本 120 条，resource 侧 0 条 |
| 日历 | `<schedule><schedule-day day-of-week="monday"><time-span start-time="28800" end-time="79200"/>` — 秒/天 | 用户样本 08:00–22:00 |
| 日历例外 | `<calendar name="Time Off" overtime="no"><event sd="9189" st="28800" ed="9189" et="43200"/>` | b 样本 8 条 |
| 基线 | **独立 scenario 文件** + TOC 里 `<scenario name="Initial Baseline" filename="ifIj….xml"/>`；changelog 记 `attribute="baselineInfo"` | 内置示例项目 2 个 scenario |
| ID 体系 | 根任务 `t-1`、根资源 `r-1`、原型 `t-2..t-4`/`r-2`；实例 `tN`/`rN`；`next-task-id` 单调递增 | 用户样本 next-task-id=401 而最大 t400 |
| 备注 | 富文本树 `<note><text><p><run><style><value key="paragraph-alignment">` + `<lit>` | 用户样本会议室备注 |
| 其它 | `fixed-duration`、`splittable`、`priority`(500)、`efficiency`、`cost-per-hour`、`units-available`、`user-data`(MSP 自定义字段) | 标签串 + 样本 |

**工期单位【实测】**：`effort` 一律**秒**，没有"工作日"字段；`duration-format hours-per-day="8|16" hours-per-week=…` 与日历共同决定"人日↔秒"换算。**注意用户样本是 `hours-per-day="16"`**（默认模板是 8），换算若写死 8 会整体差一倍。

**2001 纪元【实测】**：只出现在日历例外的 `sd/ed` 整数日号上——`9189 → 2026-02-28`、`7490 → 2021-07-05`，与"自 2001-01-01 起的天数"完全吻合（按 1970 纪元则落到 1995/1990，明显不成立），日号取本机日历日。

## 5. PoC 实测（脚本在 `/tmp/oplx_poc/`，不入库）

`oplx_read.py` 同时支持 zip 与目录包，输出（截取）：

```text
用户样本  26 任务(群组10/里程碑1/叶15)  深度4  依赖0    资源4  分配0   工时和 1 411 200 s
b 样本   298 任务(63/8/227)            深度5  依赖126 全 FS  资源19 分配120 工时和 46 656 000 s
a 样本   170 任务(34/3/133)            深度3  依赖79  全 FS  资源1  分配0
内置示例  41 任务(10/4/27)             深度3  依赖23  全 FS  资源6  分配67  + 1 个基线 scenario
生成样本   7 任务                     依赖4   SS/FF/SF/FS 各 1，lead 3600/7200/1800/0 s
```

用户样本日期样例：`2026-09-30T00:00:00.000Z`（26 条约束全为 `start-no-earlier-than`）；依赖边 0 条 —— **该文件是纯大纲，没有任何前置关系**。

## 6. 导入（.oplx → Kairo）可行性：**可行【实测】**

只读解析已跑通 4 个真实文件 + 1 个自造文件（最大 298 任务 / 126 依赖），层级、依赖四型、lead、日历、分配、基线全部能取出。无网络、无私有 API。唯一"读不全"的是 `<filter>` 谓词块与样式树里的不透明二进制，但业务语义不依赖它们。

## 7. 导出（Kairo → .oplx）可行性：**有条件可行【实测】**

已构造 885 B 的最小容器（2 条目）并被 OmniPlan 4.10.3 正常打开、回读：任务 2 条（`设计` 28800 s、`实现` 57600 s）、依赖 `startstart / lead 3600.0 / 前置=设计`。最小必需集：

```xml
<!-- __TOC.xml -->
<omniplan xmlns="http://www.omnigroup.com/namespace/OmniPlan/v2" file-format-version="3">
  <project><next-task-id>N</next-task-id><next-resource-id>M</next-resource-id>
    <scenario id="任意token" name="Actual" filename="Actual.xml"/></project>
</omniplan>
<!-- Actual.xml -->
<scenario xmlns="…/OmniPlan/v2" id="同上"><start-date>ISO-8601</start-date>
  <top-task idref="t-1"/><task id="t-1"><type>group</type><child-task idref="t1"/>…</task>…</scenario>
```

- **可省略**（两轮实测，`min.oplx` 与 `min2.oplx` 均被成功打开并回读 2 个任务）：`__changelog.xml`、`Preview.png`、`prototype-task`/`prototype-resource`、`granularity`、`duration-format`、`critical-path`。
- **必须自洽**：`top-task` 必须指向真实存在的根 group；`child-task` 只能引用已定义的任务；`next-task-id` 必须大于所有已用编号。
- **ID**：手写 `t1`/`t2` 被接受（无需 UUID）；scenario `id` 任意 token 亦可。
- **日期**：ISO-8601 UTC 毫秒串，**不是** NSDate 浮点。
- **可写 zip**：OmniPlan 从 zip 打开完全正常，落地时不必生成目录包。
- 需要额外处理：把 Kairo 的"天/工作日"换算成 `effort` 秒（依赖 `hours-per-day` 与日历），并把 `kind` 缺省语义定为 FS（不要显式写 `kind="FS"`，虽然也能读，但原生写法是省略）。

## 8. 风险与工作量

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| 无官方 schema | 全部靠逆向；Apple 未提供 XSD/DTD | 固定样本回归集（本机已有 5 份），每次升级 OmniPlan 先跑 PoC |
| 版本分叉 | `file-format-version` 目前恒为 3，但 3 与 4.0 之前的 changelog `<version>4.0` 并存，语义未文档化 | 只写最小子集，不碰 changelog/样式/过滤器 |
| 工时换算 | `hours-per-day` 样本间 8 与 16 混存，错了整体工期翻倍 | 导入时读取 `duration-format`，不写死 |
| 自动化验证成本 | `save <doc> in <path>` 触发过一次 OmniPlan 崩溃（CrashCatcher 弹窗、AppleEvent 全部挂起）；`open` 即使成功也返回 -10000；`close` 偶发超时【实测】 | 导出只做"文件层面解析 + 人工开一次"，不脚本化回存 |
| 不透明块 | `<filter>`、部分样式树是 NSKeyedArchiver 二进制 | 导出时不生成，导入时跳过 |

**工作量估算**：只读导入器 3–4 人日（映射 + 日历 + 5 样本回归）；导出器 + 往返验证 5–7 人日；合计 **8–11 人日**，不含 UI 与实时同步。

## 9. 证据与复现

```bash
# 样本与解包
file "/Users/cygnus/work/btrobot/Cygnus 个人任务.oplx"      # Zip archive, deflate
unzip -l "/Users/cygnus/work/btrobot/Cygnus 个人任务.oplx"    # 3 entries
defaults read /Applications/OmniPlan.app/Contents/Info.plist CFBundleShortVersionString  # 4.10.3

# PoC
python3 /tmp/oplx_poc/oplx_read.py  <任意 .oplx 或目录包>
python3 /tmp/oplx_poc/oplx_write.py /tmp/oplx_poc/out/min.oplx
```

附带样本：`/tmp/oplx_poc/s2/b.oplx`（298 任务/126 依赖）、`/tmp/oplx_poc/gen/gen.oplx`（四型依赖，OmniPlan 自己写出）、内置 `Simple Product Development.oplx`（带基线）。原始样本未修改（仅 `cp` 副本）。
