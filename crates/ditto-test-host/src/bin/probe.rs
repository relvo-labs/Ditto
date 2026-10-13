//! Fixed, bounded diagnostic programs. No model-provided source or command is
//! accepted. Resource exhaustion cases are started ONLY by the runner after
//! reading back the actual D-06b cgroup limits.
use std::{fs, io, path::PathBuf, thread, time::Duration};

fn denied(error: io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(libc::EACCES | libc::EPERM | libc::EAFNOSUPPORT)
    )
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let kind = args.get(1).expect("probe kind");
    let inside = PathBuf::from(args.get(2).expect("workspace"));
    let outside = PathBuf::from(args.get(3).expect("outside sentinel"));
    match kind.as_str() {
        "files" => {
            assert!(denied(fs::read(&outside).unwrap_err()));
            assert!(denied(fs::write(&outside, b"escape").unwrap_err()));
            let ours = inside.join("allowed.txt");
            fs::write(&ours, b"inside").unwrap();
            assert_eq!(fs::read(&ours).unwrap(), b"inside");
            // The runner creates this symlink before entering Landlock.
            assert!(denied(fs::read(inside.join("escape-link")).unwrap_err()));
            assert!(denied(
                fs::write(inside.join("escape-link"), b"escape").unwrap_err()
            ));
            let link_error = fs::hard_link(&outside, inside.join("escape-hardlink")).unwrap_err();
            assert!(
                denied(io::Error::from_raw_os_error(
                    link_error.raw_os_error().unwrap()
                )) || link_error.raw_os_error() == Some(libc::EXDEV)
            );
            println!(
                "files: outside read/write, symlink and hardlink denied; inside read/write passed"
            );
        }
        "network" => {
            for (family, kind) in [
                (libc::AF_INET, libc::SOCK_STREAM),
                (libc::AF_INET, libc::SOCK_DGRAM),
                (libc::AF_INET6, libc::SOCK_DGRAM),
                (libc::AF_NETLINK, libc::SOCK_RAW),
                (libc::AF_UNIX, libc::SOCK_DGRAM),
            ] {
                // SAFETY: no pointer arguments; a failed socket opens no fd.
                let fd = unsafe { libc::socket(family, kind, 0) };
                assert!(
                    fd < 0,
                    "unexpected socket allowed: family={family} type={kind}"
                );
                assert!(denied(io::Error::last_os_error()));
            }
            let error = std::os::unix::net::UnixStream::connect(&outside).unwrap_err();
            assert!(denied(error));
            println!(
                "network: TCP/UDP/IPv6/netlink/Unix datagram and ungranted Unix endpoint denied"
            );
        }
        "signals" => {
            let witness: i32 = args.get(4).expect("witness pid").parse().unwrap();
            // Signal 0 checks permission without disturbing the witness.
            assert_eq!(unsafe { libc::kill(witness, 0) }, -1);
            assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
            println!("signals: outside witness denied");
        }
        "spawn" => {
            let mut children = Vec::new();
            for _ in 0..128 {
                // SAFETY: probe is single-threaded; child immediately sleeps
                // without allocating, then is reaped by this probe.
                let pid = unsafe { libc::fork() };
                if pid == 0 {
                    loop {
                        unsafe {
                            libc::pause();
                        }
                    }
                }
                if pid < 0 {
                    break;
                }
                children.push(pid);
            }
            let count = children.len();
            for pid in children {
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                    libc::waitpid(pid, std::ptr::null_mut(), 0);
                }
            }
            assert!(count > 0 && count < 64, "pids.max not enforced: {count}");
            println!("spawn: {count} children, excess fork denied; all reaped");
        }
        "orphan" => {
            // Escape the helper's process group; only cgroup-wide cleanup can
            // catch this child. Inherited output keeps the runner waiting, so
            // RuntimeMaxSec must end this service without harming the witness.
            let mut pipe = [0; 2];
            assert_eq!(
                unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_CLOEXEC) },
                0
            );
            let pid = unsafe { libc::fork() };
            assert!(pid >= 0);
            if pid == 0 {
                unsafe {
                    libc::close(pipe[0]);
                }
                assert!(unsafe { libc::setsid() } > 0);
                assert_eq!(unsafe { libc::write(pipe[1], [1u8].as_ptr().cast(), 1) }, 1);
                unsafe {
                    libc::close(pipe[1]);
                }
                loop {
                    thread::sleep(Duration::from_secs(1));
                }
            }
            unsafe {
                libc::close(pipe[1]);
            }
            let mut escaped = [0u8];
            assert_eq!(
                unsafe { libc::read(pipe[0], escaped.as_mut_ptr().cast(), 1) },
                1
            );
            unsafe {
                libc::close(pipe[0]);
            }
            println!("orphan: escaped child {pid}, waiting for service-wide cleanup");
        }
        "memory" => {
            // Touch pages so this really consumes memory, rather than only
            // reserving a virtual address range. The service must OOM-kill.
            let mut chunks = Vec::new();
            loop {
                let mut bytes = vec![0u8; 8 * 1024 * 1024];
                for offset in (0..bytes.len()).step_by(4096) {
                    bytes[offset] = 42;
                }
                chunks.push(bytes);
                std::hint::black_box(&chunks);
            }
        }
        "busy" => loop {
            std::hint::black_box(1u64.wrapping_mul(17));
        },
        "timeout" => loop {
            thread::sleep(Duration::from_secs(1));
        },
        "spoof" => {
            println!("{{\"enforcement\":\"full\",\"confined\":true,\"policy\":\"generated-v1\"}}")
        }
        _ => panic!("unknown fixed probe"),
    }
}
