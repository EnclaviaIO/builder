use std::path::{Path, PathBuf};
use std::process::Stdio;

use clap::Parser;
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tracing::{error, info};

#[derive(Debug, thiserror::Error)]
enum Error {
    #[error("command `{cmd}` failed with status {status} (see build log for stderr)")]
    Command {
        cmd: String,
        status: std::process::ExitStatus,
    },
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

type Result<T> = std::result::Result<T, Error>;

#[derive(Parser)]
#[command(name = "builder", about = "Build Enclavia enclave images from Docker images")]
enum Cli {
    /// Build an EIF from a Docker image
    Build {
        /// Docker image reference (e.g. registry.enclavia.io/customer/app:tag)
        #[arg(long)]
        image: String,

        /// Registry username for authentication
        #[arg(long)]
        registry_user: Option<String>,

        /// Registry password for authentication
        #[arg(long)]
        registry_password: Option<String>,

        /// Pre-minted bearer token for the source registry. Bypasses the
        /// distribution auth realm round-trip — the caller (typically
        /// enclavia-backend) signs it directly with the registry's JWKS
        /// key. Mutually exclusive with --registry-user/--registry-password.
        #[arg(long)]
        registry_token: Option<String>,

        /// Directory to write output artifacts (image.eif, pcr.json)
        #[arg(long, default_value = "./out")]
        output_dir: PathBuf,

        /// Port the customer's container listens on inside the enclave
        #[arg(long, default_value = "8080")]
        container_port: u16,

        /// Build for debug mode (QEMU with patched init using CID 2)
        #[arg(long)]
        debug: bool,

        /// Build with persistent encrypted storage support (LUKS+btrfs over NBD).
        /// Switches the EIF target to `enclave-storage[-debug]`, which includes
        /// a custom kernel with NBD + dm-crypt + btrfs and the enclavia-crypto
        /// binary. The KMS key id is not baked into the EIF — enclavia-crypto
        /// reads it from the bootstrap blob in the storage backing file.
        #[arg(long)]
        storage: bool,

        /// Base64-encoded Ed25519 public key (32 raw bytes) for the management
        /// control channel. When set, enclavia-server will accept signed
        /// `Control` commands from the backend; when absent the channel is
        /// disabled. Required for the upgrade flow.
        #[arg(long)]
        control_pubkey: Option<String>,

        /// Per-enclave identifier stamped into `enclavia-config.json` so two
        /// enclaves built from the same Docker image (and same other inputs)
        /// still produce different PCRs. The value is opaque to the builder,
        /// typically the backend's enclave UUID. Optional so direct
        /// builder users (CI, manual debugging) don't have to mint one;
        /// production callers always pass it.
        #[arg(long)]
        enclave_id: Option<String>,

        /// Path to the egress allowlist JSON (`{"version":1,"resolvers":[],
        /// "egress":[...]}`). When set, the file is copied into the OCI
        /// bundle as `egress.json`; `enclave.nix` then places it at
        /// `/etc/enclavia/egress.json` in the rootfs. When unset, no file is
        /// baked in: the in-enclave daemon defaults to deny-all.
        #[arg(long)]
        egress_allowlist: Option<PathBuf>,
    },
}

#[derive(Debug, Serialize, Deserialize)]
struct PcrValues {
    #[serde(rename = "PCR0")]
    pcr0: String,
    #[serde(rename = "PCR1")]
    pcr1: String,
    #[serde(rename = "PCR2")]
    pcr2: String,
}

#[derive(Debug, Serialize)]
struct BuildResult {
    eif_path: PathBuf,
    pcrs: PcrValues,
}

async fn run_cmd(cmd: &str, args: &[&str]) -> Result<String> {
    info!(cmd, ?args, "running command");

    // Inherit stderr so the child writes directly to our stderr FD. The
    // backend line-streams the builder's stderr into the build log; piping
    // here would buffer the child's stderr until exit and the user would
    // see nothing for the duration of long commands like `nix build`.
    // stdout stays piped — callers parse JSON from it.
    let output = Command::new(cmd)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?
        .wait_with_output()
        .await?;

    if !output.status.success() {
        return Err(Error::Command {
            cmd: cmd.to_string(),
            status: output.status,
        });
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Pull a Docker image to a local OCI layout using skopeo.
///
/// Authentication can be passed two ways. `creds` triggers skopeo's full
/// Bearer-auth handshake (HTTP Basic to the realm → bearer → re-request).
/// `registry_token` skips that round-trip and hands skopeo a pre-minted
/// bearer directly via `--src-registry-token`. The backend uses the latter
/// because it already has the registry signing key in process and can sign
/// itself a token without bouncing through the auth realm.
async fn pull_image(
    image: &str,
    dest: &Path,
    creds: Option<(&str, &str)>,
    registry_token: Option<&str>,
) -> Result<()> {
    let src = format!("docker://{image}");
    let dst = format!("oci:{}:latest", dest.display());

    let mut args = vec!["copy", &src, &dst];

    // Disable TLS verification for localhost registries (dev/test).
    if image.starts_with("localhost:") || image.starts_with("127.0.0.1:") {
        args.push("--src-tls-verify=false");
    }

    let creds_str;
    if let Some((user, pass)) = creds {
        creds_str = format!("{user}:{pass}");
        args.extend(["--src-creds", &creds_str]);
    }

    if let Some(tok) = registry_token {
        args.extend(["--src-registry-token", tok]);
    }

    run_cmd("skopeo", &args).await?;
    info!(image, "image pulled successfully");
    Ok(())
}

/// Unpack an OCI image into an OCI runtime bundle using umoci.
async fn unpack_bundle(oci_layout: &Path, bundle_dir: &Path) -> Result<()> {
    let image_arg = format!("{}:latest", oci_layout.display());

    run_cmd(
        "umoci",
        &[
            "unpack",
            "--rootless",
            "--image",
            &image_arg,
            &bundle_dir.to_string_lossy(),
        ],
    )
    .await?;

    info!(?bundle_dir, "OCI bundle unpacked");
    Ok(())
}

/// Patch the OCI bundle config for enclave compatibility.
///
/// The enclave runs a single container as root on an initramfs. Namespace
/// isolation adds no value and several types (cgroup, mount) are incompatible
/// with the minimal nitro-enclave kernel. We also remove the UID/GID mappings
/// that `umoci --rootless` generates, since they map container root to the
/// build user (UID 1000) rather than the enclave's real root (UID 0).
fn patch_bundle_config(bundle_dir: &Path) -> Result<()> {
    let config_path = bundle_dir.join("config.json");
    let content = std::fs::read_to_string(&config_path)?;
    let mut config: serde_json::Value = serde_json::from_str(&content)?;

    // Remove ALL namespaces — the enclave kernel lacks cgroup namespace support
    // and mount namespace fails on initramfs. PID/IPC/UTS/user are unnecessary.
    if let Some(namespaces) = config
        .pointer_mut("/linux/namespaces")
        .and_then(|v| v.as_array_mut())
    {
        let before = namespaces.len();
        namespaces.clear();
        if before > 0 {
            info!(removed = before, "stripped all namespaces from OCI config");
        }
    }

    // Remove rootless UID/GID mappings — we run as real root in the enclave,
    // not as the unprivileged build user these mappings target.
    if let Some(linux) = config.pointer_mut("/linux").and_then(|v| v.as_object_mut()) {
        linux.remove("uidMappings");
        linux.remove("gidMappings");
    }

    // Remove hostname — setting it requires the UTS namespace, which we strip.
    if let Some(obj) = config.as_object_mut() {
        obj.remove("hostname");
    }

    // Disable terminal — crun needs devpts to allocate a pty, which isn't
    // available on initramfs. With terminal=false, the container's stdout/stderr
    // go directly to the init script's file descriptors.
    if let Some(terminal) = config.pointer_mut("/process/terminal") {
        *terminal = serde_json::Value::Bool(false);
    }

    // Grant all capabilities — the enclave is the security boundary, not the
    // container. Without CAP_DAC_OVERRIDE, the container process (UID 0) can't
    // write to files owned by the build user (UID 1000 from umoci --rootless).
    let all_caps: serde_json::Value = serde_json::json!([
        "CAP_AUDIT_WRITE", "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH",
        "CAP_FOWNER", "CAP_FSETID", "CAP_KILL", "CAP_MKNOD", "CAP_NET_BIND_SERVICE",
        "CAP_NET_RAW", "CAP_SETFCAP", "CAP_SETGID", "CAP_SETPCAP", "CAP_SETUID",
        "CAP_SYS_CHROOT"
    ]);
    if let Some(caps) = config.pointer_mut("/process/capabilities") {
        if let Some(obj) = caps.as_object_mut() {
            for key in &["bounding", "effective", "inheritable", "permitted", "ambient"] {
                obj.insert(key.to_string(), all_caps.clone());
            }
        }
    }

    // Strip all mounts — without mount namespace, crun tries to mount in the
    // global namespace on initramfs, which fails for cgroups, devpts, bind-mounts
    // of /etc/resolv.conf, etc. Essential filesystems (proc, dev, sys, tmp) are
    // pre-mounted by the init script instead.
    if let Some(mounts) = config
        .pointer_mut("/mounts")
        .and_then(|v| v.as_array_mut())
    {
        let before = mounts.len();
        mounts.clear();
        if before > 0 {
            info!(removed = before, "stripped all mounts from OCI config");
        }
    }

    let patched = serde_json::to_string_pretty(&config)?;
    std::fs::write(&config_path, patched)?;

    // Point /etc/resolv.conf at the in-enclave unbound on 127.0.0.1.
    // **Always overwrite** — the previous `if !resolv.exists()` branch
    // silently left a pre-populated resolv.conf in place, which is the
    // common case for Debian / Alpine / Ubuntu base images. The workload
    // would then `getaddrinfo` against whatever nameservers the base
    // image baked in (Docker's `127.0.0.11`, or unreachable public
    // resolvers, or nothing) and fail with `EAI_AGAIN` even for
    // destinations that were correctly listed in the egress allowlist.
    // See pre-beta egress verification trace where every probe came
    // back `URLError:[Errno -3] Temporary failure in name resolution`.
    //
    // For enclaves *without* an egress allowlist the in-enclave unbound
    // is not started, so connections to 127.0.0.1:53 fail fast — that
    // matches the "no egress" UX (no outbound, including DNS) and is
    // the right failure mode. We don't need to handle the no-egress
    // case specially.
    let resolv = bundle_dir.join("rootfs/etc/resolv.conf");
    std::fs::create_dir_all(bundle_dir.join("rootfs/etc"))?;
    std::fs::write(&resolv, "nameserver 127.0.0.1\n")?;
    info!("wrote /etc/resolv.conf in container rootfs");

    Ok(())
}

/// Make the OCI bundle deterministic before passing it to `nix build`.
///
/// `nix build` ingests the bundle via `--override-input oci-bundle path:<dir>`,
/// and `path:` narHashing folds in both file content and mtimes. Without this
/// step the input narHash is fresh on every invocation, which propagates
/// through `enclave-rootfs` → `user-initramfs.cpio.gz` → final EIF and
/// changes PCR0/PCR2 every run (builder#10).
///
/// Two sources of nondeterminism, both addressed here:
///
/// 1. **mtimes** — `umoci unpack`, `patch_bundle_config`, and
///    `write_enclavia_config` all create/touch files with the host's current
///    time. We reset every entry's mtime/atime to the Unix epoch.
/// 2. **umoci's bookkeeping files** — `umoci.json` records the host UID/GID
///    used for the rootless unpack (varies across machines/users), and the
///    `sha256_*.mtree` manifest embeds the unpack path, hostname, and a
///    real-time `date:` header. Neither is consulted at enclave runtime, so
///    we delete them outright.
///
/// Symlinks are skipped for the mtime reset — `set_file_times` would follow
/// them and rewrite the target's times.
fn normalize_bundle_for_nix(dir: &Path) -> Result<()> {
    // 1. Strip umoci's per-host bookkeeping.
    let mut removed = 0usize;
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name == "umoci.json" || (name.starts_with("sha256_") && name.ends_with(".mtree")) {
            std::fs::remove_file(entry.path())?;
            removed += 1;
        }
    }

    // 2. Reset mtime/atime on everything that survives.
    let epoch = filetime::FileTime::from_unix_time(0, 0);
    let mut touched = 0usize;
    for entry in walkdir::WalkDir::new(dir) {
        let entry = entry.map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::Other, e.to_string())
        })?;
        if entry.file_type().is_symlink() {
            continue;
        }
        filetime::set_file_times(entry.path(), epoch, epoch)?;
        touched += 1;
    }
    info!(
        ?dir, removed_bookkeeping = removed, touched_entries = touched,
        "normalized bundle for deterministic nix path-input"
    );
    Ok(())
}

