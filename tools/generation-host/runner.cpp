// Trusted fixed-template runner. Description JSON is data, never QML source.
// Landlock/socket/cgroup boundaries are established by the Rust host BEFORE
// this executable starts. This second filter denies process execution/fork.
#include <QGuiApplication>
#include <QQuickView>
#include <QQuickItem>
#include <QQmlEngine>
#include <QJSValue>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QFile>
#include <QSignalSpy>
#include <QTest>
#include <QtTest/qtestkeyboard.h>
#include <QKeyEvent>
#include <QTimer>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <linux/audit.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sched.h>
#include <unistd.h>
#include <cerrno>
#include <iostream>
#include <vector>
#include <functional>

static void emitJson(const QJsonObject& object) {
    std::cout << QJsonDocument(object).toJson(QJsonDocument::Compact).constData() << std::endl;
}
static bool denyExecution() {
    std::vector<sock_filter> f;
    const auto stmt=[&](unsigned short code,unsigned k){f.push_back(BPF_STMT(code,k));};
    const auto jump=[&](unsigned k,unsigned char yes,unsigned char no){f.push_back(BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,k,yes,no));};
    stmt(BPF_LD|BPF_W|BPF_ABS,4); jump(AUDIT_ARCH_X86_64,1,0); stmt(BPF_RET|BPF_K,SECCOMP_RET_KILL_PROCESS);
    stmt(BPF_LD|BPF_W|BPF_ABS,0);
    f.push_back(BPF_JUMP(BPF_JMP|BPF_JGE|BPF_K,0x40000000,0,1)); stmt(BPF_RET|BPF_K,SECCOMP_RET_KILL_PROCESS);
    for (int n:{SYS_execve,SYS_execveat,SYS_fork,SYS_vfork,SYS_unshare,SYS_setns,SYS_mount,SYS_umount2}) {
        jump(n,0,1); stmt(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM);
    }
    jump(SYS_clone3,0,1); stmt(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|ENOSYS);
    jump(SYS_clone,0,4);
    stmt(BPF_LD|BPF_W|BPF_ABS,16); stmt(BPF_ALU|BPF_AND|BPF_K,CLONE_THREAD);
    jump(CLONE_THREAD,1,0); stmt(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM);
    stmt(BPF_RET|BPF_K,SECCOMP_RET_ALLOW);
    sock_fprog program{static_cast<unsigned short>(f.size()),f.data()};
    return prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)==0 && syscall(SYS_seccomp,SECCOMP_SET_MODE_FILTER,SECCOMP_FILTER_FLAG_TSYNC,&program)==0;
}
int main(int argc,char** argv) {
    if (argc!=4) return 64;
    const QString mode=QString::fromLocal8Bit(argv[1]);
    QFile input(QString::fromLocal8Bit(argv[2]));
    if (!input.open(QIODevice::ReadOnly) || input.size()>16384) return 1;
    QJsonParseError error;
    const auto parsed=QJsonDocument::fromJson(input.readAll(),&error);
    QJsonArray stages;
    const auto stage=[&](const char* name,bool passed,const char* reason){
        stages.append(QJsonObject{{"stage",name},{"result",passed?"passed":"failed"},{"diagnostic",reason}});
        emitJson({{"phase",name},{"progress",stages.size()/5.0}});
    };
    bool execBlocked=false;
    const auto finish=[&](bool preview){
        const char* names[]={"syntax","contract","load","focus","interaction"};
        while(stages.size()<5) stages.append(QJsonObject{{"stage",names[stages.size()]},{"result","not_run"},{"diagnostic","previous_stage_failed"}});
        emitJson({{"native_result",QJsonObject{{"exec_blocked",execBlocked},{"stages",stages},{"preview_opened",preview},{"test_data",true}}}});
    };
    if(error.error!=QJsonParseError::NoError || !parsed.isObject()){stage("syntax",false,"invalid_description_json");finish(false);return 0;}
    // Application setup uses only the clean host-provided environment; the
    // exec filter is installed before any QML component is loaded.
    QGuiApplication app(argc,argv);
    execBlocked=denyExecution();
    if(!execBlocked){stage("syntax",false,"execution_filter_failed");finish(false);return 0;}
    // Prove the process restriction in the same thread that loads QML.
    errno=0;
    if(syscall(SYS_execve,"/usr/bin/true",nullptr,nullptr)!=-1 || errno!=EPERM){finish(false);return 1;}
    errno=0;
    if(syscall(SYS_fork)!=-1 || errno!=EPERM){finish(false);return 1;}
    const auto description=parsed.object();
    const auto content=description["content"].toObject();
    const bool tasks=content["template"]=="tasks_summary_v1";
    QQuickView view;
    view.setResizeMode(QQuickView::SizeViewToRootObject);
    QVariantMap properties{{"config",QVariant::fromValue(view.engine()->toScriptValue(description.toVariantMap()))},{"testData",true}};
    if(tasks) {
        QVariantList data;
        data.append(QVariantMap{{"task_id","fixture-a"},{"text","測試待辦 A"},{"done",false},{"source","preview"}});
        data.append(QVariantMap{{"task_id","fixture-b"},{"text","測試待辦 B"},{"done",true},{"source","preview"}});
        properties["tasks"]=QVariant::fromValue(view.engine()->toScriptValue(data)); properties["dataAvailable"]=true;
    } else {
        QStringList ids;
        for(const auto& action:content["actions"].toArray()) ids.append(action.toObject()["workspace_id"].toString());
        properties["availableWorkspaceIds"]=QVariant::fromValue(view.engine()->toScriptValue(ids)); properties["actionsAvailable"]=true;
    }
    view.setInitialProperties(properties);
    view.setSource(QUrl::fromLocalFile(QString::fromLocal8Bit(argv[3])));
    stage("syntax",view.status()!=QQuickView::Error,"fixed_template_compilation");
    if(view.status()==QQuickView::Error){finish(false);return 0;}
    const bool contract=description["format_version"]==1 && (tasks || content["template"]=="workspace_actions_v1") && view.rootObject()!=nullptr;
    stage("contract",contract,"fixed_template_contract"); if(!contract){finish(false);return 0;}
    auto* item=view.rootObject();
    QVariant healthy;
    const bool loaded=item->property("ready").toBool() && QMetaObject::invokeMethod(item,"healthy",Q_RETURN_ARG(QVariant,healthy)) && healthy.toBool();
    stage("load",loaded,"provider_health"); if(!loaded){finish(false);return 0;}
    view.setTitle(QStringLiteral("Ditto 插件預覽 — 使用測試資料"));
    view.show(); view.requestActivate(); item->forceActiveFocus(); QTest::qWait(80);
    stage("focus",item->hasActiveFocus(),"keyboard_focus"); if(!item->hasActiveFocus()){finish(false);return 0;}
    bool interaction=false;
    QString interactionDiagnostic="fixture_data_and_keyboard_action";
    if(tasks) {
        const auto list=item->property("displayedTasks").value<QJSValue>().toVariant().toList();
        interaction=!list.isEmpty() && list.size()<=content["max_items"].toInt();
    } else {
        const auto actions=content["actions"].toArray();
        const QString wanted="workspaceAction_"+actions.first().toObject()["workspace_id"].toString();
        std::function<QQuickItem*(QQuickItem*)> find=[&](QQuickItem* parent)->QQuickItem*{
            if(parent->objectName()==wanted)return parent;
            for(auto* child:parent->childItems())if(auto* found=find(child))return found;
            return nullptr;
        };
        auto* button=find(item);
        QSignalSpy spy(item,SIGNAL(activateWorkspaceRequested(QString)));
        if(button && button->isEnabled()) {button->forceActiveFocus();QTest::qWait(20);QTest::keyClick(&view,Qt::Key_Space);QTest::qWait(20);interaction=spy.count()==1;}
        if(!interaction)interactionDiagnostic=!button?"workspace_button_missing":!button->isEnabled()?"workspace_button_disabled":QString("workspace_key_action_count_%1_focus_%2").arg(spy.count()).arg(button->hasActiveFocus());
    }
    stage("interaction",interaction,interactionDiagnostic.toUtf8().constData()); if(!interaction){finish(false);return 0;}
    if(mode=="preview") {
        emitJson({{"phase","preview_opened"},{"progress",1.0}});
        // Preview lifetime is bounded independently by the service deadline;
        // closing this window also ends its event loop immediately.
        QObject::connect(&view,&QWindow::visibleChanged,&app,[&](bool visible){if(!visible)app.quit();});
        QTimer::singleShot(20000,&app,&QCoreApplication::quit);
        app.exec();
    }
    finish(mode=="preview"); return 0;
}
