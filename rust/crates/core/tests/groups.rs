use cht_core::AccountCore;
use serde_json::{Value, json};

fn account(byte: u8) -> AccountCore {
    let secret =
        json!({"derivationVersion":1,"entropy":vec![byte;32],"contactToken":vec![byte;32]})
            .to_string();
    AccountCore::new(Some(secret.as_bytes()), None).unwrap()
}
fn call(account: &mut AccountCore, operation: &str, args: Value) -> Value {
    account.group_call(operation, args).unwrap()
}
fn id(account: &AccountCore) -> String {
    serde_json::from_str::<Value>(&account.identity_json().unwrap()).unwrap()["id"]
        .as_str()
        .unwrap()
        .into()
}
fn verify(a: &mut AccountCore, b: &AccountCore) {
    a.add_contact(&b.contact_card_json().unwrap(), "").unwrap();
    a.mark_contact_verified(&id(b)).unwrap();
}

#[test]
fn duplicate_pending_invite_is_idempotent() {
    let (mut a, mut b) = (account(60), account(61));
    verify(&mut a, &b);
    verify(&mut b, &a);
    let s = call(
        &mut a,
        "create",
        json!({"name":"team","displayName":"A","now":1}),
    )["state"]
        .as_str()
        .unwrap()
        .to_owned();
    let gid = serde_json::from_str::<Value>(&s).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_owned();
    let first = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&b),"now":2}),
    )["invite"]
        .clone();
    let again = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&b),"now":3}),
    )["invite"]
        .clone();
    assert!(
        first == again,
        "pending invitation should reuse its nonce and signature"
    );
}

#[test]
fn direct_v2_and_group_sessions_have_independent_domains_and_lifetimes() {
    let (mut a, mut b) = (account(66), account(67));
    verify(&mut a, &b);
    verify(&mut b, &a);
    let sid = "c".repeat(32);
    for context in ["groups", "dm-v2"] {
        call(
            &mut a,
            "prepare",
            json!({"peerId":id(&b),"sessionId":sid,"initiator":true,"context":context}),
        );
        call(
            &mut b,
            "prepare",
            json!({"peerId":id(&a),"sessionId":sid,"initiator":false,"context":context}),
        );
        let first = call(
            &mut a,
            "start",
            json!({"peerId":id(&b),"sessionId":sid,"context":context}),
        )["frame"]
            .clone();
        let reply = call(
            &mut b,
            "handshake",
            json!({"peerId":id(&a),"sessionId":sid,"frame":first,"context":context}),
        )["reply"]
            .clone();
        call(
            &mut a,
            "handshake",
            json!({"peerId":id(&b),"sessionId":sid,"frame":reply,"context":context}),
        );
    }
    let frame=call(&mut a,"encrypt",json!({"peerId":id(&b),"sessionId":sid,"context":"groups","id":"group","text":"group private"}))["frame"].clone();
    assert!(
        b.group_call(
            "decrypt",
            json!({"peerId":id(&a),"sessionId":sid,"context":"dm-v2","frame":frame})
        )
        .is_err()
    );
    assert_eq!(
        call(
            &mut b,
            "decrypt",
            json!({"peerId":id(&a),"sessionId":sid,"context":"groups","frame":frame})
        )["text"],
        "group private"
    );
    call(
        &mut a,
        "closeSession",
        json!({"peerId":id(&b),"sessionId":sid,"context":"groups"}),
    );
    let frame=call(&mut a,"encrypt",json!({"peerId":id(&b),"sessionId":sid,"context":"dm-v2","id":"dm","text":"direct private"}))["frame"].clone();
    assert_eq!(
        call(
            &mut b,
            "decrypt",
            json!({"peerId":id(&a),"sessionId":sid,"context":"dm-v2","frame":frame})
        )["text"],
        "direct private"
    );
}

