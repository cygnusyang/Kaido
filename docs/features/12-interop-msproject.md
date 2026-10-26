# 12 · 互操作调研 B：MS Project 格式对比（.mpp / MSPDI / MPX）

> 调研稿，基线 v1.0.1（bc6ce10）。只回答「先做哪个格式、哪个直接不做」；字段级映射已在 `13-interop-mapping.md`，本文不重复。
> 样本：`~/Documents/PLB1011.mpp`（1,327,104 B，只读，副本在 `/tmp`）。本机 **无 Windows / 无 MS Project / 无 Office**，下文每条结论要么来自本机实测，要么来自可引用的官方文档或参考实现源码；**未能实测的一律标注「未验证」**。

## 1. `.mpp` 识别结果（实测）

| 项 | 值 | 取证方式 |
| --- | --- | --- |
| 容器 | Composite Document File V2（OLE2 复合文档），Little Endian，Code page 936 | `file` |
| 根 CLSID | `74B78F3A-C8C8-11D1-BE11-00C04FB6FAF1` | `olefile` |
| 版本标记 | `\x01CompObj` 内 `Microsoft.Project 16.0` + `MSProject.MPP14`；MPXJ `MPPReader.getFileFormat()` 返回 `MSProject.MPP14` | 实测 |
| 创建应用 | SummaryInformation：`Microsoft Project`，Create 2025-11-28，LastSaved 2026-03-25 | `olefile` |
| 内部结构 | 96 个 stream，占用 97% 文件字节；`114/` 数据表 51.9%、`214/` 视图数据 44.7% | `olefile` 求和 |
| 数据表 | `TBkndTask / Rsc / Cons / Cal / Assn / OutlCode / Attachment / ChecklistItem / …`，每表 `Fixed*Data + Fixed*Meta + Var*Data + Var*Meta` | stream 列表 |
| 视图数据 | `214/CV_iew/Var2Data` 单流 416,534 B（列布局、筛选、分组、绘图） | stream 列表 |
| 计划规模 | 298 任务 / 19 资源 / 180 依赖（FS 179、FF 1）/ 256 分配 / 21 日历 / 278 条任务基线 | MPXJ 读取 |
| 读耗时 | 345–469 ms（1.3 MB / 298 任务） | MPXJ 实测 |

**要点**：`.mpp` 里真正不可替代的内容是 `214/` 那 44.7% 的**视图/呈现数据**（列宽、筛选器、绘图）。计划数据本身是「表 + 定长/变长记录」的私有布局。

## 2. `.mpp` 二进制可读性：公开进展到哪一步

- **没有公开规范**。微软从未发布 `.mpp` 结构文档；`learn.microsoft.com/office-project` 只收录 MSPDI（`mspdi_pj12.xsd`）。
- **事实上的参考实现是 MPXJ**（`github.com/joniles/mpxj`，LGPL-2.1+）：`org/mpxj/mpp` 包 145 个 class、878 KB 字节码，其中 `MPP8Reader` 45 KB / `MPP12Reader` 51 KB / `MPP14Reader` 51 KB——**每代一条独立解析器**，字段 ID → 语义的对应表另有一份 509 KB 的 *MPP Field Guide*。
- **能读，但读写不对称**。MPXJ 官方 FAQ 原文：「虽然技术上可生成 MPP，但我们对文件结构的了解仍相对不完整……**你最好改用 MSPDI，它支持 MPP 里的全部数据项**」——业界最强实现者明确放弃写 `.mpp`。
- **密码保护**：`MPPReader.setReadPassword()` / `setRespectPasswordProtection()` 存在，说明加密 MPP 要走额外解密钥路径，不是加个 if。
- **自研成本**：需覆盖 MPP8/9/12/14 四代容器 + 每代字段索引 + 时标数据（timephased）+ 密码；任一环反向失败即「打不开用户的文件」——**失败面不可控**，不是工作量问题。

## 3. MSPDI（MS Project XML）：唯一有官方规范的格式

