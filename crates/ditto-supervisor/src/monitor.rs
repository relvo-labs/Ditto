//! The responsiveness state machine and the loop that drives it. Clock,
//! pinger and effects are traits so the timing can be tested without
//! sleeping and without a Shell.

use std::time::Duration;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// `pong <n>` for this ping's `n`, within the deadline.
    Pong,
    /// Connected (or the connection queued) but no matching reply in time.
    NoReply(String),
    /// No socket, or nothing listening on it: the Shell is not running.
    /// Exits are Core's to handle (its launcher sees them), not a miss.
    Absent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Absent,
    /// Listening but has never answered. A Shell without the `ping` handler
    /// ignores the line, so counting it as unresponsive would kill a healthy
    /// Shell every six seconds.
    Unarmed,
    Armed {
        misses: u32,
    },
    /// Killed and handed to rescue; waits for a new Shell to answer.
    Tripped,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    None,
    Trip { misses: u32 },
}

/// Which rule an armed Shell is judged by (#226). A Shell answers `pong` as
/// soon as its socket is up, then its UI thread stalls for seconds while it
/// connects to Core and mounts the boot providers; on a slow machine that is
/// longer than the steady rule allows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// The first `startup_grace` after this Shell generation was armed: a trip
    /// needs `startup_misses` in a row.
    Startup,
    /// After the grace: `misses` in a row, the rule NFR-08 is measured by.
    Steady,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Startup => "startup",
            Phase::Steady => "steady",
        }
    }
}

pub struct Monitor {
    pub state: State,
    threshold: u32,
    startup_threshold: u32,
    grace_ms: u64,
    /// When the current Shell generation was armed, on the monitor's clock.
    armed_at_ms: u64,
    /// The phase the last observation of an armed Shell was judged in.
    pub phase: Phase,
}

impl Monitor {
    /// The steady rule only, without a startup grace.
    pub fn new(threshold: u32) -> Self {
        let threshold = threshold.max(1);
        Self {
            state: State::Absent,
            threshold,
            startup_threshold: threshold,
            grace_ms: 0,
            armed_at_ms: 0,
            phase: Phase::Steady,
        }
    }

    /// For `grace` after each arming, require `misses` in a row. A grace is
    /// never stricter than the steady rule.
    pub fn with_startup_grace(mut self, grace: Duration, misses: u32) -> Self {
        self.grace_ms = grace.as_millis().try_into().unwrap_or(u64::MAX);
        self.startup_threshold = misses.max(self.threshold);
        self
    }

    pub fn from_timing(timing: &Timing) -> Self {
        Self::new(timing.misses).with_startup_grace(timing.startup_grace, timing.startup_misses)
    }

    fn phase_at(&self, now_ms: u64) -> Phase {
        if now_ms.saturating_sub(self.armed_at_ms) < self.grace_ms {
            Phase::Startup
        } else {
            Phase::Steady
        }
    }

    /// `now_ms` is when `outcome` was observed, on the monitor's clock. The
    /// threshold for a miss is the one of the phase at that moment, and the
    /// count is not reset when the grace ends: once it has ended, a streak
    /// that began inside it trips as soon as it reaches the steady count.
    pub fn observe(&mut self, outcome: &Outcome, now_ms: u64) -> Action {
        if matches!(self.state, State::Armed { .. }) {
            self.phase = self.phase_at(now_ms);
        }
        let (next, action) = match (self.state, outcome) {
            (State::Armed { .. }, Outcome::Pong) => (State::Armed { misses: 0 }, Action::None),
            // A new Shell generation (first answer, or a new Shell after an
            // exit or a trip): its startup grace begins now.
            (_, Outcome::Pong) => {
                self.armed_at_ms = now_ms;
                self.phase = self.phase_at(now_ms);
                (State::Armed { misses: 0 }, Action::None)
            }
            (_, Outcome::Absent) => (State::Absent, Action::None),
            (State::Absent | State::Unarmed, Outcome::NoReply(_)) => (State::Unarmed, Action::None),
            (State::Tripped, Outcome::NoReply(_)) => (State::Tripped, Action::None),
            (State::Armed { misses }, Outcome::NoReply(_)) => {
                let misses = misses + 1;
                let threshold = match self.phase {
                    Phase::Startup => self.startup_threshold,
                    Phase::Steady => self.threshold,
                };
                if misses >= threshold {
                    (State::Tripped, Action::Trip { misses })
                } else {
                    (State::Armed { misses }, Action::None)
                }
            }
        };
        self.state = next;
        action
    }
}