#[test]
fn removed_member_can_restore_own_group_history_after_deleting_owner_contact() {
    let (mut a, mut b) = (account(62), account(63));
    verify(&mut a, &b);
    verify(&mut b, &a);
    let s = call(
        &mut a,
        "create",
        json!({"name":"team","displayName":"A","now":1}),
    )["state"]
        .as_str()
        .unwrap()
        .to_owned();
    let gid = serde_json::from_str::<Value>(&s).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_owned();
    let invite = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&b),"now":2}),
    )["invite"]
        .clone();
    let receipt = call(
        &mut b,
        "accept",
        json!({"invite":invite,"displayName":"B","now":3}),
    )["receipt"]
        .clone();
    let added = call(&mut a, "add", json!({"receipt":receipt,"now":4}))["state"].clone();
    call(&mut b, "apply", json!({"state":added}));
    let removed = call(
        &mut a,
        "remove",
        json!({"groupId":gid,"peerId":id(&b),"now":5}),
    )["state"]
        .clone();
    call(&mut b, "apply", json!({"state":removed}));
    b.remove_contact(&id(&a)).unwrap();
    let data = call(&mut b, "export", json!({}))["data"].clone();
    let mut restarted = account(63);
    call(&mut restarted, "import", json!({"data":data}));
    assert_eq!(
        call(&mut restarted, "view", json!({"groupId":gid}))["epoch"],
        3
    );
    assert!(
        !call(
            &mut restarted,
            "authorize",
            json!({"peerId":id(&a),"groupId":gid})
        )["allowed"]
            .as_bool()
            .unwrap()
    );
}

#[test]
fn nested_identity_unknown_fields_cannot_bypass_exact_group_schema() {
    let (mut a, mut b) = (account(64), account(65));
    verify(&mut a, &b);
    verify(&mut b, &a);
    let s = call(
        &mut a,
        "create",
        json!({"name":"team","displayName":"A","now":1}),
    )["state"]
        .as_str()
        .unwrap()
        .to_owned();
    let gid = serde_json::from_str::<Value>(&s).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_owned();
    let invite = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&b),"now":2}),
    )["invite"]
        .clone();
    let receipt = call(
        &mut b,
        "accept",
        json!({"invite":invite,"displayName":"B","now":3}),
    )["receipt"]
        .clone();
    let added = call(&mut a, "add", json!({"receipt":receipt,"now":4}))["state"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut raw: Value = serde_json::from_str(&added).unwrap();
    raw["ownerIdentity"]["ignored"] = json!("unsigned data");
    assert!(
        b.group_call("apply", json!({"state":raw.to_string()}))
            .is_err()
    );
}

#[test]
fn identity_replacement_retires_all_group_sessions() {
    let (mut a, mut b) = (account(31), account(32));
    verify(&mut a, &b);
    verify(&mut b, &a);
    let sid = "a".repeat(32);
    let peer = id(&b);
    call(
        &mut a,
        "prepare",
        json!({"peerId":peer,"sessionId":sid,"initiator":true}),
    );
    call(
        &mut b,
        "prepare",
        json!({"peerId":id(&a),"sessionId":sid,"initiator":false}),
    );
    let f = call(&mut a, "start", json!({"peerId":peer,"sessionId":sid}))["frame"].clone();
    let r = call(
        &mut b,
        "handshake",
        json!({"peerId":id(&a),"sessionId":sid,"frame":f}),
    )["reply"]
        .clone();
    call(
        &mut a,
        "handshake",
        json!({"peerId":peer,"sessionId":sid,"frame":r}),
    );
    call(
        &mut a,
        "create",
        json!({"name":"old","displayName":"A","now":1}),
    );
    a.create_identity_json().unwrap();
    assert!(
        a.group_call(
            "encrypt",
            json!({"peerId":peer,"sessionId":sid,"id":"old","text":"private"})
        )
        .is_err()
    );
    assert_eq!(
        call(&mut a, "list", json!({}))["groups"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
}

#[test]
fn queued_event_survives_unrelated_membership_change_but_removal_denies_it() {
    let (mut a, mut b, mut c) = (account(33), account(34), account(35));
    verify(&mut a, &b);
    verify(&mut b, &a);
    verify(&mut a, &c);
    verify(&mut c, &a);
    let s = call(
        &mut a,
        "create",
        json!({"name":"team","displayName":"A","now":1}),
    )["state"]
        .as_str()
        .unwrap()
        .to_string();
    let gid = serde_json::from_str::<Value>(&s).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_string();
    let i = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&b),"now":2}),
    )["invite"]
        .clone();
    let r = call(
        &mut b,
        "accept",
        json!({"invite":i,"displayName":"B","now":3}),
    )["receipt"]
        .clone();
    let s = call(&mut a, "add", json!({"receipt":r,"now":4}))["state"].clone();
    call(&mut b, "apply", json!({"state":s}));
    let event=call(&mut a,"sign",json!({"groupId":gid,"id":"queued","kind":"message","payload":"{\"text\":\"hello\"}","now":5}))["event"].clone();
    let i = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&c),"now":6}),
    )["invite"]
        .clone();
    let r = call(
        &mut c,
        "accept",
        json!({"invite":i,"displayName":"C","now":7}),
    )["receipt"]
        .clone();
    let s = call(&mut a, "add", json!({"receipt":r,"now":8}))["state"].clone();
    call(&mut b, "apply", json!({"state":s}));
    assert_eq!(
        call(&mut b, "inspect", json!({"event":event}))["id"],
        "queued"
    );
    let s = call(
        &mut a,
        "remove",
        json!({"groupId":gid,"peerId":id(&b),"now":9}),
    )["state"]
        .clone();
    call(&mut b, "apply", json!({"state":s}));
    assert!(b.group_call("inspect", json!({"event":event})).is_err());
}

