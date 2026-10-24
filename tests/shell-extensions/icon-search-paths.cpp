// Test-only LD_PRELOAD shim for the real-Quickshell launcher icon check (#188).
//
// Qt's offscreen platform theme reports no icon theme search paths, so
// QIcon::themeSearchPaths() is only ":/icons" and every theme lookup fails.
// The Wayland and X11 platform themes (QGenericUnixTheme) search
// $XDG_DATA_DIRS/icons; this sets the same list once the application exists.
// Nothing else changes: Quickshell still picks the theme (IconTheme pragma),
// checks hasThemeIcon() and serves image://icon/<name> itself.
#include <QCoreApplication>
#include <QDir>
#include <QIcon>
#include <QStringList>

static void dittoIconSearchPaths()
{
    QStringList paths;
    const QStringList dirs = qEnvironmentVariable("XDG_DATA_DIRS", QStringLiteral("/usr/local/share:/usr/share"))
                                 .split(u':', Qt::SkipEmptyParts);
    for (const QString &dir : dirs)
        paths << QDir(dir).filePath(QStringLiteral("icons"));
    QIcon::setThemeSearchPaths(paths);
}
Q_COREAPP_STARTUP_FUNCTION(dittoIconSearchPaths)
