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

/// Which Shell answered: the generation a `pong` belongs to. Read from the
/// connection itself, not inferred from an observed exit, because Core can
/// relaunch a crashed Shell faster than one ping interval and the supervisor
/// then never sees the socket absent (review of #227).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Peer {
    /// The process listening on the socket (`SO_PEERCRED`), with its start
    /// time (field 22 of `/proc/<pid>/stat`, `None` if unreadable) so a
    /// reused PID can be told apart. Compare with `provably_differs_from`.
    Process { pid: u32, start: Option<u64> },
    /// The peer could not be read. It never starts a generation by itself:
    /// in any state it is taken to be possibly the same Shell, so the
    /// supervisor errs toward rescue (a replacement may miss its grace),
    /// never away from it.
    Unknown { connection: u64 },
}

impl Peer {
    pub fn describe(self) -> String {
        match self {
            Peer::Process { pid, .. } => format!("pid:{pid}"),
            Peer::Unknown { .. } => "unknown".into(),
        }
    }

    /// **The identity rule.** Two observations are possibly the same process
    /// unless they are provably different: both identified and either the
    /// PIDs differ, or the PID is the same and both start times are known
    /// and differ. A missing start time or an unknown peer proves nothing.
    /// Uncertain means the same generation, which keeps the grace from being
    /// renewed: the supervisor errs toward rescue, never away from it. (A
    /// replacement that cannot be told apart may then be judged by the steady
    /// rule while it starts.) Never compare peers with `==` for this.
    pub fn provably_differs_from(self, other: Peer) -> bool {
        match (self, other) {
            (Peer::Process { pid: a, start: sa }, Peer::Process { pid: b, start: sb }) => {
                a != b || matches!((sa, sb), (Some(x), Some(y)) if x != y)
            }
            _ => false,
        }
    }

