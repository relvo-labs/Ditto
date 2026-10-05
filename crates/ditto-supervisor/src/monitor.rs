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

pub struct Monitor {
    pub state: State,
    threshold: u32,
}

impl Monitor {
    pub fn new(threshold: u32) -> Self {
        Self {
            state: State::Absent,
            threshold: threshold.max(1),
        }
    }

    pub fn observe(&mut self, outcome: &Outcome) -> Action {
        let (next, action) = match (self.state, outcome) {
            (_, Outcome::Pong) => (State::Armed { misses: 0 }, Action::None),
            (_, Outcome::Absent) => (State::Absent, Action::None),
            (State::Absent | State::Unarmed, Outcome::NoReply(_)) => (State::Unarmed, Action::None),
            (State::Tripped, Outcome::NoReply(_)) => (State::Tripped, Action::None),
            (State::Armed { misses }, Outcome::NoReply(_)) => {
                let misses = misses + 1;
                if misses >= self.threshold {
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
    /// SIGKILL the Shell and start the rescue UI.
    fn trip(&mut self, misses: u32, last: &Outcome);
    fn transition(&mut self, from: State, to: State, outcome: &Outcome);
}

pub struct Timing {
    pub interval: Duration,
    pub timeout: Duration,
    pub misses: u32,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            interval: Duration::from_secs(2),
            timeout: Duration::from_secs(1),
            misses: 3,
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
    let mut monitor = Monitor::new(timing.misses);
    let mut sequence = 0u64;
    loop {
        if rounds.is_some_and(|rounds| sequence >= rounds) {
            return;
        }
        sequence += 1;
        let started = clock.now_ms();
        let outcome = pinger.ping(sequence, timing.timeout);
        let before = monitor.state;
        let action = monitor.observe(&outcome);
        if std::mem::discriminant(&before) != std::mem::discriminant(&monitor.state) {
            effects.transition(before, monitor.state, &outcome);
        }
        if let Action::Trip { misses } = action {
            effects.trip(misses, &outcome);
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
        states: Vec<State>,
    }

    impl Effects for Recorder {
        fn trip(&mut self, misses: u32, _: &Outcome) {
            self.trips.push((self.clock.now_ms(), misses));
        }
        fn transition(&mut self, _: State, to: State, _: &Outcome) {
            self.states.push(to);
        }
    }

    fn miss() -> Outcome {
        Outcome::NoReply("timeout".into())
    }

    fn drive(script: Vec<Outcome>) -> (Recorder, Vec<u64>) {
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
        run(
            &clock,
            &mut socket,
            &mut recorder,
            &Timing::default(),
            Some(rounds),
        );
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

    #[test]
    fn the_monitor_on_its_own() {
        let mut monitor = Monitor::new(3);
        assert_eq!(monitor.observe(&miss()), Action::None);
        assert_eq!(monitor.state, State::Unarmed);
        monitor.observe(&Outcome::Pong);
        monitor.observe(&miss());
        monitor.observe(&miss());
        assert_eq!(monitor.state, State::Armed { misses: 2 });
        assert_eq!(monitor.observe(&miss()), Action::Trip { misses: 3 });
        assert_eq!(
            monitor.observe(&miss()),
            Action::None,
            "a tripped Shell is not killed twice"
        );
        assert_eq!(Monitor::new(0).threshold, 1);
    }
}