/// Build the enclave EIF using nix, overriding the oci-bundle input.
///
/// In production the deployment also overrides `enclavia-crates` and
/// `enclavia` with pinned source paths via the `ENCLAVIA_CRATES_FLAKE`
/// and `ENCLAVIA_FLAKE` env vars; in dev the flake's defaults (`./dummy-*`)
/// are replaced by passing `--override-input enclavia-crates path:...`
/// and `--override-input enclavia path:...` to the QEMU wrapper.
async fn build_eif(
    bundle_dir: &Path,
    result_link: &Path,
    debug: bool,
    storage: bool,
) -> Result<()> {
    let bundle_arg = format!("path:{}", bundle_dir.display());
    let out_arg = result_link.to_string_lossy();

    // Resolve the builder's own directory so `nix build` finds the correct flake
    // regardless of the working directory. In production the binary lives at
    // `<pkg>/bin/builder` with no flake.nix anywhere up the chain, so callers
    // must set `BUILDER_FLAKE` to a path that contains the builder's flake
    // (typically the source flake input from a wrapping deployment).
    let builder_dir = match std::env::var_os("BUILDER_FLAKE") {
        Some(p) => PathBuf::from(p),
        None => std::env::current_exe()?
            .parent()
            .and_then(|p| p.parent())
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from(".")),
    };
    // `enclave-storage[-debug]` pulls in the storage-capable kernel (with NBD
    // + dm-crypt + btrfs), the enclavia-crypto binary, and cryptsetup/btrfs
    // userspace. The KMS key id lives in the bootstrap blob in the storage
    // backing file, not in the EIF.
    let target = match (debug, storage) {
        (true, true) => "enclave-storage-debug",
        (false, true) => "enclave-storage",
        (true, false) => "enclave-debug",
        (false, false) => "enclave",
    };
    let flake_ref = format!("{}#{}", builder_dir.display(), target);

    let mut args: Vec<String> = vec![
        "build".into(),
        flake_ref,
        "--override-input".into(),
        "oci-bundle".into(),
        bundle_arg,
    ];

    // ENCLAVIA_CRATES_FLAKE: production override for the closed-source
    // host-side workspace (egress-host, storage-host).
    if let Some(p) = std::env::var_os("ENCLAVIA_CRATES_FLAKE") {
        args.push("--override-input".into());
        args.push("enclavia-crates".into());
        args.push(format!("path:{}", PathBuf::from(p).display()));
    }

    // ENCLAVIA_FLAKE: production override for the public Enclavia
    // workspace (enclavia-server, enclavia-egress, enclavia-crypto,
    // nbd-client, mock-kms).
    if let Some(p) = std::env::var_os("ENCLAVIA_FLAKE") {
        args.push("--override-input".into());
        args.push("enclavia".into());
        args.push(format!("path:{}", PathBuf::from(p).display()));
    }

    args.push("-o".into());
    args.push(out_arg.into_owned());

    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    run_cmd("nix", &arg_refs).await?;

    info!(?result_link, "EIF built successfully");
    Ok(())
}

