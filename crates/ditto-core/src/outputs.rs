//! Windows left behind when an output goes away (plan/03/05 §7, DES-08).
//!
//! Wayfire already moves the views of a destroyed output onto a remaining
//! one (matrix C-18), so Core does not move first and ask later: it waits for
//! the compositor to settle, reads the windows back, and moves only a window
//! that is still on a missing output or whose centre is off its output. A
//! window that cannot be moved (tiled: `unsupported`) is logged and the user
//! is told in a notification. What Core moved is read back again; a move the
//! readback does not confirm counts as not moved.

use std::{
    collections::{BTreeSet, HashSet},
    sync::{Arc, Weak},
    time::Duration,
};

use ditto_compositor::{AdapterError, AdapterResult, CompositorAdapter};
use ditto_protocol::{services::Urgency, Output, Window, WindowSessionId, WindowState};

use crate::core::Core;

/// How long Core lets the compositor finish its own moves before reading
/// the windows back. Wayfire announces the output removal before it has
/// moved every view; acting at once would move a window twice.
pub const SETTLE: Duration = Duration::from_millis(500);

/// A window Core could not bring back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stranded {
    pub window_id: WindowSessionId,
    pub app_id: String,
    pub title: String,
    /// `unsupported` (tiled), `readback` (moved but not where asked), or the
    /// adapter's error kind.
    pub reason: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Rescue {
    /// Windows that were on a vanished output, or are now on none.
    pub checked: usize,
    /// Already visible after the compositor's own handling; left alone.
    pub already_visible: usize,
    pub moved: Vec<WindowSessionId>,
    pub stranded: Vec<Stranded>,
}

/// The primary output: the one at the top left of the layout. Wayland has
/// no primary output; this rule is the one the Shell uses for the character
/// as well, so both pick the same output.
pub fn primary(outputs: &[Output]) -> Option<&Output> {
    outputs
        .iter()
        .filter(|output| output.enabled)
        .min_by_key(|output| (output.x, output.y, output.name.clone()))
}

fn centre_inside(window: &Window, output: &Output) -> Option<bool> {
    let (x, y, width, height) = (window.x?, window.y?, window.width?, window.height?);
    let cx = i64::from(x) + i64::from(width) / 2;
    let cy = i64::from(y) + i64::from(height) / 2;
    Some(cx >= 0 && cy >= 0 && cx < i64::from(output.width) && cy < i64::from(output.height))
}

/// Keep the window's own position where it fits, and pull it in where it
/// does not; a window larger than the output goes to its top left.
fn clamp(position: i32, size: u32, extent: u32) -> i32 {
    let room = i64::from(extent) - i64::from(size);
    i64::from(position).clamp(0, room.max(0)) as i32
}

