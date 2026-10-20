#include <QtQml/QQmlExtensionPlugin>
#include <QtQml/qqml.h>
#include <QtDBus/QtDBus>
#include <QtNetwork/QNetworkInterface>
#include <QtCore/QTimer>
#include <memory>

// A panel-local observation, not a desktop.* capability or stored configuration.
// Only ListLinks/GetAll are called; D-Bus activation is disabled. A routable
// networkd link proves local connectivity, never Internet reachability.
class NetworkdStatus : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY changed)
    Q_PROPERTY(QString kind READ kind NOTIFY changed)
public:
    explicit NetworkdStatus(QObject *parent = nullptr)
        : QObject(parent), bus(QDBusConnection::systemBus()), watcher(this) {
        refreshTimer.setSingleShot(true);
        connect(&refreshTimer, &QTimer::timeout, this, &NetworkdStatus::refresh);
        watcher.setConnection(bus);
        watcher.setWatchMode(QDBusServiceWatcher::WatchForOwnerChange);
        connect(&watcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
                [this](const QString &, const QString &, const QString &owner) {
            ++epoch;
            busy = false;
            publish(false, "other");
            if (!owner.isEmpty()) queueRefresh();
        });
    }
    bool enabled() const { return active; }
    bool connected() const { return live; }
    QString kind() const { return medium; }
    void setEnabled(bool value) {
        if (active == value) return;
        active = value;
        ++epoch;
        busy = false;
        refreshTimer.stop();
        publish(false, "other");
        if (active) {
            watcher.addWatchedService(service);
            bus.connect(service, {}, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                        this, SLOT(propertiesChanged(QString,QVariantMap,QStringList)));
            queueRefresh();
        } else {
            watcher.removeWatchedService(service);
            bus.disconnect(service, {}, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                           this, SLOT(propertiesChanged(QString,QVariantMap,QStringList)));
        }
        emit enabledChanged();
    }
signals:
    void enabledChanged();
    void changed();
private slots:
    void propertiesChanged(const QString &interface, const QVariantMap &, const QStringList &) {
        if (interface.startsWith("org.freedesktop.network1.")) queueRefresh();
    }
private:
    const QString service = "org.freedesktop.network1";
    QDBusConnection bus;
    QDBusServiceWatcher watcher;
    QTimer refreshTimer;
    bool active = false, live = false, busy = false, dirty = false;
    QString medium = "other";
    quint64 epoch = 0;

    void publish(bool value, const QString &kind) {
        if (live == value && medium == kind) return;
        live = value;
        medium = kind;
        emit changed();
    }
    void queueRefresh() {
        if (!active) return;
        // Invalidate before reading again. An error or removed service cannot
        // leave a stale connected icon. Coalesce events while a read is pending.
        publish(false, "other");
        dirty = true;
        if (!busy && !refreshTimer.isActive()) refreshTimer.start(0);
    }
    QDBusPendingCall query(const QString &path, const QString &interface,
                          const QString &method, const QVariantList &args = {}) {
        auto request = QDBusMessage::createMethodCall(service, path, interface, method);
        request.setAutoStartService(false);
        request.setArguments(args);
        return bus.asyncCall(request, 1500);
    }
    void finish(bool value, const QString &kind) {
        busy = false;
        if (dirty) queueRefresh();
        else publish(value, kind);
    }
    void refresh() {
        if (!active || busy) return;
        busy = true;
        dirty = false;
        const auto generation = epoch;
        auto *call = new QDBusPendingCallWatcher(query("/org/freedesktop/network1",
            "org.freedesktop.network1.Manager", "ListLinks"), this);
        connect(call, &QDBusPendingCallWatcher::finished, this, [this, generation, call] {
            const auto reply = call->reply();
            call->deleteLater();
            if (!active || generation != epoch) return;
            if (reply.type() == QDBusMessage::ErrorMessage || reply.signature() != "a(iso)") {
                finish(false, "other");
                return;
            }
            struct Link { int index; QString name; QDBusObjectPath path; };
            QList<Link> links;
            const auto array = qvariant_cast<QDBusArgument>(reply.arguments().first());
            array.beginArray();
            while (!array.atEnd() && links.size() < 64) {
                Link link;
                array.beginStructure();
                array >> link.index >> link.name >> link.path;
                array.endStructure();
                links.append(link);
            }
            array.endArray();
            if (links.isEmpty()) { finish(false, "other"); return; }
            struct Snapshot { int pending; QString kind; };
            auto snapshot = std::make_shared<Snapshot>(Snapshot{int(links.size()), {}});
            for (const auto &link : links) {
                auto *properties = new QDBusPendingCallWatcher(query(link.path.path(),
                    "org.freedesktop.DBus.Properties", "GetAll", {"org.freedesktop.network1.Link"}), this);
                connect(properties, &QDBusPendingCallWatcher::finished, this,
                        [this, generation, properties, index = link.index, snapshot] {
                    QDBusPendingReply<QVariantMap> result = *properties;
                    properties->deleteLater();
                    if (!active || generation != epoch) return;
                    if (!result.isError()) {
                        const auto state = result.value();
                        const auto device = QNetworkInterface::interfaceFromIndex(index);
                        // Ignore loopback, down interfaces and unknown media.
                        // networkd must actually own and have configured the link.
                        if (state.value("AdministrativeState").toString() == "configured"
                            && state.value("OperationalState").toString() == "routable"
                            && state.value("AddressState").toString() == "routable"
                            && device.flags().testFlag(QNetworkInterface::IsUp)
                            && device.flags().testFlag(QNetworkInterface::IsRunning)
                            && !device.flags().testFlag(QNetworkInterface::IsLoopBack)) {
                            if (device.type() == QNetworkInterface::Ethernet) snapshot->kind = "wired";
                            else if (device.type() == QNetworkInterface::Wifi && snapshot->kind.isEmpty())
                                snapshot->kind = "wireless";
                        }
                    }
                    if (--snapshot->pending == 0) finish(!snapshot->kind.isEmpty(), snapshot->kind);
                });
            }
        });
    }
};

class NetworkPlugin : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void registerTypes(const char *uri) override {
        qmlRegisterType<NetworkdStatus>(uri, 1, 0, "NetworkdStatus");
    }
};

#include "network.moc"
