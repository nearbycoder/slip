use slip_core::model::*;

#[test]
fn device_info_round_trip() {
    let info = DeviceInfo {
        alias: "Nice Orange".into(),
        version: "2.1".into(),
        device_model: Some("Linux".into()),
        device_type: Some(DeviceType::Desktop),
        fingerprint: "abc".into(),
        port: 53317,
        protocol: Protocol::Https,
        download: false,
    };
    let json = serde_json::to_value(&info).unwrap();
    assert_eq!(
        json,
        serde_json::json!({
            "alias": "Nice Orange", "version": "2.1", "deviceModel": "Linux", "deviceType": "desktop",
            "fingerprint": "abc", "port": 53317, "protocol": "https", "download": false
        })
    );
    let back: DeviceInfo = serde_json::from_value(json).unwrap();
    assert_eq!(back, info);
}

#[test]
fn device_info_lenient_minimal() {
    // Register responses may omit port/protocol/download/model/type.
    let info: DeviceInfo = serde_json::from_str(r#"{"alias":"Secret Banana","version":"2.0","fingerprint":"f"}"#).unwrap();
    assert_eq!(info.port, 53317);
    assert_eq!(info.protocol, Protocol::Https);
    assert!(!info.download);
    assert_eq!(info.device_model, None);
    assert_eq!(info.device_type, None);
    assert_eq!(info.device_type_or_default(), DeviceType::Desktop);
}

#[test]
fn device_info_lenient_nulls_and_unknowns() {
    let info: DeviceInfo = serde_json::from_str(
        r#"{"alias":"X","version":null,"deviceModel":null,"deviceType":"toaster","fingerprint":"f",
            "port":null,"protocol":"HTTP","download":null,"extra":{"nested":[1,2,3]},"announce":true}"#,
    )
    .unwrap();
    assert_eq!(info.version, "2.1");
    assert_eq!(info.device_type, Some(DeviceType::Desktop), "unknown device types fall back to desktop");
    assert_eq!(info.port, 53317);
    assert_eq!(info.protocol, Protocol::Http);
    assert!(!info.download);

    let info: DeviceInfo = serde_json::from_str(r#"{"alias":"Y","deviceType":"mobile","port":"53318","protocol":"weird"}"#).unwrap();
    assert_eq!(info.device_type, Some(DeviceType::Mobile));
    assert_eq!(info.port, 53318);
    assert_eq!(info.protocol, Protocol::Https);
    assert_eq!(info.fingerprint, "");
    // Missing alias is tolerated.
    let info: DeviceInfo = serde_json::from_str(r#"{"fingerprint":"z"}"#).unwrap();
    assert_eq!(info.alias, "Unknown");
}

#[test]
fn all_device_types_parse() {
    for (s, t) in [
        ("mobile", DeviceType::Mobile),
        ("desktop", DeviceType::Desktop),
        ("web", DeviceType::Web),
        ("headless", DeviceType::Headless),
        ("server", DeviceType::Server),
    ] {
        let info: DeviceInfo = serde_json::from_str(&format!(r#"{{"alias":"a","deviceType":"{s}"}}"#)).unwrap();
        assert_eq!(info.device_type, Some(t));
        assert_eq!(serde_json::to_value(t).unwrap(), serde_json::json!(s));
    }
}

#[test]
fn multicast_announce_and_legacy_key() {
    let info: DeviceInfo = serde_json::from_str(r#"{"alias":"A","fingerprint":"f"}"#).unwrap();
    let dto = MulticastDto { info: info.clone(), announce: true };
    let v: serde_json::Value = serde_json::from_slice(&dto.to_json()).unwrap();
    assert_eq!(v["announce"], true);
    assert_eq!(v["announcement"], true);
    assert_eq!(v["alias"], "A");
    assert_eq!(MulticastDto::parse(&dto.to_json()).unwrap(), dto);

    // v1 peers only send `announcement`.
    let legacy = MulticastDto::parse(br#"{"alias":"B","fingerprint":"g","announcement":true}"#).unwrap();
    assert!(legacy.announce);
    let neither = MulticastDto::parse(br#"{"alias":"B","fingerprint":"g"}"#).unwrap();
    assert!(!neither.announce);
    let response = MulticastDto::parse(br#"{"alias":"B","fingerprint":"g","announce":false,"announcement":true}"#).unwrap();
    assert!(!response.announce, "`announce` takes precedence");
    assert!(MulticastDto::parse(b"not json").is_err());
}

#[test]
fn file_dto_round_trip_and_lenient() {
    let f = FileDto {
        id: "1".into(),
        file_name: "a.png".into(),
        size: 123,
        file_type: "image/png".into(),
        sha256: None,
        preview: None,
        metadata: Some(FileMetadata { modified: Some("2024-01-01T12:00:00Z".into()), accessed: None }),
    };
    let v = serde_json::to_value(&f).unwrap();
    assert_eq!(
        v,
        serde_json::json!({"id":"1","fileName":"a.png","size":123,"fileType":"image/png","sha256":null,"preview":null,
            "metadata":{"modified":"2024-01-01T12:00:00Z","accessed":null}})
    );
    assert_eq!(serde_json::from_value::<FileDto>(v).unwrap(), f);

    let f: FileDto = serde_json::from_str(r#"{"id":"2","fileName":"x","size":10.0,"fileType":null,"metadata":"bogus","extra":1}"#).unwrap();
    assert_eq!(f.size, 10);
    assert_eq!(f.file_type, "application/octet-stream");
    assert_eq!(f.metadata, None);
}

#[test]
fn prepare_upload_parse_fills_ids_and_detects_text() {
    let body = br#"{
        "info": {"alias":"S","version":"2.0","deviceModel":"Samsung","deviceType":"mobile","fingerprint":"x","port":53317,"protocol":"https","download":true},
        "files": {
            "k1": {"fileName":"hello.txt","size":5,"fileType":"text/plain","preview":"hello"}
        }
    }"#;
    let req = PrepareUploadRequest::parse(body).unwrap();
    assert_eq!(req.files["k1"].id, "k1");
    assert!(req.info.download);
    assert!(req.is_text_message());

    let body = br#"{"info":{"alias":"S"},"files":{"a":{"id":"a","fileName":"t.txt","size":5,"fileType":"text/plain","preview":null}}}"#;
    assert!(!PrepareUploadRequest::parse(body).unwrap().is_text_message(), "text file without preview is a file");

    let resp: PrepareUploadResponse = serde_json::from_str(r#"{"sessionId":"s","files":{"a":"t"},"x":1}"#).unwrap();
    assert_eq!(resp.files["a"], "t");
    let v = serde_json::to_value(&resp).unwrap();
    assert_eq!(v, serde_json::json!({"sessionId":"s","files":{"a":"t"}}));
}
