//! Development query only: no confined child or status socket is needed.
#[test]
fn landlock_abi_query_is_read_only_and_machine_readable() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_ditto-confine"))
        .arg("--landlock-abi")
        .output()
        .expect("run probe");
    assert!(output.status.success(), "{:?}", output);
    assert!(output.stderr.is_empty());
    let abi = String::from_utf8(output.stdout).unwrap();
    assert!(abi.trim().parse::<i64>().is_ok(), "{abi}");
}

#[test]
fn landlock_query_cannot_be_combined_with_a_program() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_ditto-confine"))
        .args(["--landlock-abi", "--", "/usr/bin/true"])
        .output()
        .expect("run invalid probe");
    assert_eq!(output.status.code(), Some(64));
    assert!(output.stdout.is_empty());
}