    /// What is known about the armed process after `observed`, which is not
    /// provably different from it: a start time learnt for the same PID is
    /// kept, so a later reuse of that PID can be told apart. Never forgets.
    fn learn(armed: Option<Peer>, observed: Peer) -> Option<Peer> {
        match (armed, observed) {
            (None, Peer::Process { .. }) => Some(observed),
            (
                Some(Peer::Process { pid, start: None }),
                Peer::Process {
                    pid: seen,
                    start: Some(start),
                },
            ) if pid == seen => Some(Peer::Process {
                pid,
                start: Some(start),
            }),
            _ => armed,
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
    /// The identified process of the current generation, if one has
    /// answered; never `Peer::Unknown`.
    pub peer: Option<Peer>,
    /// Counts Shell generations; changes whenever a new one is armed.
    pub generation: u64,
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
            peer: None,
            generation: 0,
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

    fn new_generation(&mut self, identified: Option<Peer>, now_ms: u64) -> (State, Action) {
        self.peer = identified;
        self.generation += 1;
        self.armed_at_ms = now_ms;
        self.phase = self.phase_at(now_ms);
        (State::Armed { misses: 0 }, Action::None)
    }

    /// `now_ms` is when `outcome` was observed, on the monitor's clock, and
    /// `peer` is who was on the other end of the connection. The threshold
    /// for a miss is the one of the phase at that moment, and the count is not
    /// reset when the grace ends: once it has ended, a streak that began
    /// inside it trips as soon as it reaches the steady count.
    pub fn observe(&mut self, outcome: &Outcome, peer: Peer, now_ms: u64) -> Action {
        if matches!(self.state, State::Armed { .. }) {
            self.phase = self.phase_at(now_ms);
        }
        let identified = matches!(peer, Peer::Process { .. }).then_some(peer);
        // The generation follows the process, not the state (review round 4):
        // in any state, only the first answer ever or a process provably
        // different from the last armed one starts a new generation.
        let (next, action) = match (self.state, outcome) {
            (_, Outcome::Pong)
                if self.generation == 0
                    || self
                        .peer
                        .is_some_and(|armed| armed.provably_differs_from(peer)) =>
            {
                self.new_generation(identified, now_ms)
            }
            // Possibly the same process (see the identity rule): its own
            // generation goes on, with the grace counted from its first
            // arming, learning what can be learnt about its identity. Armed,
            // after a reconnect; or after Absent, Unarmed or a trip whose kill
            // did not take: a Shell past its grace resumes the steady rule, its
            // misses start again from zero. No observation of one Shell, no
            // reconnect and no Absent can earn it a new grace.
            (_, Outcome::Pong) => {
                self.peer = Peer::learn(self.peer, peer);
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
    /// Who the last `ping` talked to, identified when its connection was made.
    fn peer(&self) -> Peer;
}

pub trait Effects {
    /// SIGKILL the Shell and start the rescue UI. `phase` is the rule that
    /// tripped, so a startup hang can be told from a steady one in the log.
    fn trip(&mut self, misses: u32, last: &Outcome, phase: Phase);
    /// A state change, or a new Shell generation while armed (`from` and `to`
    /// both `Armed`). `phase` and `peer` are meaningful when `to` is `Armed`
    /// or `Tripped`.
    fn transition(&mut self, from: State, to: State, outcome: &Outcome, phase: Phase, peer: Peer);
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
        let peer = pinger.peer();
        let (before, before_phase, before_generation) =
            (monitor.state, monitor.phase, monitor.generation);
        let action = monitor.observe(&outcome, peer, clock.now_ms());
        if std::mem::discriminant(&before) != std::mem::discriminant(&monitor.state)
            || before_generation != monitor.generation
        {
            let armed = monitor.peer.unwrap_or(peer);
            effects.transition(before, monitor.state, &outcome, monitor.phase, armed);
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

    /// Scripted replies, each from a scripted peer; a miss costs the whole
    /// timeout, like a stopped Shell.
    struct FakeSocket {
        clock: FakeClock,
        script: VecDeque<(Outcome, Peer)>,
        peer: Peer,
        sequences: Vec<u64>,
    }

    impl Pinger for FakeSocket {
        fn ping(&mut self, sequence: u64, timeout: Duration) -> Outcome {
            self.sequences.push(sequence);
            let (outcome, peer) = self
                .script
                .pop_front()
                .unwrap_or((Outcome::Absent, SHELL_A));
            self.peer = peer;
            match outcome {
                Outcome::NoReply(_) => self.clock.sleep(timeout),
                _ => self.clock.sleep(Duration::from_millis(3)),
            }
            outcome
        }
        fn peer(&self) -> Peer {
            self.peer
        }
    }

    const SHELL_A: Peer = Peer::Process {
        pid: 4100,
        start: Some(900),
    };
    const SHELL_B: Peer = Peer::Process {
        pid: 4200,
        start: Some(1_300),
    };
    /// SHELL_A's PID reused by another process later.
    const SHELL_A_REUSED: Peer = Peer::Process {
        pid: 4100,
        start: Some(5_000),
    };

    /// `outcomes`, all from `peer`.
    fn from(peer: Peer, outcomes: Vec<Outcome>) -> Vec<(Outcome, Peer)> {
        outcomes.into_iter().map(|o| (o, peer)).collect()
    }

    #[derive(Default)]
    struct Recorder {
        clock: FakeClock,
        trips: Vec<(u64, u32)>,
        trip_phases: Vec<Phase>,
        states: Vec<State>,
        /// The phase reported with each transition into `Armed`.
        armed_phases: Vec<Phase>,
        /// The peer reported with each transition into `Armed`.
        armed_peers: Vec<Peer>,
        grace_ended: Vec<(u64, u32)>,
    }

    impl Effects for Recorder {
        fn trip(&mut self, misses: u32, _: &Outcome, phase: Phase) {
            self.trips.push((self.clock.now_ms(), misses));
            self.trip_phases.push(phase);
        }
        fn transition(&mut self, _: State, to: State, _: &Outcome, phase: Phase, peer: Peer) {
            self.states.push(to);
            if matches!(to, State::Armed { .. }) {
                self.armed_phases.push(phase);
                self.armed_peers.push(peer);
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

    /// One Shell (one peer) throughout.
    fn drive_with(timing: &Timing, script: Vec<Outcome>) -> (Recorder, Vec<u64>) {
        drive_peers(timing, from(SHELL_A, script))
    }

    fn drive_peers(timing: &Timing, script: Vec<(Outcome, Peer)>) -> (Recorder, Vec<u64>) {
        let clock = FakeClock::default();
        let rounds = script.len() as u64;
        let mut socket = FakeSocket {
            clock: clock.clone(),
            script: script.into(),
            peer: Peer::Unknown { connection: 0 },
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
        let shell_c = Peer::Process {
            pid: 4300,
            start: Some(2_000),
        };
        let mut a = vec![Outcome::Pong];
        a.extend(std::iter::repeat_n(miss(), 10));
        // Straight from Tripped to a new Shell's pong.
        let mut b = vec![Outcome::Pong];
        b.extend([miss(), miss(), miss(), miss(), miss()]);
        b.extend(pongs(2));
        // Through Absent to another new Shell.
        let mut c = vec![Outcome::Absent, Outcome::Pong];
        c.extend([miss(), miss(), miss(), miss()]);
        c.extend(pongs(2));
        let mut script = from(SHELL_A, a);
        script.extend(from(SHELL_B, b));
        script.extend(from(shell_c, c));
        let (recorder, _) = drive_peers(&Timing::default(), script);
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
        assert_eq!(recorder.armed_peers, [SHELL_A, SHELL_B, shell_c]);
    }

    /// A Shell long past its grace exits; the next one starts its own grace.
    #[test]
    fn a_new_shell_after_an_exit_gets_the_grace_again() {
        let mut script = from(SHELL_A, pongs(40));
        script.push((Outcome::Absent, SHELL_A));
        let mut b = vec![miss(), Outcome::Pong]; // listening, then answering
        b.extend([miss(), miss(), miss(), miss(), miss()]);
        b.extend(pongs(35));
        b.extend([miss(), miss(), miss()]);
        script.extend(from(SHELL_B, b));
        let (recorder, _) = drive_peers(&Timing::default(), script);
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

    fn reset() -> Outcome {
        Outcome::NoReply("connection reset".into())
    }

    /// Review P1: the old Shell is past its grace and crashes; Core relaunches
    /// it within one ping interval, so no Absent is ever observed. The write
    /// on the old connection fails, the reconnect reaches the new Shell, which
    /// answers and then stalls 6 s. The new peer is a new generation.
    #[test]
    fn a_fast_replacement_gets_the_grace() {
        for new_shell in [SHELL_B, SHELL_A_REUSED] {
            let mut script = from(SHELL_A, pongs(31));
            let mut b = vec![reset(), Outcome::Pong];
            b.extend([miss(), miss(), miss()]);
            b.extend(pongs(5));
            script.extend(from(new_shell, b));
            let (recorder, _) = drive_peers(&Timing::default(), script);
            assert!(recorder.trips.is_empty(), "{:?}", recorder.trips);
            assert_eq!(
                recorder.states,
                [State::Armed { misses: 0 }, State::Armed { misses: 0 }]
            );
            assert_eq!(recorder.armed_peers, [SHELL_A, new_shell]);
            assert_eq!(recorder.armed_phases, [Phase::Startup, Phase::Startup]);
        }
    }

    /// A new Shell that hangs right after replacing the old one still trips,
    /// at the startup threshold.
    #[test]
    fn a_fast_replacement_that_hangs_trips_at_the_startup_threshold() {
        let mut script = from(SHELL_A, pongs(31));
        let mut b = vec![reset(), Outcome::Pong];
        b.extend(std::iter::repeat_n(miss(), 12));
        script.extend(from(SHELL_B, b));
        let (recorder, _) = drive_peers(&Timing::default(), script);
        // The new Shell answers at 64 003 ms; misses at 67, 69, …, 85 s.
        assert_eq!(recorder.trips, [(85_000, 10)]);
        assert_eq!(recorder.trip_phases, [Phase::Startup]);
    }

    /// The same Shell reconnecting (every miss drops the connection) is not
    /// a new generation: past its grace, three misses trip it as before.
    #[test]
    fn the_same_shell_reconnecting_keeps_its_phase() {
        let mut script = pongs(31);
        script.extend([reset(), Outcome::Pong, miss(), miss(), miss()]);
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.trips, [(71_000, 3)]);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
        assert_eq!(recorder.armed_peers, [SHELL_A]);
    }

    /// A Shell that keeps stalling and answering in between cannot extend
    /// its own grace: it keeps its PID, so once its grace is over the steady
    /// rule trips it. Nine misses then a pong, over and over: tolerated
    /// during the grace, tripped at the third miss after it.
    #[test]
    fn a_stalling_shell_cannot_extend_its_grace() {
        let mut script = vec![Outcome::Pong];
        for _ in 0..4 {
            script.extend(std::iter::repeat_n(miss(), 9));
            script.push(Outcome::Pong);
        }
        let (recorder, _) = drive_default(script);
        assert_eq!(recorder.grace_ended, [(60_003, 0)]);
        assert_eq!(recorder.trips, [(67_000, 3)]);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
    }

    /// Without peer credentials a Shell that does not answer still trips,
    /// reconnects notwithstanding. (A reconnect that answers keeps the
    /// generation: `an_unidentified_reconnect_keeps_the_generation`.)
    #[test]
    fn an_unidentified_peer_neither_inherits_nor_escapes() {
        let unknown = |connection| Peer::Unknown { connection };

        // Hung from its first answer, reconnecting on every miss.
        let mut script = vec![(Outcome::Pong, unknown(1))];
        script.extend((2..16).map(|c| (miss(), unknown(c))));
        let (recorder, _) = drive_peers(&Timing::default(), script);
        assert_eq!(recorder.trips, [(21_000, 10)]);

        // Hung after its grace: the steady rule, reconnects notwithstanding.
        let mut script: Vec<_> = pongs(31).into_iter().map(|o| (o, unknown(1))).collect();
        script.extend((2..8).map(|c| (miss(), unknown(c))));
        let (recorder, _) = drive_peers(&Timing::default(), script);
        assert_eq!(recorder.trips, [(67_000, 3)]);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
    }

    /// Review round 2 P1: without peer credentials, the same Shell stalling
    /// nine pings and answering once, over and over, reconnects after every
    /// miss. A reconnect must not give it a new grace: the steady rule trips
    /// it once the grace from its first arming is over.
    #[test]
    fn an_unidentified_stalling_shell_trips_after_its_first_grace() {
        let unknown = |connection| Peer::Unknown { connection };
        let mut connection = 1;
        let mut script = vec![(Outcome::Pong, unknown(connection))];
        for _ in 0..6 {
            for _ in 0..9 {
                connection += 1;
                script.push((miss(), unknown(connection)));
            }
            connection += 1;
            script.push((Outcome::Pong, unknown(connection)));
        }
        let (recorder, _) = drive_peers(&Timing::default(), script);
        assert_eq!(recorder.grace_ended, [(60_003, 0)]);
        assert_eq!(recorder.trips[0], (67_000, 3));
        // The fake Shell survives each kill and answers again as the same
        // process: it resumes its generation (round 4), so every later stall
        // trips by the steady rule too.
        assert!(recorder.trip_phases.iter().all(|p| *p == Phase::Steady));
        assert!(recorder.trips.iter().all(|(_, misses)| *misses == 3));
    }

    /// Unidentified, a reconnect that reaches a new Shell cannot be told
    /// from the same Shell, so it keeps the generation: the rule of 6efa9b5,
    /// which errs toward rescue.
    #[test]
    fn an_unidentified_reconnect_keeps_the_generation() {
        let unknown = |connection| Peer::Unknown { connection };
        let mut script: Vec<_> = pongs(31).into_iter().map(|o| (o, unknown(1))).collect();
        script.push((reset(), unknown(2)));
        script.push((Outcome::Pong, unknown(3)));
        script.extend((4..7).map(|c| (miss(), unknown(c))));
        let (recorder, _) = drive_peers(&Timing::default(), script);
        assert_eq!(recorder.trips, [(71_000, 3)]);
        assert_eq!(recorder.trip_phases, [Phase::Steady]);
        assert_eq!(
            recorder.states,
            [State::Armed { misses: 0 }, State::Tripped]
        );
    }

    /// After an observed exit, an unidentified Shell cannot be told from the
    /// one before, so it resumes that generation (round 4; in round 2 it got
    /// a new grace): toward rescue.
    #[test]
    fn an_unidentified_shell_after_an_exit_resumes_the_generation() {
        let unknown = |connection| Peer::Unknown { connection };
        let mut script: Vec<_> = pongs(40).into_iter().map(|o| (o, unknown(1))).collect();
        script.push((Outcome::Absent, unknown(1)));
        script.push((Outcome::Pong, unknown(2)));
        script.extend((3..8).map(|c| (miss(), unknown(c))));
        script.extend(std::iter::repeat_n((Outcome::Pong, unknown(8)), 5));
        let (recorder, _) = drive_peers(&Timing::default(), script);
        assert_eq!(recorder.trips, [(89_000, 3)]);
        // Armed, resumed after the exit, resumed again after the trip.
        assert_eq!(
            recorder.armed_phases,
            [Phase::Startup, Phase::Steady, Phase::Steady]
        );
    }

    #[test]
    fn the_monitor_on_its_own() {
        let mut monitor = Monitor::new(3);
        assert_eq!(monitor.observe(&miss(), SHELL_A, 0), Action::None);
        assert_eq!(monitor.state, State::Unarmed);
        monitor.observe(&Outcome::Pong, SHELL_A, 0);
        monitor.observe(&miss(), SHELL_A, 0);
        monitor.observe(&miss(), SHELL_A, 0);
        assert_eq!(monitor.state, State::Armed { misses: 2 });
        assert_eq!(
            monitor.observe(&miss(), SHELL_A, 0),
            Action::Trip { misses: 3 }
        );
        assert_eq!(
            monitor.observe(&miss(), SHELL_A, 0),
            Action::None,
            "a tripped Shell is not killed twice"
        );
        assert_eq!(Monitor::new(0).threshold, 1);
    }

    #[test]
    fn generations_follow_the_peer() {
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::from_secs(60), 10);
        monitor.observe(&Outcome::Pong, SHELL_A, 0);
        assert_eq!((monitor.generation, monitor.peer), (1, Some(SHELL_A)));
        monitor.observe(&Outcome::Pong, SHELL_A, 70_000);
        assert_eq!(monitor.phase, Phase::Steady);
        // Armed, the same process answering again keeps its generation.
        monitor.observe(&miss(), SHELL_A, 70_500);
        monitor.observe(&Outcome::Pong, SHELL_A, 70_600);
        assert_eq!((monitor.generation, monitor.phase), (1, Phase::Steady));
        // After a trip whose kill did not take, the same process answering
        // resumes its generation, steady (round 4; a Shell that hangs again
        // trips again after three misses).
        for _ in 0..3 {
            monitor.observe(&miss(), SHELL_A, 71_000);
        }
        assert_eq!(monitor.state, State::Tripped);
        monitor.observe(&Outcome::Pong, SHELL_A, 72_000);
        assert_eq!((monitor.generation, monitor.phase), (1, Phase::Steady));
        // A different identified Shell, while armed: new generation, new grace.
        monitor.observe(&Outcome::Pong, SHELL_B, 130_000);
        assert_eq!(monitor.phase, Phase::Startup);
        assert_eq!(monitor.generation, 2);
        monitor.observe(&Outcome::Pong, SHELL_A_REUSED, 131_000);
        assert_eq!(monitor.generation, 3, "a reused PID is another Shell");
        // An unknown peer while armed is not a new generation and does not
        // replace the known one.
        monitor.observe(&Outcome::Pong, Peer::Unknown { connection: 9 }, 200_000);
        assert_eq!(
            (monitor.generation, monitor.peer, monitor.phase),
            (3, Some(SHELL_A_REUSED), Phase::Steady)
        );
        // A generation armed while unidentified records its process when it
        // becomes known, without a new grace; a different process after that
        // is a replacement.
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::from_secs(60), 10);
        monitor.observe(&Outcome::Pong, Peer::Unknown { connection: 1 }, 0);
        assert_eq!((monitor.generation, monitor.peer), (1, None));
        monitor.observe(&Outcome::Pong, SHELL_A, 70_000);
        assert_eq!(
            (monitor.generation, monitor.peer, monitor.phase),
            (1, Some(SHELL_A), Phase::Steady)
        );
        monitor.observe(&Outcome::Pong, SHELL_B, 71_000);
        assert_eq!((monitor.generation, monitor.phase), (2, Phase::Startup));
    }

    #[test]
    fn the_grace_boundary_on_the_monitor_clock() {
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::from_millis(1_000), 10);
        monitor.observe(&Outcome::Pong, SHELL_A, 5_000);
        assert_eq!(monitor.phase, Phase::Startup);
        for _ in 0..9 {
            assert_eq!(monitor.observe(&miss(), SHELL_A, 5_999), Action::None);
        }
        assert_eq!(monitor.phase, Phase::Startup);
        assert_eq!(
            monitor.observe(&Outcome::Pong, SHELL_A, 5_999),
            Action::None
        );
        monitor.observe(&miss(), SHELL_A, 6_000);
        assert_eq!(
            monitor.phase,
            Phase::Steady,
            "the grace is [armed, armed + grace)"
        );
        monitor.observe(&miss(), SHELL_A, 6_000);
        assert_eq!(
            monitor.observe(&miss(), SHELL_A, 6_000),
            Action::Trip { misses: 3 }
        );

        // Ten misses inside the grace trip at ten, not never.
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::from_secs(60), 10);
        monitor.observe(&Outcome::Pong, SHELL_A, 0);
        for at in 1..10 {
            assert_eq!(monitor.observe(&miss(), SHELL_A, at), Action::None);
        }
        assert_eq!(
            monitor.observe(&miss(), SHELL_A, 10),
            Action::Trip { misses: 10 }
        );

        // A grace is never stricter than the steady rule; zero means none.
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::from_secs(60), 1);
        monitor.observe(&Outcome::Pong, SHELL_A, 0);
        assert_eq!(monitor.observe(&miss(), SHELL_A, 1), Action::None);
        assert_eq!(monitor.observe(&miss(), SHELL_A, 2), Action::None);
        assert_eq!(
            monitor.observe(&miss(), SHELL_A, 3),
            Action::Trip { misses: 3 }
        );
        let mut monitor = Monitor::new(3).with_startup_grace(Duration::ZERO, 10);
        monitor.observe(&Outcome::Pong, SHELL_A, 0);
        assert_eq!(monitor.phase, Phase::Steady);
    }

    #[test]
    fn the_identity_rule() {
        let process = |pid, start| Peer::Process { pid, start };
        let unknown = Peer::Unknown { connection: 1 };
        let cases = [
            (process(1, Some(10)), process(1, Some(10)), false),
            (process(1, Some(10)), process(1, None), false),
            (process(1, None), process(1, Some(10)), false),
            (process(1, None), process(1, None), false),
            (process(1, Some(10)), process(1, Some(11)), true),
            (process(1, Some(10)), process(2, Some(10)), true),
            (process(1, None), process(2, None), true),
            (process(1, Some(10)), unknown, false),
            (unknown, process(1, Some(10)), false),
            (unknown, Peer::Unknown { connection: 2 }, false),
        ];
        for (a, b, different) in cases {
            assert_eq!(a.provably_differs_from(b), different, "{a:?} vs {b:?}");
            assert_eq!(b.provably_differs_from(a), different, "symmetric");
        }
        // Learning: a start time for the armed PID is kept, never forgotten.
        assert_eq!(
            Peer::learn(Some(process(1, None)), process(1, Some(10))),
            Some(process(1, Some(10)))
        );
        assert_eq!(
            Peer::learn(Some(process(1, Some(10))), process(1, None)),
            Some(process(1, Some(10)))
        );
        assert_eq!(
            Peer::learn(Some(process(1, Some(10))), unknown),
            Some(process(1, Some(10)))
        );
        assert_eq!(Peer::learn(None, unknown), None);
        assert_eq!(Peer::learn(None, process(1, None)), Some(process(1, None)));
    }

    // Exhaustive no-escape evidence (review round 3). One real Shell: pid
    // `P`, start time `T`. Every way the pinger can see it is enumerated
    // against every stall pattern, and the monitor must behave exactly as if
    // the Shell had been identified perfectly every time.

    const P: u32 = 4100;
    const T: u64 = 900;

    /// How one observation of that single Shell can look to the pinger.
    #[derive(Clone, Copy, Debug)]
    enum Seen {
        /// `SO_PEERCRED` and `/proc/<pid>/stat` both read.
        WithStart,
        /// `SO_PEERCRED` read, the start time not.
        WithoutStart,
        /// Peer unreadable, on the connection already open.
        UnknownSame,
        /// Peer unreadable, on a new connection.
        UnknownNew,
    }

    const SEEN: [Seen; 4] = [
        Seen::WithStart,
        Seen::WithoutStart,
        Seen::UnknownSame,
        Seen::UnknownNew,
    ];

    struct Observer {
        connection: u64,
    }

    impl Observer {
        fn peer(&mut self, seen: Seen) -> Peer {
            match seen {
                Seen::WithStart => Peer::Process {
                    pid: P,
                    start: Some(T),
                },
                Seen::WithoutStart => Peer::Process {
                    pid: P,
                    start: None,
                },
                Seen::UnknownSame => Peer::Unknown {
                    connection: self.connection,
                },
                Seen::UnknownNew => {
                    self.connection += 1;
                    Peer::Unknown {
                        connection: self.connection,
                    }
                }
            }
        }
    }

    /// The default timing on the monitor clock: a ping starts every 2 s, a
    /// pong is observed 3 ms later, a miss 1 s later. `stall: Some(k)` is k
    /// misses then one pong, over and over; `None` is hung after the first
    /// pong. Pong `j` is seen as `seen[j % len]`. Returns the first trip's
    /// time, if any before `until`.
    fn first_trip(seen: &[Seen], stall: Option<u32>, until: u64) -> Option<u64> {
        let mut monitor = Monitor::from_timing(&Timing::default());
        let mut observer = Observer { connection: 1 };
        let missed = miss();
        let (mut pongs, mut since_pong) = (0usize, 0u32);
        for n in 0.. {
            let start: u64 = n * 2_000;
            if start > until {
                return None;
            }
            let seen = seen[pongs % seen.len()];
            if n == 0 || stall == Some(since_pong) {
                let peer = observer.peer(seen);
                pongs += 1;
                since_pong = 0;
                monitor.observe(&Outcome::Pong, peer, start + 3);
            } else {
                // Every miss drops the connection; the next ping reconnects.
                observer.connection += 1;
                since_pong += 1;
                let peer = observer.peer(seen);
                if let Action::Trip { .. } = monitor.observe(&missed, peer, start + 1_000) {
                    return Some(start + 1_000);
                }
            }
        }
        unreachable!()
    }

    /// First arming at 3 ms, the 60 s grace, then the steady bound: three
    /// misses at 2 s intervals and the last one's 1 s deadline.
    const NO_ESCAPE_BOUND: u64 = 3 + 60_000 + 3 * 2_000 + 1_000;

    #[test]
    fn no_observation_sequence_lets_one_shell_escape() {
        let until = NO_ESCAPE_BOUND + 4_000;
        let stalls: Vec<Option<u32>> = (1..=9).map(Some).chain([None]).collect();
        // The truth, with the Shell identified perfectly every time.
        let truth: Vec<Option<u64>> = stalls
            .iter()
            .map(|&stall| first_trip(&[Seen::WithStart], stall, until))
            .collect();
        for (stall, trip) in stalls.iter().zip(&truth) {
            match stall {
                // Answering at least every 6 s: the steady rule never trips
                // such a Shell either.
                Some(k) if *k < 3 => assert_eq!(*trip, None, "k={k}"),
                _ => assert!(
                    trip.is_some_and(|at| at <= NO_ESCAPE_BOUND),
                    "{stall:?} {trip:?}"
                ),
            }
        }
        let mut seen = [Seen::WithStart; 8];
        let mut runs = 0;
        for code in 0..4usize.pow(8) {
            for (i, slot) in seen.iter_mut().enumerate() {
                *slot = SEEN[code / 4usize.pow(i as u32) % 4];
            }
            for (&stall, &expected) in stalls.iter().zip(&truth) {
                assert_eq!(
                    first_trip(&seen, stall, until),
                    expected,
                    "seen {seen:?}, stall {stall:?}"
                );
                runs += 1;
            }
        }
        assert_eq!(runs, 655_360);
    }

    /// The inverse: a provably different Shell replacing an armed one past
    /// its grace (the fast replacement, no Absent seen) gets a new grace and
    /// survives a 6 s startup stall; one that cannot be told apart keeps the
    /// generation and trips by the steady rule (toward rescue). The armed
    /// Shell is seen through every sequence of 4 over {with start, without
    /// start, unknown}, applied cyclically to its 31 pongs.
    #[test]
    fn a_provably_different_shell_still_gets_the_grace() {
        let kinds = [Seen::WithStart, Seen::WithoutStart, Seen::UnknownNew];
        let other_pid = |start| Peer::Process { pid: 4200, start };
        let replacements = [
            (other_pid(Some(1_300)), "other pid, start known"),
            (other_pid(None), "other pid, start unknown"),
            (
                Peer::Process {
                    pid: P,
                    start: Some(5_000),
                },
                "pid reused, other start",
            ),
            (
                Peer::Process {
                    pid: P,
                    start: None,
                },
                "pid reused, start unknown",
            ),
            (Peer::Unknown { connection: 999 }, "unidentified"),
        ];
        let mut checked = 0;
        for code in 0..3usize.pow(4) {
            let armed: Vec<Seen> = (0..4).map(|i| kinds[code / 3usize.pow(i) % 3]).collect();
            let pid_known = armed.iter().any(|s| !matches!(s, Seen::UnknownNew));
            let start_known = armed.iter().any(|s| matches!(s, Seen::WithStart));
            for (replacement, label) in replacements {
                let provable = match replacement {
                    Peer::Process { pid, .. } if pid != P => pid_known,
                    Peer::Process { start: Some(_), .. } => start_known,
                    _ => false,
                };
                let mut monitor = Monitor::from_timing(&Timing::default());
                let mut observer = Observer { connection: 1 };
                for n in 0..31u64 {
                    let peer = observer.peer(armed[n as usize % 4]);
                    monitor.observe(&Outcome::Pong, peer, n * 2_000 + 3);
                }
                monitor.observe(&reset(), replacement, 63_000);
                monitor.observe(&Outcome::Pong, replacement, 64_003);
                // Read now: after a trip, the next pong is a new generation
                // whoever answers (the 6efa9b5 rule).
                let generation = monitor.generation;
                let mut trips = vec![];
                for (n, outcome) in [miss(), miss(), miss(), Outcome::Pong].iter().enumerate() {
                    let at = 66_000 + 2_000 * n as u64 + 1_000;
                    if monitor.observe(outcome, replacement, at) != Action::None {
                        trips.push(at);
                    }
                }
                let context = format!("armed seen {armed:?}, replacement {label}");
                if provable {
                    assert_eq!(generation, 2, "{context}");
                    assert!(trips.is_empty(), "{context}: {trips:?}");
                } else {
                    assert_eq!(generation, 1, "{context}");
                    assert_eq!(trips, [71_000], "{context}");
                }
                checked += 1;
            }
        }
        assert_eq!(checked, 405);
    }

    // Review round 4 (P1, P2): `Absent` injected into the life of one Shell.
    // With the fixed pinger a live Shell holding its listening socket cannot
    // be observed as Absent (see the socket tests in `shell.rs`); these tests
    // inject it anyway, and Absent→NoReply (Unarmed), and show that the same
    // process still cannot gain a new grace.

    /// Like `first_trip`, but at ping `at` the outcomes `disruption` replace
    /// the stall pattern, then one pong (the resumed pong) follows and the
    /// pattern goes on from there. Returns the first trip and when the
    /// resumed pong was observed.
    fn first_trip_disrupted(
        seen: &[Seen],
        stall: Option<u32>,
        at: u64,
        disruption: &[Outcome],
        until: u64,
    ) -> (Option<u64>, u64) {
        let mut monitor = Monitor::from_timing(&Timing::default());
        let mut observer = Observer { connection: 1 };
        let missed = miss();
        let resumed_ping = at + disruption.len() as u64;
        let resumed = resumed_ping * 2_000 + 3;
        let (mut pongs, mut since_pong) = (0usize, 0u32);
        for n in 0.. {
            let start: u64 = n * 2_000;
            if start > until {
                return (None, resumed);
            }
            let seen = seen[pongs % seen.len()];
            let outcome = if n >= at && n < resumed_ping {
                &disruption[(n - at) as usize]
            } else if n == 0 || n == resumed_ping || (n > at && stall == Some(since_pong)) {
                &Outcome::Pong
            } else if n < at && stall == Some(since_pong) {
                &Outcome::Pong
            } else {
                &missed
            };
            match outcome {
                Outcome::Pong => {
                    let peer = observer.peer(seen);
                    pongs += 1;
                    since_pong = 0;
                    monitor.observe(outcome, peer, start + 3);
                }
                Outcome::NoReply(_) => {
                    observer.connection += 1;
                    if n < at || n > resumed_ping {
                        since_pong += 1;
                    }
                    let peer = observer.peer(seen);
                    if let Action::Trip { .. } = monitor.observe(outcome, peer, start + 1_000) {
                        return (Some(start + 1_000), resumed);
                    }
                }
                Outcome::Absent => {
                    observer.connection += 1;
                    let peer = observer.peer(seen);
                    monitor.observe(outcome, peer, start + 3);
                }
            }
        }
        unreachable!()
    }

    #[test]
    fn an_injected_absent_earns_one_shell_no_new_grace() {
        let kinds = [Seen::WithStart, Seen::WithoutStart, Seen::UnknownNew];
        let disruptions = [
            vec![Outcome::Absent],
            vec![Outcome::Absent, miss()],
            vec![Outcome::Absent, miss(), miss(), miss()],
            vec![miss(), Outcome::Absent, miss()],
            vec![Outcome::Absent, Outcome::Absent],
        ];
        // Inside the grace, across its end, and well after it.
        let positions = [5, 29, 40];
        let stalls: Vec<Option<u32>> = (1..=9).map(Some).chain([None]).collect();
        let until = 100_000;
        let mut runs = 0;
        for disruption in &disruptions {
            for at in positions {
                for &stall in &stalls {
                    let (truth, resumed) =
                        first_trip_disrupted(&[Seen::WithStart], stall, at, disruption, until);
                    // No new grace at the resumed pong: a stall of three or
                    // more trips by the first grace's bound or by the steady
                    // bound after the resumed pong, whichever is later.
                    if !matches!(stall, Some(k) if k < 3) {
                        let bound = NO_ESCAPE_BOUND.max(resumed + 3 * 2_000 + 1_000);
                        assert!(
                            truth.is_some_and(|trip| trip <= bound),
                            "{disruption:?} at {at}, stall {stall:?}: {truth:?} > {bound}"
                        );
                    }
                    let mut seen = [Seen::WithStart; 8];
                    for code in 0..3usize.pow(8) {
                        for (i, slot) in seen.iter_mut().enumerate() {
                            *slot = kinds[code / 3usize.pow(i as u32) % 3];
                        }
                        assert_eq!(
                            first_trip_disrupted(&seen, stall, at, disruption, until).0,
                            truth,
                            "seen {seen:?}, {disruption:?} at {at}, stall {stall:?}"
                        );
                        runs += 1;
                    }
                }
            }
        }
        assert_eq!(runs, 6_561 * 5 * 3 * 10);
    }

    /// The inverse after an exit: an armed Shell past its grace, then Absent
    /// (or Absent, then a listener that does not answer yet), then a pong.
    /// Exactly the provably different Shells get a new grace; the rest
    /// resume the old generation and trip by the steady rule.
    #[test]
    fn after_an_absent_only_a_provably_different_shell_gets_a_grace() {
        let kinds = [Seen::WithStart, Seen::WithoutStart, Seen::UnknownNew];
        let other_pid = |start| Peer::Process { pid: 4200, start };
        let replacements = [
            other_pid(Some(1_300)),
            other_pid(None),
            Peer::Process {
                pid: P,
                start: Some(5_000),
            },
            Peer::Process {
                pid: P,
                start: None,
            },
            Peer::Unknown { connection: 999 },
        ];
        let gaps = [vec![Outcome::Absent], vec![Outcome::Absent, miss()]];
        let mut checked = 0;
        for code in 0..3usize.pow(4) {
            let armed: Vec<Seen> = (0..4).map(|i| kinds[code / 3usize.pow(i) % 3]).collect();
            let pid_known = armed.iter().any(|s| !matches!(s, Seen::UnknownNew));
            let start_known = armed.iter().any(|s| matches!(s, Seen::WithStart));
            for replacement in replacements {
                let provable = match replacement {
                    Peer::Process { pid, .. } if pid != P => pid_known,
                    Peer::Process { start: Some(_), .. } => start_known,
                    _ => false,
                };
                for gap in &gaps {
                    let mut monitor = Monitor::from_timing(&Timing::default());
                    let mut observer = Observer { connection: 1 };
                    for n in 0..31u64 {
                        let peer = observer.peer(armed[n as usize % 4]);
                        monitor.observe(&Outcome::Pong, peer, n * 2_000 + 3);
                    }
                    let mut n = 31u64;
                    for outcome in gap {
                        monitor.observe(outcome, replacement, n * 2_000 + 1_000);
                        n += 1;
                    }
                    monitor.observe(&Outcome::Pong, replacement, n * 2_000 + 3);
                    let generation = monitor.generation;
                    let mut trips = vec![];
                    for outcome in [miss(), miss(), miss()] {
                        n += 1;
                        let at = n * 2_000 + 1_000;
                        if monitor.observe(&outcome, replacement, at) != Action::None {
                            trips.push(at);
                        }
                    }
                    let context = format!("armed {armed:?}, {replacement:?}, gap {gap:?}");
                    if provable {
                        assert_eq!(generation, 2, "{context}");
                        assert!(trips.is_empty(), "{context}: {trips:?}");
                    } else {
                        assert_eq!(generation, 1, "{context}");
                        assert_eq!(trips, [n * 2_000 + 1_000], "{context}");
                    }
                    checked += 1;
                }
            }
        }
        assert_eq!(checked, 81 * 5 * 2);
    }
}