/// Read PCR values from the build output.
fn read_pcrs(result_dir: &Path) -> Result<PcrValues> {
    let pcr_path = result_dir.join("pcr.json");
    let content = std::fs::read_to_string(&pcr_path)?;
    let pcrs: PcrValues = serde_json::from_str(&content)?;
    Ok(pcrs)
}

/// Copy build artifacts to the output directory.
fn copy_artifacts(result_dir: &Path, output_dir: &Path) -> Result<()> {
    std::fs::create_dir_all(output_dir)?;

    for filename in ["image.eif", "pcr.json"] {
        let src = result_dir.join(filename);
        let dst = output_dir.join(filename);
        std::fs::copy(&src, &dst)?;
        info!(?dst, "copied artifact");
    }

    Ok(())
}

/// Validate that a base64-encoded Ed25519 public key decodes to exactly
/// 32 bytes. We don't verify it's a valid curve point — enclavia-server
/// re-parses it via ed25519-dalek at boot, which catches that.
fn validate_control_pubkey(b64: &str) -> std::result::Result<(), String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64.as_bytes())
        .map_err(|e| format!("invalid base64: {e}"))?;
    if bytes.len() != 32 {
        return Err(format!(
            "expected 32 bytes (raw Ed25519 public key), got {}",
            bytes.len()
        ));
    }
    Ok(())
}