#[test]
fn all_sixteen_members_can_accept_and_restore_a_long_name_group() {
    let mut owner = account(40);
    let s = call(
        &mut owner,
        "create",
        json!({"name":"x".repeat(64),"displayName":"o".repeat(64),"now":1}),
    )["state"]
        .as_str()
        .unwrap()
        .to_string();
    let gid = serde_json::from_str::<Value>(&s).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_string();
    for n in 1..16 {
        let mut member = account(40 + n);
        verify(&mut owner, &member);
        verify(&mut member, &owner);
        let now = u64::from(n) * 4;
        let invite = call(
            &mut owner,
            "invite",
            json!({"groupId":gid,"peerId":id(&member),"now":now}),
        )["invite"]
            .clone();
        let info = call(
            &mut member,
            "inspectInvite",
            json!({"invite":invite,"now":now+1}),
        );
        assert_eq!(info["ownerId"], id(&owner));
        assert!(
            call(&mut member, "list", json!({}))["groups"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let receipt = call(
            &mut member,
            "accept",
            json!({"invite":invite,"displayName":"m".repeat(64),"now":now+1}),
        )["receipt"]
            .clone();
        let s = call(&mut owner, "add", json!({"receipt":receipt,"now":now+2}))["state"].clone();
        call(&mut member, "apply", json!({"state":s}));
    }
    let data = call(&mut owner, "export", json!({}))["data"].clone();
    let mut restarted = account(40);
    call(&mut restarted, "import", json!({"data":data}));
    assert_eq!(
        call(&mut restarted, "view", json!({"groupId":gid}))["members"]
            .as_array()
            .unwrap()
            .len(),
        16
    );
}

#[test]
fn acceptance_is_explicit_and_removal_revokes_authorization() {
    let (mut a, mut b, mut c) = (account(1), account(2), account(3));
    verify(&mut a, &b);
    verify(&mut b, &a);
    verify(&mut a, &c);
    let state = call(
        &mut a,
        "create",
        json!({"name":"team","displayName":"Alice","now":1000}),
    )["state"]
        .as_str()
        .unwrap()
        .to_string();
    let gid = serde_json::from_str::<Value>(&state).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_string();
    let invite = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&b),"now":1001}),
    )["invite"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(
        !call(&mut a, "authorize", json!({"peerId":id(&b),"groupId":gid}))["allowed"]
            .as_bool()
            .unwrap()
    );
    let receipt = call(
        &mut b,
        "accept",
        json!({"invite":invite,"displayName":"Bob","now":1002}),
    )["receipt"]
        .as_str()
        .unwrap()
        .to_string();
    let joined = call(&mut a, "add", json!({"receipt":receipt,"now":1003}))["state"]
        .as_str()
        .unwrap()
        .to_string();
    call(&mut b, "apply", json!({"state":joined}));
    assert!(
        call(
            &mut b,
            "authorize",
            json!({"peerId":id(&a),"groupId":gid,"epoch":2})
        )["allowed"]
            .as_bool()
            .unwrap()
    );
    assert!(
        !call(&mut c, "authorize", json!({"peerId":id(&b),"groupId":gid}))["allowed"]
            .as_bool()
            .unwrap()
    );
    let removed = call(
        &mut a,
        "remove",
        json!({"groupId":gid,"peerId":id(&b),"now":1004}),
    )["state"]
        .as_str()
        .unwrap()
        .to_string();
    call(&mut b, "apply", json!({"state":removed}));
    assert!(
        !call(&mut a, "authorize", json!({"peerId":id(&b),"groupId":gid}))["allowed"]
            .as_bool()
            .unwrap()
    );
}