- **规范**：[Project XML Data Interchange Schema Reference](https://learn.microsoft.com/en-us/office-project/xml-data-interchange/project-xml-data-interchange-schema-reference)，对应 `mspdi_pj12.xsd`（Project 2007 版）；命名空间 `http://schemas.microsoft.com/project`。
- **版本**：Project 2010+ 写 `<SaveVersion>14</SaveVersion>`，**没有公开的 v14 XSD**——v14 新增元素（如 `TaskMode`）微软未出独立 schema 文档；我方输出按 v14 写。
- **实测覆盖率**（`PLB1011.mpp` → MSPDI，1,248,365 B UTF-8，`xmllint --noout` 通过）：

| 领域 | MSPDI 元素 | 实测写出 |
| --- | --- | --- |
| 任务 | `Task/Name, OutlineLevel, Summary, Milestone, Duration, Start, Finish` | 298 条 |
| 依赖四类型 | `PredecessorLink/Type` + `LinkLag` + `LagFormat` | 180 条边，类型计数与源文件**逐项相等** |
| 约束 | `ConstraintType`（0 ASAP / 4 SNET / 6 FNET） | 262 / 22 / 14，与源文件**逐项相等** |
| 日历 | `Calendar/WeekDays/WeekDay/WorkingTimes` + `Exceptions` | 21 个日历 |
| 资源 | `Resource/Name, MaxUnits, StandardRate, CalendarUID` | 19 条 |
| 分配 | `Assignment/TaskUID, ResourceUID, Units` | 270 条（见下「差异」） |
| 基线 | `Task/Baseline/BaselineNumber, Start, Finish, Work` | 278 条任务基线保留 |
| 自定义域 | `ExtendedAttribute` + `Task/ExtendedAttribute` | 1 个定义 / 236 条任务有值 |

- **往返实测**（MSPDI 写 → 读回）：任务 298、资源 19、依赖 180、日历 21，依赖类型 FS179/FF1、约束 262/22/14、基线 278 **全部一致**。
- **已知差异**：分配数 256 → 270（+14）。逐任务定位后确认：多出的 14 条**全部落在摘要任务上**（任务 0/1/5/6/14/18/22/43/46/70/79/80/102/132，MPP 中分配行数 0，MSPDI 中为 1）。摘要任务不承载分配，对排期无影响，但预检里应说明「摘要任务会多出分配行」。
- **写入是否被 Project 接受**：MSPDI 就是 Project 自己的「另存为 XML」格式，结构同源；但**本机无 Windows，未用 Project 实机验证——标为未验证**，建议首次发布前在 Windows 虚拟机做一次性验收。

## 4. MPX（老式文本交换格式）：判定不做

- 定长记录的 ANSI 文本，首行 `MPX,Microsoft Project for Windows,4.0,ANSI`；实测导出 86,821 B、`MPXWriter` 37 ms。
- **中文直接丢**：本样本导出后任务名变 `????`、项目名 `??`——ANSI 代码页装不下 CJK，**硬伤，不是参数问题**。
- **无基线日期**：输出里 "Baseline" 只作列标题出现（且只有 Baseline Work，无 start/finish），多基线无从表达。
- 微软当前文档库只收录 MSPDI，MPX 规范停留在 Project 98/2000 时代；用 MPX 等于用「比 MSPDI 更差且中文不可用」的通道。
- **结论：读写都不做。** 保留 MPXJ 的 `MPXWriter` 仅作内部排障。

## 5. 方案对比

| 格式 | 方向 | 自研 | 第三方 | 许可证 | 可行性判定 |
| --- | --- | --- | --- | --- | --- |
| MSPDI | 读 | XML 解析，零外部依赖 | MPXJ | LGPL-2.1+ | **可行，首选** |
| MSPDI | 写 | 同上 | MPXJ | LGPL-2.1+ | **可行，首选** |
| MPX | 读/写 | 文本行解析，简单 | MPXJ | LGPL-2.1+ | 技术可行，**价值为负**（丢中文、无基线）→ 不做 |
| `.mpp` | 读 | 需逆向 MPP8/9/12/14，**≥60 人日且失败面不可控** | MPXJ（需 JVM） | LGPL-2.1+ | **不做**（见 §7） |
| `.mpp` | 写 | 无参考实现 | **无**（MPXJ 自己都不写） | — | **不做** |

MPXJ 许可证细节：LGPL-2.1-or-later（`mpxj-16.10.0.pom` 的 `<licenses>`）。动态链接/进程外调用可满足 LGPL，但 Swift 应用要背 JRE（`org.mpxj` 依赖 Apache POI、jackcess、sqlite-jdbc、JAXB、Jackson 一整套 Apache-2.0 生态），启动 +300 ms、安装包 +50 MB 起，macOS 沙箱与公证链路复杂化。

## 6. 建议路线与工作量

1. **P0｜MSPDI 导入**（MSPDI → Kairo）：8–10 人日。含 `13-interop-mapping.md` §5 要求的导入前预检报告（丢失字段计数、日历换算偏差预估、依赖降级明细）。
2. **P0｜MSPDI 导出**（Kairo → MSPDI）：5–6 人日。含导出旁注文件 `<项目名>.kairo-export-notes.md` 与 `Task/UID` 旁路保 UUID。
3. **P1｜双向往返对拍**：4–5 人日。fixture = 本样本 + 边界样本（7 天/5 天日历、lag 小数、11 条以上基线、cancelled 任务）。
4. 合计 **17–21 人日**拿到「与 MS Project / OmniPlan 互通」的完整能力，且**零第三方运行时依赖**。

## 7. 明确不做

- **`.mpp` 二进制读写，整体判「不做」**。① 无公开规范，唯一参考实现（MPXJ）自认写不了、读也只是「相对不完整」；② 自研要覆盖四代容器 + 字段索引 + 密码，≥60 人日且失败不可控；③ 走 MPXJ 就得背 JVM，与「单机 Swift 应用、可公证、秒开」的产品约束冲突。
- **`.mpp` 的用户侧路径**：由发起方在 MS Project 里「另存为 XML（MSPDI）」，导入向导明确提示「请对方导出为 XML」。**把格式转换成本推给格式拥有者**——这是唯一不需要我们维护逆向代码的方案。
- **MPX**：读写都不做（中文丢失 + 无基线 + 已废弃）。
- **`.mpp` 独有内容**：视图/呈现数据（`214/` 那 44.7%）不追求还原——Kairo 有自己的甘特与列布局，不需要进口别人的列宽。

## 8. 最小可验证动作（已在本机跑通）

`PLB1011.mpp` 用 MPXJ 16.10.0 + JDK 17 读入并导出 MSPDI，全程 <1 s：

```bash
mkdir -p /tmp/mpxj-min/src/main/java && cd /tmp/mpxj-min
printf "plugins{id 'application'}\nrepositories{mavenCentral()}\ndependencies{implementation 'net.sf.mpxj:mpxj:16.10.0'}\napplication{mainClass='Dump'}\n" > build.gradle
cat > src/main/java/Dump.java <<'JAVA'
import org.mpxj.*; import org.mpxj.mpp.MPPReader; import org.mpxj.mspdi.MSPDIWriter; import java.io.File;
public class Dump{public static void main(String[] a)throws Exception{
 ProjectFile p=new MPPReader().read(new File(a[0]));
 System.out.println("tasks="+p.getTasks().size()+" res="+p.getResources().size()+" rel="+p.getRelations().size()+" cal="+p.getCalendars().size());
 new MSPDIWriter().write(p,a[0].replaceAll("\\.mpp$",".xml"));}}
JAVA
gradle -q --console=plain run --args='/tmp/PLB1011.mpp'
```

实测输出：`tasks=298 res=19 rel=180 cal=21` → 生成 `/tmp/PLB1011.xml`（1,248,365 B）；回读后计数、依赖类型、约束分布、基线数全部一致。

## 9. 未验证项（不得当结论引用）

- 生成的 MSPDI 由 **MS Project 实机**打开是否无警告/无修复提示（本机无 Windows；需 Windows 虚拟机一次性验收）。
- Project 2016 对 v14 元素（`TaskMode` 等，无公开 XSD）的接受度，需实机跑一遍。
- OmniPlan 能否直接打开 `.mpp`（若可以，可作为用户侧转换路径，本文不假设）。
- MPX 在现代 Project 版本中的导入可用性（不打算支持，仅记录）。