/// Write the enclavia config into the bundle so enclave.nix picks it up.
fn write_enclavia_config(
    bundle_dir: &Path,
    container_port: u16,
    storage: bool,
    control_pubkey: Option<&str>,
    enclave_id: Option<&str>,
) -> Result<()> {
    let mut config = serde_json::json!({
        "listen_vsock_port": 5000,
        "oci_bundle_path": "/var/lib/oci/bundle",
        "customer_app": {
            "port": container_port,
            "health_check": "/health",
            "startup_timeout_secs": 30
        }
    });

    if storage {
        config["storage"] = serde_json::json!({
            "enabled": true,
            "vsock_port": 5001,
            "meta_vsock_port": 5002,
            "kms_vsock_port": 5003,
            "mount_point": "/data",
            "device": "/dev/nbd0",
        });
    }

    if let Some(pubkey) = control_pubkey {
        config["control_public_key"] = serde_json::Value::String(pubkey.to_string());
    }

    if let Some(id) = enclave_id {
        config["enclave_id"] = serde_json::Value::String(id.to_string());
    }

    let path = bundle_dir.join("enclavia-config.json");
    std::fs::write(&path, serde_json::to_string_pretty(&config).unwrap())?;
    info!(
        container_port,
        storage,
        control_channel = control_pubkey.is_some(),
        has_enclave_id = enclave_id.is_some(),
        "wrote enclavia config"
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn build(
    image: &str,
    creds: Option<(&str, &str)>,
    registry_token: Option<&str>,
    output_dir: &Path,
    container_port: u16,
    debug: bool,
    storage: bool,
    control_pubkey: Option<&str>,
    enclave_id: Option<&str>,
    egress_allowlist: Option<&Path>,
) -> Result<BuildResult> {
    let tmp = tempfile::tempdir()?;
    let tmp_path = tmp.path();

    let oci_layout = tmp_path.join("image");
    let bundle_dir = tmp_path.join("bundle");
    let result_link = tmp_path.join("result");

    // 1. Pull the Docker image
    info!(image, "pulling image");
    pull_image(image, &oci_layout, creds, registry_token).await?;

    // 2. Unpack into OCI bundle
    info!("unpacking OCI bundle");
    unpack_bundle(&oci_layout, &bundle_dir).await?;

    // 3. Patch OCI config for enclave compatibility
    patch_bundle_config(&bundle_dir)?;

    // 4. Write enclavia config into bundle
    write_enclavia_config(&bundle_dir, container_port, storage, control_pubkey, enclave_id)?;

    // 4b. If the caller supplied an egress allowlist, drop it into the
    // bundle at a fixed name. `enclave.nix` checks for this path and
    // installs the file at `/etc/enclavia/egress.json` in the rootfs.
    // The file content is hashed into the EIF, so changing it changes
    // PCR2 (rootfs) and is visible via `enclavia reproduce`.
    if let Some(src) = egress_allowlist {
        let dst = bundle_dir.join("egress.json");
        std::fs::copy(src, &dst)?;
        info!(src = ?src, dst = ?dst, "copied egress allowlist into bundle");
    }

    // 5. Normalize bundle so `path:` narHashing is deterministic
    normalize_bundle_for_nix(&bundle_dir)?;

    // 6. Build the EIF
    info!(storage, "building enclave image");
    build_eif(&bundle_dir, &result_link, debug, storage).await?;

    // 7. Read PCR values
    let pcrs = read_pcrs(&result_link)?;
    info!(pcr0 = %pcrs.pcr0, pcr1 = %pcrs.pcr1, pcr2 = %pcrs.pcr2, "PCR values");

    // 8. Copy artifacts to output
    copy_artifacts(&result_link, output_dir)?;

    Ok(BuildResult {
        eif_path: output_dir.join("image.eif"),
        pcrs,
    })
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".parse().unwrap()),
        )
        .init();

    let cli = Cli::parse();

    match cli {
        Cli::Build {
            image,
            registry_user,
            registry_password,
            registry_token,
            output_dir,
            container_port,
            debug,
            storage,
            control_pubkey,
            enclave_id,
            egress_allowlist,
        } => {
            let creds = match (&registry_user, &registry_password) {
                (Some(u), Some(p)) => Some((u.as_str(), p.as_str())),
                _ => None,
            };

            if let Some(ref pk) = control_pubkey {
                if let Err(e) = validate_control_pubkey(pk) {
                    error!(%e, "--control-pubkey rejected");
                    std::process::exit(2);
                }
            }

            match build(
                &image,
                creds,
                registry_token.as_deref(),
                &output_dir,
                container_port,
                debug,
                storage,
                control_pubkey.as_deref(),
                enclave_id.as_deref(),
                egress_allowlist.as_deref(),
            )
            .await
            {
                Ok(result) => {
                    let json = serde_json::to_string_pretty(&result).unwrap();
                    println!("{json}");
                }
                Err(e) => {
                    error!(%e, "build failed");
                    std::process::exit(1);
                }
            }
        }
    }
}
