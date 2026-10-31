import Foundation
import Testing
import KaidoInterop
import InteropMSPDI

/// MS Project 用元素属性 Manual="1" 表达手动排期（v1.3.6）。
/// 读：属性 → InteropTask.isManuallyScheduled；写：手动任务写回该属性。
@Suite("MSPDI 手动排期标记")
struct MSPDIManualFlagTests {
    private func sample(attribute: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Project xmlns="http://schemas.microsoft.com/project">
          <SaveVersion>14</SaveVersion>
          <Tasks>
            <Task\(attribute)>
              <UID>1</UID><ID>1</ID><Name>手动任务</Name>
              <OutlineLevel>1</OutlineLevel><Duration>PT8H0M0S</Duration>
            </Task>
          </Tasks>
        </Project>
        """
        return Data(xml.utf8)
    }

    @Test func manualAttributeIsRead() throws {
        let document = try MSPDIAdapter().read(sample(attribute: " Manual=\"1\""))
        #expect(document.tasks.first?.isManuallyScheduled == true)
    }

    @Test func absentAttributeMeansAutomatic() throws {
        let document = try MSPDIAdapter().read(sample(attribute: ""))
        #expect(document.tasks.first?.isManuallyScheduled == false)
    }

    @Test func manualFlagIsWrittenBack() throws {
        let document = try MSPDIAdapter().read(sample(attribute: " Manual=\"1\""))
        let output = try MSPDIAdapter().write(document)
        #expect(String(decoding: output, as: UTF8.self).contains("Manual=\"1\""))
    }
}