#[test]
fn invite_expiry_forgery_and_unknown_fields_are_rejected() {
    let (mut a, mut b) = (account(4), account(5));
    verify(&mut a, &b);
    verify(&mut b, &a);
    let state = call(
        &mut a,
        "create",
        json!({"name":"x","displayName":"A","now":1}),
    )["state"]
        .as_str()
        .unwrap()
        .to_string();
    let gid = serde_json::from_str::<Value>(&state).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_string();
    let invite = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&b),"now":2}),
    )["invite"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(
        b.group_call(
            "accept",
            json!({"invite":invite,"displayName":"B","now":604800003u64})
        )
        .is_err()
    );
    let mut forged: Value = serde_json::from_str(&invite).unwrap();
    forged["recipientId"] = json!(id(&a));
    assert!(
        b.group_call(
            "accept",
            json!({"invite":forged.to_string(),"displayName":"B","now":3})
        )
        .is_err()
    );
    assert!(
        a.group_call(
            "create",
            json!({"name":"x","displayName":"A","now":4,"extra":true})
        )
        .is_err()
    );
}

#[test]
fn independent_noise_sessions_reject_cross_session_frames() {
    let (mut a, mut b) = (account(6), account(7));
    verify(&mut a, &b);
    verify(&mut b, &a);
    let peer_b = id(&b);
    let peer_a = id(&a);
    let s1 = "a".repeat(32);
    let s2 = "b".repeat(32);
    for s in [&s1, &s2] {
        call(
            &mut a,
            "prepare",
            json!({"peerId":peer_b,"sessionId":s,"initiator":true}),
        );
        call(
            &mut b,
            "prepare",
            json!({"peerId":peer_a,"sessionId":s,"initiator":false}),
        );
        let f = call(&mut a, "start", json!({"peerId":peer_b,"sessionId":s}))["frame"]
            .as_str()
            .unwrap()
            .to_string();
        let reply = call(
            &mut b,
            "handshake",
            json!({"peerId":peer_a,"sessionId":s,"frame":f}),
        )["reply"]
            .as_str()
            .unwrap()
            .to_string();
        call(
            &mut a,
            "handshake",
            json!({"peerId":peer_b,"sessionId":s,"frame":reply}),
        );
    }
    let frame = call(
        &mut a,
        "encrypt",
        json!({"peerId":peer_b,"sessionId":s1,"id":"msg","text":"hello"}),
    )["frame"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(
        b.group_call(
            "decrypt",
            json!({"peerId":peer_a,"sessionId":s2,"frame":frame})
        )
        .is_err()
    );
    assert_eq!(
        call(
            &mut b,
            "decrypt",
            json!({"peerId":peer_a,"sessionId":s1,"frame":frame})
        )["text"],
        "hello"
    );
}

#[test]
fn chained_invites_import_and_forks_are_rejected() {
    let (mut a, mut b, mut c) = (account(8), account(9), account(10));
    for p in [&b, &c] {
        verify(&mut a, p)
    }
    verify(&mut b, &a);
    verify(&mut c, &a);
    let genesis = call(
        &mut a,
        "create",
        json!({"name":"chain","displayName":"A","now":1}),
    )["state"]
        .as_str()
        .unwrap()
        .to_string();
    let gid = serde_json::from_str::<Value>(&genesis).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_string();
    let invite_b = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&b),"now":2}),
    )["invite"]
        .as_str()
        .unwrap()
        .to_string();
    let receipt_b = call(
        &mut b,
        "accept",
        json!({"invite":invite_b,"displayName":"B","now":3}),
    )["receipt"]
        .as_str()
        .unwrap()
        .to_string();
    let second = call(&mut a, "add", json!({"receipt":receipt_b,"now":4}))["state"]
        .as_str()
        .unwrap()
        .to_string();
    let invite_c = call(
        &mut a,
        "invite",
        json!({"groupId":gid,"peerId":id(&c),"now":5}),
    )["invite"]
        .as_str()
        .unwrap()
        .to_string();
    let receipt_c = call(
        &mut c,
        "accept",
        json!({"invite":invite_c,"displayName":"C","now":6}),
    )["receipt"]
        .as_str()
        .unwrap()
        .to_string();
    let third = call(&mut a, "add", json!({"receipt":receipt_c,"now":7}))["state"]
        .as_str()
        .unwrap()
        .to_string();
    call(&mut c, "apply", json!({"state":third}));
    assert_eq!(call(&mut c, "view", json!({"groupId":gid}))["epoch"], 3);
    let exported = call(&mut c, "export", json!({}))["data"]
        .as_str()
        .unwrap()
        .to_string();
    let mut restarted = account(10);
    verify(&mut restarted, &a);
    call(&mut restarted, "import", json!({"data":exported}));
    assert_eq!(
        call(&mut restarted, "view", json!({"groupId":gid}))["epoch"],
        3
    );
    assert!(c.group_call("apply", json!({"state":second})).is_err());
    let mut altered: Value = serde_json::from_str(&third).unwrap();
    altered["members"][1]["identity"]["noiseStaticPublicKey"] = json!("AA");
    assert!(
        c.group_call("apply", json!({"state":altered.to_string()}))
            .is_err()
    );
    let closed = call(&mut a, "leave", json!({"groupId":gid,"now":8}))["state"]
        .as_str()
        .unwrap()
        .to_string();
    call(&mut c, "apply", json!({"state":closed}));
    assert!(
        !call(&mut c, "authorize", json!({"peerId":id(&a),"groupId":gid}))["allowed"]
            .as_bool()
            .unwrap()
    );
}