/// Bring the windows of `vanished` outputs into view on a remaining output.
/// `before` is the window list from before the outputs went away: it names
/// which windows were on them.
pub fn rescue_windows(
    adapter: &mut dyn CompositorAdapter,
    vanished: &[String],
    before: &[Window],
) -> AdapterResult<Rescue> {
    let outputs: Vec<Output> = adapter
        .outputs()?
        .into_iter()
        .filter(|output| output.enabled)
        .collect();
    let mut rescue = Rescue::default();
    let Some(primary) = primary(&outputs).cloned() else {
        // Nowhere to put anything: the compositor has no output at all.
        return Ok(rescue);
    };
    let affected: HashSet<&WindowSessionId> = before
        .iter()
        .filter(|window| {
            window
                .output
                .as_ref()
                .is_some_and(|output| vanished.contains(output))
        })
        .map(|window| &window.id)
        .collect();
    let active: BTreeSet<String> = adapter
        .workspaces()?
        .into_iter()
        .filter(|workspace| workspace.active)
        .map(|workspace| workspace.id)
        .collect();
    for window in adapter.windows()? {
        if window.state == WindowState::Minimized {
            continue;
        }
        let home = window
            .output
            .as_ref()
            .and_then(|name| outputs.iter().find(|output| output.name == *name));
        let lost = window.output.is_some() && home.is_none();
        if !lost && !affected.contains(&window.id) {
            continue;
        }
        rescue.checked += 1;
        let (target, change_output) = match home {
            Some(home) => (home.clone(), false),
            None => (primary.clone(), true),
        };
        // A window on another workspace of a live output is in that
        // workspace's coordinates, not off-screen.
        let elsewhere = window
            .workspace_id
            .as_ref()
            .is_some_and(|workspace| !active.contains(workspace));
        if !change_output && (elsewhere || centre_inside(&window, &target) != Some(false)) {
            rescue.already_visible += 1;
            continue;
        }
        let (Some(x), Some(y), Some(width), Some(height)) =
            (window.x, window.y, window.width, window.height)
        else {
            rescue.stranded.push(stranded(&window, "no_geometry"));
            continue;
        };
        let (x, y) = (
            clamp(x, width, target.width),
            clamp(y, height, target.height),
        );
        let moved = if change_output {
            adapter.move_window_to_output(&window.id, &target.name, x, y)
        } else {
            adapter.move_window(&window.id, x, y)
        };
        match moved {
            Ok(()) => {}
            // Closed meanwhile: nothing left to bring back.
            Err(AdapterError::NotFound(_)) => continue,
            Err(AdapterError::Unavailable(reason)) => {
                return Err(AdapterError::Unavailable(reason))
            }
            Err(AdapterError::Unsupported(_)) => {
                rescue.stranded.push(stranded(&window, "unsupported"));
                continue;
            }
            Err(other) => {
                rescue.stranded.push(stranded(&window, error_kind(&other)));
                continue;
            }
        }
        // Readback: the window must now be on the target, centre inside.
        let confirmed = adapter.window(&window.id).ok().is_some_and(|after| {
            after.output.as_deref() == Some(target.name.as_str())
                && centre_inside(&after, &target) == Some(true)
        });
        if confirmed {
            rescue.moved.push(window.id.clone());
        } else {
            rescue.stranded.push(stranded(&window, "readback"));
        }
    }
    Ok(rescue)
}

fn stranded(window: &Window, reason: &str) -> Stranded {
    Stranded {
        window_id: window.id.clone(),
        app_id: window.app_id.clone(),
        title: window.title.clone(),
        reason: reason.into(),
    }
}

fn error_kind(error: &AdapterError) -> &'static str {
    match error {
        AdapterError::Unsupported(_) => "unsupported",
        AdapterError::NotFound(_) => "not_found",
        AdapterError::Unavailable(_) => "unavailable",
        AdapterError::ReadbackMismatch(_) => "readback",
        AdapterError::Internal(_) => "internal",
    }
}

/// What the notification says, in the Profile's language. Core has no
/// translation catalogue; a notification is plain text by the time it is
/// posted, so the two Ditto languages are written out here.
pub fn notice(locale: &str, vanished: &[String], stranded: &[Stranded]) -> (String, String) {
    let names: Vec<String> = stranded
        .iter()
        .take(3)
        .map(|window| {
            if window.title.trim().is_empty() {
                window.app_id.clone()
            } else {
                window.title.clone()
            }
        })
        .collect();
    let more = stranded.len().saturating_sub(names.len());
    let outputs = vanished.join(", ");
    if locale.starts_with("en") {
        let list = if more > 0 {
            format!("{} and {more} more", names.join(", "))
        } else {
            names.join(", ")
        };
        (
            "Some windows could not be brought back".into(),
            format!(
                "After the screen {outputs} was disconnected, these windows could not be moved onto the remaining screen: {list}. They are arranged by the tiling layout; switch to the floating layout or pick them from the window list."
            ),
        )
    } else {
        let list = if more > 0 {
            format!("{} 等 {} 個", names.join("、"), stranded.len())
        } else {
            names.join("、")
        };
        (
            "有視窗沒辦法移回畫面".into(),
            format!(
                "螢幕 {outputs} 移除後，這些視窗沒辦法自動移到剩下的螢幕：{list}。它們由平鋪布局排列；可以改用浮動布局，或從視窗清單選取它們。"
            ),
        )
    }
}

