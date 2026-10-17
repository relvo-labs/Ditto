import QtQuick
import QtTest
import "../../../crates/ditto-generation/templates" as Templates

// Only trusted fixed QML and explicit test data. This is SDK development
// evidence, not the isolated five-stage pipeline or AT-06.
TestCase {
    id: testCase
    name: "RestrictedTemplates"
    width: 640
    height: 480
    visible: true
    when: windowShown

    Component { id: tasksFactory; Templates.TasksSummary {} }
    Component { id: workspacesFactory; Templates.WorkspaceActions {} }
    SignalSpy { id: activationSpy; signalName: "activateWorkspaceRequested" }

    function test_task_contract_filter_sort_limit() {
        const panel = createTemporaryObject(tasksFactory, testCase, {
            config: { title: "今日摘要", width: 320, content: { max_items: 1, show_completed: false, order: "title" } },
            tasks: [
                { task_id: "b", text: "Bravo", done: false, source: "own" },
                { task_id: "a", text: "Alpha", done: false, source: "own" },
                { task_id: "c", text: "Complete", done: true, source: "own" }
            ],
            dataAvailable: true,
            testData: true
        })
        verify(panel !== null)
        compare(panel.displayedTasks.length, 1)
        compare(panel.displayedTasks[0].task_id, "a")
        compare(findChild(panel, "testDataLabel").visible, true)
        compare(findChild(panel, "testDataLabel").text, "預覽使用測試資料")
        panel.config = { title: "今日摘要", content: { max_items: 20, show_completed: true, order: "source" } }
        compare(panel.displayedTasks.length, 3)
        verify(panel.healthy())
        panel.release()
        verify(!panel.healthy())
    }

    function test_plain_text_when_source_unavailable() {
        const title = "<b>text</b>; Qt.createQmlObject('import Quickshell.Io', parent)"
        const panel = createTemporaryObject(tasksFactory, testCase, { config: { title: title }, testData: false })
        const label = findChild(panel, "panelTitle")
        compare(label.text, title)
        compare(label.textFormat, Text.PlainText)
        verify(findChild(panel, "dataStatus").visible)
        compare(findChild(panel, "dataStatus").text, "尚未取得待辦資料")
        verify(!findChild(panel, "testDataLabel").visible)
    }

    function test_workspace_availability_and_keyboard() {
        const panel = createTemporaryObject(workspacesFactory, testCase, {
            config: { title: "工作區", content: { actions: [
                { workspace_id: "one", label: "<b>專注</b>" },
                { workspace_id: "missing", label: "不可用" }
            ] } },
            availableWorkspaceIds: ["one"], actionsAvailable: false, testData: true
        })
        activationSpy.target = panel
        activationSpy.clear()
        const available = findChild(panel, "workspaceAction_one")
        const missing = findChild(panel, "workspaceAction_missing")
        verify(available !== null && missing !== null)
        verify(!available.enabled)
        panel.actionsAvailable = true
        verify(available.enabled)
        verify(!missing.enabled)
        compare(available.contentItem.textFormat, Text.PlainText)
        available.forceActiveFocus()
        tryCompare(available, "activeFocus", true)
        keyClick(Qt.Key_Space)
        compare(activationSpy.count, 1)
        compare(activationSpy.signalArguments[0][0], "one")
        panel.availableWorkspaceIds = []
        verify(!available.enabled)
        verify(panel.healthy())
        panel.release()
        verify(!panel.healthy())
        activationSpy.target = null
    }
}