pub trait Clock {
    /// Milliseconds since an arbitrary, monotonic origin.
    fn now_ms(&self) -> u64;
    fn sleep(&self, duration: Duration);
}

pub trait Pinger {
    fn ping(&mut self, sequence: u64, timeout: Duration) -> Outcome;
}

pub trait Effects {
    /// SIGKILL the Shell and start the rescue UI. `phase` is the rule that
    /// tripped, so a startup hang can be told from a steady one in the log.
    fn trip(&mut self, misses: u32, last: &Outcome, phase: Phase);
    /// `phase` is meaningful when `to` is `Armed` or `Tripped`.
    fn transition(&mut self, from: State, to: State, outcome: &Outcome, phase: Phase);
    /// The armed Shell's startup grace is over; `misses` is its current streak.
    fn grace_ended(&mut self, misses: u32);
}

pub struct Timing {
    pub interval: Duration,
    pub timeout: Duration,
    pub misses: u32,
    /// How long after a Shell generation is armed `startup_misses` applies.
    pub startup_grace: Duration,
    pub startup_misses: u32,
}

impl Default for Timing {
    /// The startup values come from the TCG measurements in #226: stalls of
    /// 6.1 s and 5.1 s (up to ~8.6 s of late replies) ending ~25 s after
    /// launch. Ten misses is ~20 s of silence; sixty seconds covers startup
    /// twice over. A Shell that hangs during startup still trips.
    fn default() -> Self {
        Self {
            interval: Duration::from_secs(2),
            timeout: Duration::from_secs(1),
            misses: 3,
            startup_grace: Duration::from_secs(60),
            startup_misses: 10,
        }
    }
}