fn locale(core: &Core) -> String {
    core.read(|connection| {
        let Some(active) = ditto_store::profiles::active_profile(connection)? else {
            return Ok(None);
        };
        let (_, _, document) = ditto_store::profiles::head_document(connection, &active)?;
        Ok(Some(document.appearance.locale))
    })
    .ok()
    .flatten()
    .unwrap_or_else(|| "zh-TW".into())
}

/// Run one rescue on `core` now: read back, move what needs it, publish the
/// result as desktop events, log it, and tell the user what stayed behind.
pub fn handle(core: &Core, vanished: &[String], before: &[Window]) -> Option<Rescue> {
    let outcome = core
        .session
        .with_adapter(|adapter| rescue_windows(adapter, vanished, before));
    let rescue = match outcome {
        Ok(rescue) => rescue,
        Err(error) => {
            crate::log::event(
                "outputs.rescue_failed",
                &[
                    ("outputs", &vanished.join(",")),
                    ("reason", &format!("{error:?}")),
                    ("reason_code", error_kind(&error)),
                ],
            );
            return None;
        }
    };
    if !rescue.moved.is_empty() {
        core.session.publish_changes();
    }
    crate::log::event(
        "outputs.removed",
        &[
            ("outputs", &vanished.join(",")),
            ("checked", &rescue.checked.to_string()),
            ("already_visible", &rescue.already_visible.to_string()),
            ("moved", &rescue.moved.len().to_string()),
            ("stranded", &rescue.stranded.len().to_string()),
        ],
    );
    for window in &rescue.stranded {
        crate::log::event(
            "outputs.window_stranded",
            &[
                ("window_id", &window.window_id.0),
                ("app_id", &window.app_id),
                ("reason_code", &window.reason),
            ],
        );
    }
    if !rescue.stranded.is_empty() {
        let (summary, body) = notice(&locale(core), vanished, &rescue.stranded);
        if let Err(error) = core
            .system
            .post_notification(&summary, &body, Urgency::Normal)
        {
            crate::log::event(
                "outputs.notice_failed",
                &[
                    ("reason", &format!("{error:?}")),
                    (
                        "reason_code",
                        match &error {
                            ditto_system::SystemError::Unavailable(_) => "unavailable",
                            ditto_system::SystemError::NotFound(_) => "not_found",
                            ditto_system::SystemError::Invalid(_) => "invalid",
                            ditto_system::SystemError::Failed(_) => "failed",
                        },
                    ),
                ],
            );
        }
    }
    Some(rescue)
}