#[test]
fn group_seed_is_separate_from_legacy_and_replay_safe() {
    let (mut a, mut b) = (account(11), account(12));
    verify(&mut a, &b);
    verify(&mut b, &a);
    let session = "0123456789abcdef0123456789abcdef";
    let text=json!({"v":1,"t":"ice","s":session,"c":"candidate:1 1 UDP 123 192.0.2.1 1234 typ host","m":null,"l":0}).to_string();
    let signal=call(&mut a,"signSignal",json!({"peerId":id(&b),"id":format!("cht-control-groups-v1-{session}-ice-0"),"text":text,"now":1000}))["source"].as_str().unwrap().to_string();
    assert!(b.inspect_seed_signal(&signal, &id(&a), 1000).is_err());
    assert_eq!(
        call(
            &mut b,
            "inspectSignal",
            json!({"source":signal,"expectedPeer":id(&a),"now":1000})
        )["text"],
        text
    );
    assert!(
        b.group_call(
            "inspectSignal",
            json!({"source":signal,"expectedPeer":id(&a),"now":1000})
        )
        .is_err()
    );
    let mut changed: Value = serde_json::from_str(&signal).unwrap();
    changed["topic"] = json!("messages");
    assert!(
        b.group_call(
            "inspectSignal",
            json!({"source":changed.to_string(),"expectedPeer":id(&a),"now":1000})
        )
        .is_err()
    );
}