/// Ping every `interval`, measured start to start, so a slow reply does not
/// stretch the detection window. `rounds` bounds the loop for tests.
pub fn run(
    clock: &dyn Clock,
    pinger: &mut dyn Pinger,
    effects: &mut dyn Effects,
    timing: &Timing,
    rounds: Option<u64>,
) {
    let mut monitor = Monitor::from_timing(timing);
    let mut sequence = 0u64;
    loop {
        if rounds.is_some_and(|rounds| sequence >= rounds) {
            return;
        }
        sequence += 1;
        let started = clock.now_ms();
        let outcome = pinger.ping(sequence, timing.timeout);
        let (before, before_phase) = (monitor.state, monitor.phase);
        let action = monitor.observe(&outcome, clock.now_ms());
        if std::mem::discriminant(&before) != std::mem::discriminant(&monitor.state) {
            effects.transition(before, monitor.state, &outcome, monitor.phase);
        } else if let State::Armed { misses } = monitor.state {
            if before_phase == Phase::Startup && monitor.phase == Phase::Steady {
                effects.grace_ended(misses);
            }
        }
        if let Action::Trip { misses } = action {
            effects.trip(misses, &outcome, monitor.phase);
        }
        let elapsed = clock.now_ms().saturating_sub(started);
        let interval = timing.interval.as_millis() as u64;
        if elapsed < interval {
            clock.sleep(Duration::from_millis(interval - elapsed));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::collections::VecDeque;
    use std::rc::Rc;

    #[derive(Clone, Default)]
    struct FakeClock(Rc<Cell<u64>>);

    impl Clock for FakeClock {
        fn now_ms(&self) -> u64 {
            self.0.get()
        }
        fn sleep(&self, duration: Duration) {
            self.0.set(self.0.get() + duration.as_millis() as u64);
        }
    }

    /// Scripted replies; a miss costs the whole timeout, like a stopped Shell.
    struct FakeSocket {
        clock: FakeClock,
        script: VecDeque<Outcome>,
        sequences: Vec<u64>,
    }

    impl Pinger for FakeSocket {
        fn ping(&mut self, sequence: u64, timeout: Duration) -> Outcome {
            self.sequences.push(sequence);
            let outcome = self.script.pop_front().unwrap_or(Outcome::Absent);
            match outcome {
                Outcome::NoReply(_) => self.clock.sleep(timeout),
                _ => self.clock.sleep(Duration::from_millis(3)),
            }
            outcome
        }
    }

    #[derive(Default)]
    struct Recorder {
        clock: FakeClock,
        trips: Vec<(u64, u32)>,
        trip_phases: Vec<Phase>,
        states: Vec<State>,
        /// The phase reported with each transition into `Armed`.
        armed_phases: Vec<Phase>,
        grace_ended: Vec<(u64, u32)>,
    }

    impl Effects for Recorder {
        fn trip(&mut self, misses: u32, _: &Outcome, phase: Phase) {
            self.trips.push((self.clock.now_ms(), misses));
            self.trip_phases.push(phase);
        }
        fn transition(&mut self, _: State, to: State, _: &Outcome, phase: Phase) {
            self.states.push(to);
            if matches!(to, State::Armed { .. }) {
                self.armed_phases.push(phase);
            }
        }
        fn grace_ended(&mut self, misses: u32) {
            self.grace_ended.push((self.clock.now_ms(), misses));
        }
    }

    fn miss() -> Outcome {
        Outcome::NoReply("timeout".into())
    }

    /// The steady rule alone (no startup grace), as before #226.
    fn steady() -> Timing {
        Timing {
            startup_grace: Duration::ZERO,
            ..Timing::default()
        }
    }

    fn drive(script: Vec<Outcome>) -> (Recorder, Vec<u64>) {
        drive_with(&steady(), script)
    }

    /// The shipped defaults, startup grace included.
    fn drive_default(script: Vec<Outcome>) -> (Recorder, Vec<u64>) {
        drive_with(&Timing::default(), script)
    }

    fn drive_with(timing: &Timing, script: Vec<Outcome>) -> (Recorder, Vec<u64>) {
        let clock = FakeClock::default();
        let rounds = script.len() as u64;
        let mut socket = FakeSocket {
            clock: clock.clone(),
            script: script.into(),
            sequences: vec![],
        };
        let mut recorder = Recorder {
            clock: clock.clone(),
            ..Recorder::default()
        };
        run(&clock, &mut socket, &mut recorder, timing, Some(rounds));
        (recorder, socket.sequences)
    }

    #[test]
    fn three_consecutive_misses_trip_once() {
        let (recorder, sequences) =
            drive(vec![Outcome::Pong, miss(), miss(), miss(), miss(), miss()]);
        // Pings start at 0, 2, 4, 6 s; the third miss ends at 6 s + 1 s timeout.
        assert_eq!(recorder.trips, [(7_000, 3)]);
        assert_eq!(sequences, [1, 2, 3, 4, 5, 6]);
        assert_eq!(
            recorder.states,
            [State::Armed { misses: 0 }, State::Tripped]
        );
    }

    #[test]
    fn a_pong_resets_the_count() {
        let (recorder, _) = drive(vec![
            Outcome::Pong,
            miss(),
            miss(),
            Outcome::Pong,
            miss(),
            miss(),
            Outcome::Pong,
        ]);
        assert!(recorder.trips.is_empty());
    }

    #[test]
    fn never_answered_or_absent_never_trips() {
        let (recorder, _) = drive(vec![
            miss(),
            miss(),
            miss(),
            miss(),
            Outcome::Absent,
            miss(),
            miss(),
            miss(),
        ]);
        assert!(recorder.trips.is_empty());
        assert_eq!(
            recorder.states,
            [State::Unarmed, State::Absent, State::Unarmed]
        );
    }

    #[test]
    fn a_new_shell_rearms_after_a_trip() {
        let script = vec![
            Outcome::Pong,
            miss(),
            miss(),
            miss(),
            Outcome::Absent,
            Outcome::Pong,
            miss(),
            miss(),
            miss(),
        ];
        let (recorder, _) = drive(script);
        assert_eq!(recorder.trips.len(), 2);
        assert_eq!(recorder.trips[1].0 - recorder.trips[0].0, 10_000);
    }

    fn pongs(count: usize) -> Vec<Outcome> {
        vec![Outcome::Pong; count]
    }

    /// #226: a slow machine's Shell stalls ~6 s right after it starts
    /// answering. That is startup, not a hang.
    #[test]
    fn a_startup_stall_inside_grace_does_not_trip() {
        let mut script = vec![Outcome::Pong, miss(), miss(), miss()];
        script.extend(pongs(5));
        let (recorder, _) = drive_default(script);
        assert!(recorder.trips.is_empty(), "{:?}", recorder.trips);
        assert_eq!(recorder.states, [State::Armed { misses: 0 }]);
    }

    /// The measured TCG profile: a 6.1 s stall, a few good replies, then a
    /// 5.1 s stall followed by replies slower than the deadline.
    #[test]
    fn the_tcg_startup_profile_does_not_trip() {
        let mut script = vec![Outcome::Pong, miss(), miss(), miss()];
        script.extend(pongs(2));
        script.extend([miss(), miss(), miss(), miss(), miss()]);
        script.extend(pongs(30));
        let (recorder, _) = drive_default(script);
        assert!(recorder.trips.is_empty(), "{:?}", recorder.trips);
    }

    /// A Shell that hangs for good during startup is still killed, once, at
    /// the startup threshold: pings at 2, 4, …, 20 s, the tenth ends at 21 s.
    #[test]
    fn a_startup_hang_trips_once_at_the_startup_threshold() {
        let mut script = vec![Outcome::Pong];
        script.extend(std::iter::repeat_n(miss(), 14));
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.trips, [(21_000, 10)]);
        assert_eq!(
            recorder.states,
            [State::Armed { misses: 0 }, State::Tripped]
        );
        assert_eq!(recorder.trip_phases, [Phase::Startup]);
        assert_eq!(recorder.armed_phases, [Phase::Startup]);
    }

    /// Armed by the pong observed at 3 ms; the grace ends at 60 003 ms. Pings
    /// start every 2 s, so ping 31 (60 000 → 60 003 ms) is the first one
    /// judged by the steady rule.
    #[test]
    fn after_the_grace_three_misses_trip_as_before() {
        let mut script = pongs(31);
        script.extend([miss(), miss(), miss(), miss()]);
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.grace_ended, [(60_003, 0)]);
        // Same as the steady rule: last pong at 60 000 ms, the third miss
        // starts at 66 000 ms and ends at 67 000 ms, 7 s later.
        assert_eq!(recorder.trips, [(67_000, 3)]);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
    }

    /// Pongs do not extend the grace of the same Shell generation.
    #[test]
    fn the_grace_is_not_extended_by_pongs() {
        let mut script = vec![Outcome::Pong, miss()];
        script.extend(pongs(40));
        script.extend([miss(), miss(), miss()]);
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.grace_ended.len(), 1);
        assert_eq!(recorder.trips, [(89_000, 3)]);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
    }

    /// A streak that starts inside the grace and is still going when it ends
    /// is judged by the steady rule from then on, counting the misses from
    /// inside the grace: pongs until the ping at 48 s, misses observed at 51,
    /// 53, 55, 57 and 59 s (five, under ten), and at 61 s the grace is over
    /// and six is past three.
    #[test]
    fn a_streak_that_crosses_the_grace_end_uses_the_steady_rule() {
        let mut script = pongs(25);
        script.extend(std::iter::repeat_n(miss(), 8));
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.trips, [(61_000, 6)]);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
        assert!(
            recorder.grace_ended.is_empty(),
            "the trip itself reports the phase"
        );

        // A streak that starts just before the end needs three in total.
        let mut script = pongs(28);
        script.extend(std::iter::repeat_n(miss(), 5));
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.trips, [(61_000, 3)]);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
    }

    /// After a trip, the next Shell to answer is a new generation and gets
    /// the startup grace again, with or without an observed exit between.
    #[test]
    fn a_new_shell_after_a_trip_gets_the_grace_again() {
        let mut script = vec![Outcome::Pong];
        script.extend(std::iter::repeat_n(miss(), 10));
        // Straight from Tripped to a new Shell's pong.
        script.push(Outcome::Pong);
        script.extend([miss(), miss(), miss(), miss(), miss()]);
        script.extend(pongs(2));
        // Through Absent to another new Shell.
        script.push(Outcome::Absent);
        script.push(Outcome::Pong);
        script.extend([miss(), miss(), miss(), miss()]);
        script.extend(pongs(2));
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.trips, [(21_000, 10)]);
        assert_eq!(
            recorder.states,
            [
                State::Armed { misses: 0 },
                State::Tripped,
                State::Armed { misses: 0 },
                State::Absent,
                State::Armed { misses: 0 },
            ]
        );
        assert_eq!(recorder.armed_phases, [Phase::Startup; 3]);
    }

    /// A Shell long past its grace exits; the next one starts its own grace.
    #[test]
    fn a_new_shell_after_an_exit_gets_the_grace_again() {
        let mut script = pongs(40);
        script.push(Outcome::Absent);
        script.push(miss()); // listening, not answering yet
        script.push(Outcome::Pong);
        script.extend([miss(), miss(), miss(), miss(), miss()]);
        script.extend(pongs(35));
        script.extend([miss(), miss(), miss()]);
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.grace_ended.len(), 2);
        assert_eq!(recorder.trips.len(), 1, "{:?}", recorder.trips);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
        assert_eq!(
            recorder.states,
            [
                State::Armed { misses: 0 },
                State::Absent,
                State::Unarmed,
                State::Armed { misses: 0 },
                State::Tripped,
            ]
        );
    }

    #[test]
    fn the_monitor_on_its_own() {
        let mut monitor = Monitor::new(3);
        assert_eq!(monitor.observe(&miss(), 0), Action::None);
        assert_eq!(monitor.state, State::Unarmed);
        monitor.observe(&Outcome::Pong, 0);
        monitor.observe(&miss(), 0);
        monitor.observe(&miss(), 0);
        assert_eq!(monitor.state, State::Armed { misses: 2 });
        assert_eq!(monitor.observe(&miss(), 0), Action::Trip { misses: 3 });
        assert_eq!(
            monitor.observe(&miss(), 0),
            Action::None,
            "a tripped Shell is not killed twice"
        );
        assert_eq!(Monitor::new(0).threshold, 1);
    }

    #[test]
    fn the_grace_boundary_on_the_monitor_clock() {
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::from_millis(1_000), 10);
        monitor.observe(&Outcome::Pong, 5_000);
        assert_eq!(monitor.phase, Phase::Startup);
        for _ in 0..9 {
            assert_eq!(monitor.observe(&miss(), 5_999), Action::None);
        }
        assert_eq!(monitor.phase, Phase::Startup);
        assert_eq!(monitor.observe(&Outcome::Pong, 5_999), Action::None);
        monitor.observe(&miss(), 6_000);
        assert_eq!(
            monitor.phase,
            Phase::Steady,
            "the grace is [armed, armed + grace)"
        );
        monitor.observe(&miss(), 6_000);
        assert_eq!(monitor.observe(&miss(), 6_000), Action::Trip { misses: 3 });

        // Ten misses inside the grace trip at ten, not never.
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::from_secs(60), 10);
        monitor.observe(&Outcome::Pong, 0);
        for at in 1..10 {
            assert_eq!(monitor.observe(&miss(), at), Action::None);
        }
        assert_eq!(monitor.observe(&miss(), 10), Action::Trip { misses: 10 });

        // A grace is never stricter than the steady rule; zero means none.
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::from_secs(60), 1);
        monitor.observe(&Outcome::Pong, 0);
        assert_eq!(monitor.observe(&miss(), 1), Action::None);
        assert_eq!(monitor.observe(&miss(), 2), Action::None);
        assert_eq!(monitor.observe(&miss(), 3), Action::Trip { misses: 3 });
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::ZERO, 10);
        monitor.observe(&Outcome::Pong, 0);
        assert_eq!(monitor.phase, Phase::Steady);
    }
}