/// Follow output removals for as long as Core lives. Each removal is handled
/// on its own thread after [`SETTLE`], so the compositor event pump never
/// waits on it.
pub fn install(core: &Arc<Core>, settle: Duration) {
    let weak: Weak<Core> = Arc::downgrade(core);
    core.session
        .set_outputs_removed(Arc::new(move |vanished, before| {
            let weak = weak.clone();
            let _ = std::thread::Builder::new()
                .name("ditto-outputs".into())
                .spawn(move || {
                    std::thread::sleep(settle);
                    if let Some(core) = weak.upgrade() {
                        handle(&core, &vanished, &before);
                    }
                });
        }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use ditto_compositor::fixture::FixtureCompositor;

    fn floating() -> WindowSessionId {
        WindowSessionId("fixture-window-2".into())
    }

    fn tiled() -> WindowSessionId {
        WindowSessionId("fixture-window-1".into())
    }

    #[test]
    fn a_window_left_on_a_vanished_output_is_moved_onto_the_primary() {
        let (mut compositor, _events) = FixtureCompositor::paired();
        compositor.add_output("FIXTURE-2", 1280, 720);
        compositor
            .move_window_to_output(&floating(), "FIXTURE-2", 900, 500)
            .unwrap();
        let before = compositor.windows().unwrap();
        compositor.remove_output("FIXTURE-2", false);
        let rescue = rescue_windows(&mut compositor, &["FIXTURE-2".into()], &before).unwrap();
        assert_eq!(rescue.moved, vec![floating()]);
        assert!(rescue.stranded.is_empty());
        let window = compositor.window(&floating()).unwrap();
        assert_eq!(window.output.as_deref(), Some("FIXTURE-1"));
        assert_eq!(
            (window.x, window.y),
            (Some(900), Some(500)),
            "it fits as it was"
        );
    }

    #[test]
    fn a_window_the_compositor_already_moved_into_view_is_left_alone() {
        let (mut compositor, _events) = FixtureCompositor::paired();
        compositor.add_output("FIXTURE-2", 1280, 720);
        compositor
            .move_window_to_output(&floating(), "FIXTURE-2", 100, 100)
            .unwrap();
        let before = compositor.windows().unwrap();
        compositor.remove_output("FIXTURE-2", true);
        let rescue = rescue_windows(&mut compositor, &["FIXTURE-2".into()], &before).unwrap();
        assert_eq!(rescue.checked, 1);
        assert_eq!(rescue.already_visible, 1);
        assert!(
            rescue.moved.is_empty(),
            "no second move after the compositor's"
        );
    }

    #[test]
    fn a_window_the_compositor_moved_off_screen_is_pulled_into_view() {
        let (mut compositor, _events) = FixtureCompositor::paired();
        compositor.add_output("FIXTURE-2", 2560, 1440);
        compositor
            .move_window_to_output(&floating(), "FIXTURE-2", 2200, 1200)
            .unwrap();
        let before = compositor.windows().unwrap();
        compositor.remove_output("FIXTURE-2", true);
        let rescue = rescue_windows(&mut compositor, &["FIXTURE-2".into()], &before).unwrap();
        assert_eq!(rescue.moved, vec![floating()]);
        let window = compositor.window(&floating()).unwrap();
        // 640×480 on 1920×1080: pulled in to the right and bottom edges.
        assert_eq!((window.x, window.y), (Some(1280), Some(600)));
    }

    #[test]
    fn a_tiled_window_that_cannot_move_is_reported_not_moved() {
        let (mut compositor, _events) = FixtureCompositor::paired();
        compositor.add_output("FIXTURE-2", 1280, 720);
        compositor.place(&tiled(), "FIXTURE-2", 0, 0);
        let before = compositor.windows().unwrap();
        compositor.remove_output("FIXTURE-2", false);
        let rescue = rescue_windows(&mut compositor, &["FIXTURE-2".into()], &before).unwrap();
        assert!(rescue.moved.is_empty());
        assert_eq!(rescue.stranded.len(), 1);
        assert_eq!(rescue.stranded[0].window_id, tiled());
        assert_eq!(rescue.stranded[0].reason, "unsupported");
    }

    #[test]
    fn windows_that_were_never_on_the_vanished_output_are_not_touched() {
        let (mut compositor, _events) = FixtureCompositor::paired();
        compositor.add_output("FIXTURE-2", 1280, 720);
        // Partly off the right edge of the remaining output, by the user's
        // choice; the unplug did not put it there.
        compositor.move_window(&floating(), 1800, 100).unwrap();
        let before = compositor.windows().unwrap();
        compositor.remove_output("FIXTURE-2", false);
        let rescue = rescue_windows(&mut compositor, &["FIXTURE-2".into()], &before).unwrap();
        assert_eq!(rescue, Rescue::default());
        assert_eq!(compositor.window(&floating()).unwrap().x, Some(1800));
    }

    #[test]
    fn the_notice_names_the_windows_in_the_profile_language() {
        let stranded = vec![Stranded {
            window_id: tiled(),
            app_id: "foot".into(),
            title: "".into(),
            reason: "unsupported".into(),
        }];
        let (summary, body) = notice("zh-TW", &["HDMI-A-1".into()], &stranded);
        assert_eq!(summary, "有視窗沒辦法移回畫面");
        assert!(body.contains("HDMI-A-1") && body.contains("foot"));
        let (summary, _) = notice("en", &["HDMI-A-1".into()], &stranded);
        assert_eq!(summary, "Some windows could not be brought back");
    }
}
