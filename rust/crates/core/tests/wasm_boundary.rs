use cht_core::core_version;

#[test]
fn core_version_is_stable_and_reveals_no_environment_details() {
    let version = core_version();

    assert_eq!(version, "cht-core@0.1.0");
    assert!(!version.contains('\\'));
    assert!(!version.contains('/'));
}
