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
    #[error("invalid generated OCI archive: {0}")]
    OciArchive(String),
}

type Result<T> = std::result::Result<T, Error>;

const SENSITIVE_COMMAND_FLAGS: &[&str] = &[
    "--src-creds",
    "--src-password",
    "--src-registry-token",
    "--dest-creds",
    "--dest-password",
    "--dest-registry-token",
    "--registry-password",
    "--registry-token",
];

#[derive(Parser)]
#[command(
    name = "builder",
    about = "Build Enclavia enclave images from Docker images"
)]
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

        /// Base64-encoded ECDSA P-256 public key in uncompressed SEC1
        /// form (65 raw bytes: `0x04 || X(32) || Y(32)`, big-endian) for
        /// the management control channel (#47). When set, the
        /// in-enclave server will accept signed `Control` commands from
        /// the backend; when absent the channel is disabled. Required
        /// for the upgrade flow.
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

        /// Registry manifest digest of the Docker image being built. Stamped
        /// into `enclavia-config.json` so the in-enclave chain-init helper
        /// (#47, phase 3b) can populate `BootPayload::image_digest` when it
        /// submits the boot attestation through the host-side chain-host
        /// daemon. Optional so direct builder users (CI, manual debugging)
        /// don't have to pass one; the backend always supplies it.
        ///
        /// Expected shape is `sha256:[0-9a-f]{64}` (what the registry
        /// returns from a manifest GET). Light shape check at validate time
        /// keeps an obviously-wrong value from making it into the EIF.
        #[arg(long)]
        image_digest: Option<String>,

        /// Path to the egress allowlist JSON (`{"version":1,"resolvers":[],
        /// "egress":[...]}`). When set, the file is copied into the OCI
        /// bundle as `egress.json`; `enclave.nix` then places it at
        /// `/etc/enclavia/egress.json` in the rootfs. When unset, no file is
        /// baked in: the in-enclave daemon defaults to deny-all.
        #[arg(long)]
        egress_allowlist: Option<PathBuf>,

        /// Synchronizer trust anchors for the anti-rollback wiring
        /// (enclavia#208). The value is either a path to a JSON file or
        /// inline JSON (detected by a leading `{` or `[`): one
        /// `{"PCR0","PCR1","PCR2"}` hex triple (the shape of pcr.json,
        /// e.g. from the synchronizer image's own build) or a list of
        /// such triples. When set, a `synchronizer` section with
        /// `expected_pcrs` and `debug_attestation` (mirroring --debug)
        /// is stamped into `enclavia-config.json`, which lands at
        /// `/etc/enclavia/config.json` inside the MEASURED rootfs; the
        /// in-enclave nbd-client reads it to authenticate the
        /// synchronizer oracle before serving storage. When unset, no
        /// section is written and enclaves keep today's behavior
        /// (nbd-client's wiring is opted in by --synchronizer-enabled,
        /// below, and then fail-stops on a missing section). The backend
        /// supplies this at build time; the values MUST come from
        /// build-time config, never from the running host.
        #[arg(long)]
        synchronizer_pcrs: Option<String>,

        /// Turn ON the in-enclave anti-rollback wiring (enclavia#208):
        /// stamp `synchronizer.enabled = true` into the measured config,
        /// which the EIF init reads to export `SYNCHRONIZER_ENABLED=1`
        /// for the nbd-client. REQUIRES --synchronizer-pcrs (an enabled
        /// wiring with no expected oracle PCRs would fail-stop the
        /// enclave at every boot). Without this flag the wiring stays
        /// off even if anchors are baked in, so an enclave can ship the
        /// anchors disabled and be flipped on by a later rebuild.
        #[arg(long)]
        synchronizer_enabled: bool,

        /// Create-time immutable minimum upgrade activation delay in
        /// seconds (enclavia-crates#205). When set (and non-zero), the
        /// value is stamped into `enclavia-config.json`, which lands at
        /// `/etc/enclavia/config.json` inside the MEASURED rootfs
        /// (PCR2), so the in-enclave server can reject a PrepareUpgrade
        /// whose valid_from is earlier than now + this delay. Absent or
        /// 0 keeps current behavior (no field written, config bytes
        /// identical for existing enclaves).
        #[arg(long, value_name = "SECS")]
        min_upgrade_delay_secs: Option<u64>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

async fn run_cmd_with_env(cmd: &str, args: &[&str], env: &[(&str, &str)]) -> Result<String> {
    let logged_args = redact_command_args(args);
    info!(cmd, args = ?logged_args, "running command");

    // Inherit stderr so the child writes directly to our stderr FD. The
    // backend line-streams the builder's stderr into the build log; piping
    // here would buffer the child's stderr until exit and the user would
    // see nothing for the duration of long commands like `nix build`.
    // stdout stays piped — callers parse JSON from it.
    let output = Command::new(cmd)
        .args(args)
        .envs(env.iter().copied())
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

/// Copy command arguments into a log-safe representation.
///
/// Skopeo accepts registry credentials and bearer tokens as either a separate
/// argument (`--src-creds VALUE`) or an equals-form argument
/// (`--src-creds=VALUE`). Keep the flag visible for diagnostics but never put
/// its value into tracing output. The original argument slice is still passed
/// unchanged to the child process.
fn redact_command_args(args: &[&str]) -> Vec<String> {
    let mut redact_next = false;
    args.iter()
        .map(|arg| {
            if redact_next {
                redact_next = false;
                return "<redacted>".to_string();
            }

            if SENSITIVE_COMMAND_FLAGS.contains(arg) {
                redact_next = true;
                return (*arg).to_string();
            }

            for flag in SENSITIVE_COMMAND_FLAGS {
                if arg
                    .strip_prefix(flag)
                    .is_some_and(|suffix| suffix.starts_with('='))
                {
                    return format!("{flag}=<redacted>");
                }
            }

            (*arg).to_string()
        })
        .collect()
}

async fn run_cmd(cmd: &str, args: &[&str]) -> Result<String> {
    run_cmd_with_env(cmd, args, &[]).await
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
    image_digest: Option<&str>,
) -> Result<()> {
    let source_image = image_reference_for_pull(image, image_digest);
    let src = format!("docker://{source_image}");
    let dst = format!("oci:{}:latest", dest.display());

    // EIFs currently boot an x86_64 Linux kernel. Select that platform
    // explicitly so a multi-arch tag/index cannot resolve according to the
    // builder host (for example arm64 on an Apple Silicon development host).
    let mut args = vec![
        "copy",
        "--override-os",
        "linux",
        "--override-arch",
        "amd64",
        &src,
        &dst,
    ];

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

/// Return the registry reference skopeo should pull.
///
/// When the caller supplies the manifest digest recorded by the backend, put
/// it directly in the source reference. The registry transport then fetches
/// and content-verifies that digest instead of resolving a mutable tag while
/// the same (otherwise unrelated) digest is merely stamped into the EIF.
/// Skopeo does not accept a source reference containing both a tag and digest,
/// so remove an image tag before appending `@sha256:...`. A colon belonging to
/// the registry port is retained. Replace an existing digest rather than
/// producing two `@` components.
fn image_reference_for_pull(image: &str, image_digest: Option<&str>) -> String {
    match image_digest {
        Some(digest) => {
            let name_and_tag = image.split_once('@').map_or(image, |(name, _)| name);
            let last_slash = name_and_tag.rfind('/');
            let repository = match (name_and_tag.rfind(':'), last_slash) {
                (Some(colon), Some(slash)) if colon > slash => &name_and_tag[..colon],
                (Some(colon), None) => &name_and_tag[..colon],
                _ => name_and_tag,
            };
            format!("{repository}@{digest}")
        }
        None => image.to_string(),
    }
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

fn set_mode(path: &Path, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
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

    // Strip all mounts — without mount namespace, crun tries to mount in the
    // global namespace on initramfs, which fails for cgroups, devpts, bind-mounts
    // of /etc/resolv.conf, etc. Essential filesystems (proc, dev, sys, tmp) are
    // pre-mounted by the init script instead.
    if let Some(mounts) = config.pointer_mut("/mounts").and_then(|v| v.as_array_mut()) {
        let before = mounts.len();
        mounts.clear();
        if before > 0 {
            info!(removed = before, "stripped all mounts from OCI config");
        }
    }

    let patched = serde_json::to_string_pretty(&config)?;
    std::fs::write(&config_path, patched)?;
    set_mode(&config_path, 0o644)?;

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
    set_mode(&resolv, 0o644)?;
    info!("wrote /etc/resolv.conf in container rootfs");

    Ok(())
}

/// Remove umoci files that describe the build host rather than the runtime
/// bundle. The generated archive's `SOURCE_DATE_EPOCH` clamps all mtimes, so
/// timestamps no longer need to be rewritten through the unpacked tree (which
/// is important for images containing mode-000 directories).
fn strip_bundle_bookkeeping(dir: &Path) -> Result<()> {
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
    info!(
        ?dir,
        removed_bookkeeping = removed,
        "stripped umoci bookkeeping"
    );
    Ok(())
}

/// Move the bundle into the layout expected in the enclave's user initramfs.
/// `rename` keeps every rootfs inode and hardlink intact. The measured
/// Enclavia configuration and optional egress policy are also copied to their
/// outer-rootfs locations so the archive can be overlaid directly at boot.
fn stage_bundle_payload(bundle_dir: &Path, payload_dir: &Path) -> Result<()> {
    let bundle_dest = payload_dir.join("var/lib/oci/bundle");
    let enclavia_dir = payload_dir.join("etc/enclavia");

    std::fs::create_dir_all(bundle_dest.parent().expect("bundle has a parent"))?;
    std::fs::create_dir_all(&enclavia_dir)?;
    for dir in [
        payload_dir,
        &payload_dir.join("var"),
        &payload_dir.join("var/lib"),
        &payload_dir.join("var/lib/oci"),
        &payload_dir.join("etc"),
        &enclavia_dir,
    ] {
        set_mode(dir, 0o755)?;
    }

    let config_src = bundle_dir.join("enclavia-config.json");
    let config_dst = enclavia_dir.join("config.json");
    std::fs::copy(&config_src, &config_dst)?;
    set_mode(&config_dst, 0o644)?;

    let egress_src = bundle_dir.join("egress.json");
    if egress_src.is_file() {
        let egress_dst = enclavia_dir.join("egress.json");
        std::fs::copy(&egress_src, &egress_dst)?;
        set_mode(&egress_dst, 0o644)?;
    }

    std::fs::rename(bundle_dir, &bundle_dest)?;
    info!(?payload_dir, "staged OCI bundle payload");
    Ok(())
}

fn sha256_blob_path(layout: &Path, digest: &str) -> Result<PathBuf> {
    let hex = digest
        .strip_prefix("sha256:")
        .filter(|hex| hex.len() == 64)
        .filter(|hex| hex.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')))
        .ok_or_else(|| Error::OciArchive(format!("expected sha256 digest, got `{digest}`")))?;
    Ok(layout.join("blobs/sha256").join(hex))
}

/// Resolve the sole uncompressed layer produced by `umoci insert`.
fn generated_layer_path(layout: &Path) -> Result<PathBuf> {
    let index: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(layout.join("index.json"))?)?;
    let manifests = index
        .get("manifests")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| Error::OciArchive("index.json has no manifests array".into()))?;
    if manifests.len() != 1 {
        return Err(Error::OciArchive(format!(
            "expected one generated manifest, found {}",
            manifests.len()
        )));
    }
    let manifest_digest = manifests[0]
        .get("digest")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| Error::OciArchive("generated manifest has no digest".into()))?;
    let manifest: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(
        sha256_blob_path(layout, manifest_digest)?,
    )?)?;
    let layers = manifest
        .get("layers")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| Error::OciArchive("generated manifest has no layers array".into()))?;
    if layers.len() != 1 {
        return Err(Error::OciArchive(format!(
            "expected one generated layer, found {}",
            layers.len()
        )));
    }
    let media_type = layers[0]
        .get("mediaType")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| Error::OciArchive("generated layer has no mediaType".into()))?;
    if media_type != "application/vnd.oci.image.layer.v1.tar" {
        return Err(Error::OciArchive(format!(
            "expected an uncompressed OCI tar layer, got `{media_type}`"
        )));
    }
    let layer_digest = layers[0]
        .get("digest")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| Error::OciArchive("generated layer has no digest".into()))?;
    sha256_blob_path(layout, layer_digest)
}

/// Serialize the staged payload with umoci's OCI-aware tar generator.
///
/// A generic tar invocation would record the build user's ownership after a
/// rootless unpack. umoci understands `user.rootlesscontainers`, restores the
/// original container UID/GID in each tar header, preserves hardlinks and
/// supported xattrs, walks paths deterministically, and clamps timestamps via
/// SOURCE_DATE_EPOCH. Only the tar bytes cross the Nix path-input boundary.
async fn create_bundle_archive(
    payload_dir: &Path,
    archive_layout: &Path,
    input_dir: &Path,
) -> Result<()> {
    let image_arg = format!("{}:latest", archive_layout.display());
    run_cmd(
        "umoci",
        &["init", "--layout", &archive_layout.to_string_lossy()],
    )
    .await?;
    run_cmd("umoci", &["new", "--image", &image_arg]).await?;
    run_cmd_with_env(
        "umoci",
        &[
            "insert",
            "--rootless",
            "--compress=none",
            "--no-history",
            "--image",
            &image_arg,
            &payload_dir.to_string_lossy(),
            "/rootfs",
        ],
        &[("SOURCE_DATE_EPOCH", "1")],
    )
    .await?;

    let layer = generated_layer_path(archive_layout)?;
    std::fs::create_dir_all(input_dir)?;
    set_mode(input_dir, 0o755)?;
    let archive = input_dir.join("bundle.tar");
    std::fs::copy(&layer, &archive)?;
    set_mode(&archive, 0o644)?;
    info!(?archive, "created deterministic OCI bundle archive");
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
    bundle_input_dir: &Path,
    result_link: &Path,
    debug: bool,
    storage: bool,
) -> Result<()> {
    let bundle_arg = format!("path:{}", bundle_input_dir.display());
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

/// Validate that a base64-encoded ECDSA P-256 public key decodes to
/// exactly 65 bytes with the uncompressed SEC1 prefix `0x04` (#47). We
/// don't verify it's a valid curve point — `enclavia-server` re-parses
/// it via `p256::ecdsa::VerifyingKey::from_sec1_bytes` at boot, which
/// catches that. The cheap shape-only check keeps a malformed pubkey
/// from making it into the EIF in the first place.
fn validate_control_pubkey(b64: &str) -> std::result::Result<(), String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64.as_bytes())
        .map_err(|e| format!("invalid base64: {e}"))?;
    if bytes.len() != 65 {
        return Err(format!(
            "expected 65 bytes (uncompressed SEC1 ECDSA P-256 public key), got {}",
            bytes.len()
        ));
    }
    if bytes[0] != 0x04 {
        return Err(format!(
            "expected uncompressed SEC1 prefix 0x04, got 0x{:02x}",
            bytes[0]
        ));
    }
    Ok(())
}

/// Light shape check for the `--image-digest` flag (#47). The registry's
/// manifest digest is the canonical `sha256:[0-9a-f]{64}` form; we accept
/// only that prefix and the right hex length. Refusing anything else
/// keeps a malformed digest from getting baked into the EIF where it
/// would surface as a chain-validation failure later. When present, the
/// digest is also used as the skopeo source reference, so the registry
/// transport content-verifies the same manifest that we stamp into the EIF.
fn validate_image_digest(s: &str) -> std::result::Result<(), String> {
    let rest = s
        .strip_prefix("sha256:")
        .ok_or_else(|| format!("expected `sha256:<hex>` prefix, got `{s}`"))?;
    if rest.len() != 64 {
        return Err(format!(
            "expected 64-hex-char digest after `sha256:`, got {} chars",
            rest.len()
        ));
    }
    if !rest.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        return Err("digest body must be lowercase hex (`0-9a-f`)".into());
    }
    Ok(())
}

/// Shape check for one PCR hex value inside `--synchronizer-pcrs`. Both
/// real Nitro measurements and the deterministic FakeAttestor used in
/// QEMU dev clusters are SHA-384-sized (48 bytes), so a valid value is
/// exactly 96 lowercase hex chars. The in-enclave nbd-client
/// hex-decodes these at boot and FAIL-STOPS on anything malformed, so
/// rejecting bad values here keeps a broken trust anchor from getting
/// measured into an EIF that can then never serve storage.
fn validate_pcr_hex(label: &str, s: &str) -> std::result::Result<(), String> {
    if s.len() != 96 {
        return Err(format!(
            "{label}: expected 96 hex chars (48-byte SHA-384 measurement), got {}",
            s.len()
        ));
    }
    if !s.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        return Err(format!("{label}: must be lowercase hex (`0-9a-f`)"));
    }
    Ok(())
}

/// Parse and validate the `--synchronizer-pcrs` flag (enclavia#208).
///
/// The argument is inline JSON when it starts with `{` or `[` (after
/// trimming), otherwise it is treated as a path to a JSON file. The
/// JSON itself is either a single `{"PCR0","PCR1","PCR2"}` hex triple
/// (the builder's own pcr.json shape, normalized to a one-element
/// list) or a non-empty array of such triples (several oracle images
/// accepted at once, e.g. across a synchronizer upgrade window).
///
/// The returned list is exactly what gets serialized under
/// `synchronizer.expected_pcrs` in `enclavia-config.json`; the key
/// names (`PCR0`/`PCR1`/`PCR2`) match the `PcrsHex` wire shape the
/// in-enclave nbd-client deserializes.
fn parse_synchronizer_pcrs(arg: &str) -> std::result::Result<Vec<PcrValues>, String> {
    let trimmed = arg.trim();
    let json = if trimmed.starts_with('{') || trimmed.starts_with('[') {
        trimmed.to_string()
    } else {
        std::fs::read_to_string(trimmed)
            .map_err(|e| format!("cannot read synchronizer PCR file `{trimmed}`: {e}"))?
    };

    let value: serde_json::Value =
        serde_json::from_str(&json).map_err(|e| format!("invalid JSON: {e}"))?;
    let triples: Vec<PcrValues> = if value.is_array() {
        serde_json::from_value(value)
            .map_err(|e| format!("expected a list of {{PCR0,PCR1,PCR2}} triples: {e}"))?
    } else {
        let one: PcrValues = serde_json::from_value(value)
            .map_err(|e| format!("expected a {{PCR0,PCR1,PCR2}} triple: {e}"))?;
        vec![one]
    };

    if triples.is_empty() {
        return Err(
            "expected at least one PCR triple; an empty list would make the in-enclave \
             nbd-client fail-stop at boot (unverifiable oracle)"
                .into(),
        );
    }
    for (i, t) in triples.iter().enumerate() {
        validate_pcr_hex(&format!("expected_pcrs[{i}].PCR0"), &t.pcr0)?;
        validate_pcr_hex(&format!("expected_pcrs[{i}].PCR1"), &t.pcr1)?;
        validate_pcr_hex(&format!("expected_pcrs[{i}].PCR2"), &t.pcr2)?;
    }
    Ok(triples)
}

/// Write the measured Enclavia config into the bundle. Payload staging also
/// copies it to `/etc/enclavia/config.json` in the outer initramfs layout.
#[allow(clippy::too_many_arguments)]
fn write_enclavia_config(
    bundle_dir: &Path,
    container_port: u16,
    debug: bool,
    storage: bool,
    control_pubkey: Option<&str>,
    enclave_id: Option<&str>,
    image_digest: Option<&str>,
    synchronizer_pcrs: Option<&[PcrValues]>,
    synchronizer_enabled: bool,
    min_upgrade_delay_secs: Option<u64>,
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

    // image_digest is consumed by the in-enclave chain-init helper (#47).
    // The field stays absent when the caller didn't pass one so older
    // callers and the `cargo run -- build ...` dev loop keep working.
    if let Some(digest) = image_digest {
        config["image_digest"] = serde_json::Value::String(digest.to_string());
    }

    // Synchronizer trust anchors (enclavia#208). `expected_pcrs` is the
    // set of oracle measurements the in-enclave nbd-client will accept
    // when the anti-rollback wiring is enabled; `debug_attestation`
    // mirrors the build mode (QEMU's self-signing NSM in --debug, the
    // full AWS Nitro CA chain otherwise). Both are part of the trust
    // decision, which is exactly why they live in this file: it ends up
    // at /etc/enclavia/config.json inside the measured rootfs, so the
    // host can't substitute its own oracle. Absent when the caller
    // didn't pass --synchronizer-pcrs (enclaves without synchronizer
    // pinning keep today's config byte-for-byte).
    if let Some(pcrs) = synchronizer_pcrs {
        config["synchronizer"] = serde_json::json!({
            "enabled": synchronizer_enabled,
            "expected_pcrs": pcrs,
            "debug_attestation": debug,
        });
    }

    // Minimum upgrade activation delay (enclavia-crates#205). Measured
    // into PCR2 like control_public_key, so the host can't shorten it
    // after creation. Explicit 0 is treated the same as absent so the
    // config bytes stay identical for existing enclaves.
    if let Some(d) = min_upgrade_delay_secs {
        if d > 0 {
            config["min_upgrade_delay_secs"] = d.into();
        }
    }

    let path = bundle_dir.join("enclavia-config.json");
    std::fs::write(&path, serde_json::to_string_pretty(&config).unwrap())?;
    set_mode(&path, 0o644)?;
    info!(
        container_port,
        storage,
        control_channel = control_pubkey.is_some(),
        has_enclave_id = enclave_id.is_some(),
        has_image_digest = image_digest.is_some(),
        synchronizer_pcr_sets = synchronizer_pcrs.map(<[_]>::len).unwrap_or(0),
        synchronizer_enabled,
        min_upgrade_delay_secs = min_upgrade_delay_secs.unwrap_or(0),
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
    image_digest: Option<&str>,
    egress_allowlist: Option<&Path>,
    synchronizer_pcrs: Option<&[PcrValues]>,
    synchronizer_enabled: bool,
    min_upgrade_delay_secs: Option<u64>,
) -> Result<BuildResult> {
    let tmp = tempfile::tempdir()?;
    let tmp_path = tmp.path();

    let oci_layout = tmp_path.join("image");
    let bundle_dir = tmp_path.join("bundle");
    let payload_dir = tmp_path.join("payload");
    let archive_layout = tmp_path.join("bundle-archive-image");
    let bundle_input_dir = tmp_path.join("bundle-input");
    let result_link = tmp_path.join("result");

    // 1. Pull the Docker image
    info!(image, "pulling image");
    pull_image(image, &oci_layout, creds, registry_token, image_digest).await?;

    // 2. Unpack into OCI bundle
    info!("unpacking OCI bundle");
    unpack_bundle(&oci_layout, &bundle_dir).await?;

    // 3. Patch OCI config for enclave compatibility
    patch_bundle_config(&bundle_dir)?;

    // 4. Write enclavia config into bundle
    write_enclavia_config(
        &bundle_dir,
        container_port,
        debug,
        storage,
        control_pubkey,
        enclave_id,
        image_digest,
        synchronizer_pcrs,
        synchronizer_enabled,
        min_upgrade_delay_secs,
    )?;

    // 4b. If the caller supplied an egress allowlist, drop it into the
    // bundle at a fixed name. Payload staging also copies it to the archive's
    // `/etc/enclavia/egress.json` location.
    // The file content is hashed into the EIF, so changing it changes
    // PCR2 (rootfs) and is visible via `enclavia reproduce`.
    if let Some(src) = egress_allowlist {
        let dst = bundle_dir.join("egress.json");
        std::fs::copy(src, &dst)?;
        set_mode(&dst, 0o644)?;
        info!(src = ?src, dst = ?dst, "copied egress allowlist into bundle");
    }

    // 5. Remove host bookkeeping, then move the still-intact bundle tree into
    // its final initramfs layout. No recursive copy occurs here: OCI hardlinks
    // remain hardlinks until umoci serializes them below.
    strip_bundle_bookkeeping(&bundle_dir)?;
    stage_bundle_payload(&bundle_dir, &payload_dir)?;

    // 6. Serialize the payload into a deterministic OCI tar. Nix receives a
    // directory containing only this regular file, so NAR canonicalisation can
    // no longer reinterpret the customer filesystem's metadata.
    create_bundle_archive(&payload_dir, &archive_layout, &bundle_input_dir).await?;

    // 7. Build the EIF
    info!(storage, "building enclave image");
    build_eif(&bundle_input_dir, &result_link, debug, storage).await?;

    // 8. Read PCR values
    let pcrs = read_pcrs(&result_link)?;
    info!(pcr0 = %pcrs.pcr0, pcr1 = %pcrs.pcr1, pcr2 = %pcrs.pcr2, "PCR values");

    // 9. Copy artifacts to output
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
            image_digest,
            egress_allowlist,
            synchronizer_pcrs,
            synchronizer_enabled,
            min_upgrade_delay_secs,
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

            if let Some(ref d) = image_digest {
                if let Err(e) = validate_image_digest(d) {
                    error!(%e, "--image-digest rejected");
                    std::process::exit(2);
                }
            }

            let synchronizer_pcrs = match synchronizer_pcrs.as_deref() {
                Some(arg) => match parse_synchronizer_pcrs(arg) {
                    Ok(triples) => Some(triples),
                    Err(e) => {
                        error!(%e, "--synchronizer-pcrs rejected");
                        std::process::exit(2);
                    }
                },
                None => None,
            };

            // Enabling the wiring without expected oracle PCRs would
            // make the in-enclave nbd-client fail-stop at every boot
            // (unverifiable oracle), so refuse the combination here.
            if synchronizer_enabled && synchronizer_pcrs.is_none() {
                error!(
                    "--synchronizer-enabled requires --synchronizer-pcrs (the in-enclave \
                     nbd-client fail-stops at boot with no expected oracle PCRs)"
                );
                std::process::exit(2);
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
                image_digest.as_deref(),
                egress_allowlist.as_deref(),
                synchronizer_pcrs.as_deref(),
                synchronizer_enabled,
                min_upgrade_delay_secs,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_log_redacts_separate_registry_secret_values() {
        let args = [
            "copy",
            "--src-creds",
            "alice:hunter2",
            "--src-registry-token",
            "signed-bearer-token",
            "docker://registry.example/app:v1",
            "oci:/tmp/image:latest",
        ];
        assert_eq!(
            redact_command_args(&args),
            vec![
                "copy",
                "--src-creds",
                "<redacted>",
                "--src-registry-token",
                "<redacted>",
                "docker://registry.example/app:v1",
                "oci:/tmp/image:latest",
            ]
        );
    }

    #[test]
    fn command_log_redacts_equals_form_registry_secret_values() {
        let args = [
            "copy",
            "--src-password=hunter2",
            "--dest-registry-token=signed-bearer-token",
        ];
        assert_eq!(
            redact_command_args(&args),
            vec![
                "copy",
                "--src-password=<redacted>",
                "--dest-registry-token=<redacted>",
            ]
        );
    }

    #[test]
    fn command_log_preserves_non_secret_arguments() {
        let args = [
            "build",
            "path:/builder#enclave",
            "--override-input",
            "oci-bundle",
            "path:/tmp/bundle",
        ];
        assert_eq!(redact_command_args(&args), args.map(String::from));
    }

    #[test]
    fn image_digest_accepts_canonical_sha256() {
        let d = format!("sha256:{}", "0".repeat(64));
        assert!(validate_image_digest(&d).is_ok());
        let d = format!("sha256:{}", "abcdef0123456789".repeat(4));
        assert!(validate_image_digest(&d).is_ok());
    }

    #[test]
    fn image_digest_rejects_missing_prefix() {
        let d = "0".repeat(64);
        assert!(validate_image_digest(&d).is_err());
    }

    #[test]
    fn image_digest_rejects_wrong_length() {
        let d = format!("sha256:{}", "0".repeat(63));
        assert!(validate_image_digest(&d).is_err());
        let d = format!("sha256:{}", "0".repeat(65));
        assert!(validate_image_digest(&d).is_err());
    }

    #[test]
    fn image_digest_rejects_uppercase_hex() {
        let d = format!("sha256:{}", "A".repeat(64));
        assert!(validate_image_digest(&d).is_err());
    }

    #[test]
    fn image_digest_rejects_non_hex() {
        let d = format!("sha256:{}", "g".repeat(64));
        assert!(validate_image_digest(&d).is_err());
    }

    #[test]
    fn image_reference_without_digest_keeps_original_reference() {
        assert_eq!(
            image_reference_for_pull("registry.example/app:latest", None),
            "registry.example/app:latest"
        );
    }

    #[test]
    fn image_reference_with_digest_pins_tagged_image() {
        let digest = format!("sha256:{}", "a".repeat(64));
        assert_eq!(
            image_reference_for_pull("registry.example:5000/team/app:v1", Some(&digest)),
            format!("registry.example:5000/team/app@{digest}")
        );
    }

    #[test]
    fn image_reference_with_digest_preserves_registry_port() {
        let digest = format!("sha256:{}", "a".repeat(64));
        assert_eq!(
            image_reference_for_pull("registry.example:5000/team/app", Some(&digest)),
            format!("registry.example:5000/team/app@{digest}")
        );
    }

    #[test]
    fn image_reference_with_digest_replaces_existing_digest() {
        let old_digest = format!("sha256:{}", "1".repeat(64));
        let new_digest = format!("sha256:{}", "2".repeat(64));
        assert_eq!(
            image_reference_for_pull(
                &format!("registry.example/app@{old_digest}"),
                Some(&new_digest)
            ),
            format!("registry.example/app@{new_digest}")
        );
    }

    // --- synchronizer trust anchors (enclavia#208) ----------------------

    fn triple(seed: char) -> PcrValues {
        PcrValues {
            pcr0: seed.to_string().repeat(96),
            pcr1: "1".repeat(96),
            pcr2: "2".repeat(96),
        }
    }

    fn triple_json(seed: char) -> String {
        serde_json::to_string(&triple(seed)).unwrap()
    }

    #[test]
    fn pcr_hex_accepts_sha384_lowercase() {
        assert!(validate_pcr_hex("PCR0", &"a".repeat(96)).is_ok());
        assert!(validate_pcr_hex("PCR0", &"0123456789abcdef".repeat(6)).is_ok());
    }

    #[test]
    fn pcr_hex_rejects_wrong_length_case_and_non_hex() {
        assert!(validate_pcr_hex("PCR0", &"a".repeat(95)).is_err());
        assert!(validate_pcr_hex("PCR0", &"a".repeat(97)).is_err());
        assert!(validate_pcr_hex("PCR0", "").is_err());
        assert!(validate_pcr_hex("PCR0", &"A".repeat(96)).is_err());
        assert!(validate_pcr_hex("PCR0", &"g".repeat(96)).is_err());
    }

    #[test]
    fn synchronizer_pcrs_inline_single_triple_normalizes_to_list() {
        let parsed = parse_synchronizer_pcrs(&triple_json('a')).unwrap();
        assert_eq!(parsed, vec![triple('a')]);
    }

    #[test]
    fn synchronizer_pcrs_inline_list() {
        let json = format!("[{},{}]", triple_json('a'), triple_json('b'));
        let parsed = parse_synchronizer_pcrs(&json).unwrap();
        assert_eq!(parsed, vec![triple('a'), triple('b')]);
    }

    #[test]
    fn synchronizer_pcrs_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pcr.json");
        std::fs::write(&path, triple_json('c')).unwrap();
        let parsed = parse_synchronizer_pcrs(path.to_str().unwrap()).unwrap();
        assert_eq!(parsed, vec![triple('c')]);
    }

    #[test]
    fn synchronizer_pcrs_missing_file_is_rejected() {
        assert!(parse_synchronizer_pcrs("/nonexistent/pcr.json").is_err());
    }

    #[test]
    fn synchronizer_pcrs_empty_list_is_rejected() {
        // An empty expected_pcrs list would make the in-enclave
        // nbd-client fail-stop at boot; refuse it at build time.
        assert!(parse_synchronizer_pcrs("[]").is_err());
    }

    #[test]
    fn synchronizer_pcrs_invalid_json_and_shapes_are_rejected() {
        assert!(parse_synchronizer_pcrs("{not json").is_err());
        assert!(parse_synchronizer_pcrs(r#"{"PCR0": "aa"}"#).is_err());
        // Valid shape, bad hex.
        let bad = format!(
            r#"{{"PCR0": "{}", "PCR1": "{}", "PCR2": "{}"}}"#,
            "z".repeat(96),
            "1".repeat(96),
            "2".repeat(96)
        );
        assert!(parse_synchronizer_pcrs(&bad).is_err());
    }

    // --- enclavia-config.json generation ---------------------------------

    fn written_config(
        debug: bool,
        storage: bool,
        synchronizer_pcrs: Option<&[PcrValues]>,
        synchronizer_enabled: bool,
    ) -> serde_json::Value {
        written_config_with_delay(
            debug,
            storage,
            synchronizer_pcrs,
            synchronizer_enabled,
            None,
        )
    }

    fn written_config_with_delay(
        debug: bool,
        storage: bool,
        synchronizer_pcrs: Option<&[PcrValues]>,
        synchronizer_enabled: bool,
        min_upgrade_delay_secs: Option<u64>,
    ) -> serde_json::Value {
        let dir = tempfile::tempdir().unwrap();
        write_enclavia_config(
            dir.path(),
            8080,
            debug,
            storage,
            None,
            Some("enclave-uuid"),
            None,
            synchronizer_pcrs,
            synchronizer_enabled,
            min_upgrade_delay_secs,
        )
        .unwrap();
        let content = std::fs::read_to_string(dir.path().join("enclavia-config.json")).unwrap();
        serde_json::from_str(&content).unwrap()
    }

    #[test]
    fn config_has_no_synchronizer_section_when_flag_absent() {
        // Enclaves built without --synchronizer-pcrs must keep today's
        // config shape (and therefore today's PCRs for unchanged inputs).
        let config = written_config(false, true, None, false);
        assert!(config.get("synchronizer").is_none());
        assert_eq!(config["storage"]["enabled"], serde_json::json!(true));
    }

    #[test]
    fn config_synchronizer_section_matches_nbd_client_contract() {
        // The exact key names nbd-client's RawSynchronizerSection /
        // PcrsHex deserialize: synchronizer.expected_pcrs[].PCR{0,1,2}
        // plus synchronizer.debug_attestation.
        let triples = vec![triple('a'), triple('b')];
        let config = written_config(false, true, Some(&triples), false);
        let section = &config["synchronizer"];
        assert_eq!(section["debug_attestation"], serde_json::json!(false));
        let expected = section["expected_pcrs"].as_array().unwrap();
        assert_eq!(expected.len(), 2);
        assert_eq!(expected[0]["PCR0"], serde_json::json!("a".repeat(96)));
        assert_eq!(expected[0]["PCR1"], serde_json::json!("1".repeat(96)));
        assert_eq!(expected[0]["PCR2"], serde_json::json!("2".repeat(96)));
        assert_eq!(expected[1]["PCR0"], serde_json::json!("b".repeat(96)));
        // Round-trip through the same serde shape nbd-client uses.
        let round: Vec<PcrValues> =
            serde_json::from_value(section["expected_pcrs"].clone()).unwrap();
        assert_eq!(round, triples);
    }

    #[test]
    fn config_debug_attestation_mirrors_debug_flag() {
        let triples = vec![triple('a')];
        let config = written_config(true, true, Some(&triples), false);
        assert_eq!(
            config["synchronizer"]["debug_attestation"],
            serde_json::json!(true)
        );
    }

    #[test]
    fn config_base_fields_survive_synchronizer_section() {
        let triples = vec![triple('a')];
        let config = written_config(false, false, Some(&triples), false);
        assert_eq!(config["listen_vsock_port"], serde_json::json!(5000));
        assert_eq!(config["enclave_id"], serde_json::json!("enclave-uuid"));
        assert!(config.get("storage").is_none());
    }

    #[test]
    fn config_synchronizer_enabled_flag_is_written() {
        let triples = vec![triple('a')];
        // Anchors baked but wiring OFF: enabled defaults false, so the
        // EIF init does not export SYNCHRONIZER_ENABLED.
        let off = written_config(false, true, Some(&triples), false);
        assert_eq!(off["synchronizer"]["enabled"], serde_json::json!(false));
        // Wiring ON: init reads `synchronizer.enabled == true` and
        // exports SYNCHRONIZER_ENABLED=1 for nbd-client.
        let on = written_config(false, true, Some(&triples), true);
        assert_eq!(on["synchronizer"]["enabled"], serde_json::json!(true));
    }

    #[test]
    fn config_min_upgrade_delay_written_when_set() {
        // The exact key the in-enclave server reads (enclavia-crates#205).
        let config = written_config_with_delay(false, false, None, false, Some(86400));
        assert_eq!(
            config["min_upgrade_delay_secs"],
            serde_json::json!(86400u64)
        );
    }

    #[test]
    fn config_min_upgrade_delay_absent_when_none_or_zero() {
        // None and explicit 0 must both leave the field out, so config
        // bytes stay identical for existing enclaves (stable PCR2).
        let none = written_config_with_delay(false, false, None, false, None);
        assert!(none.get("min_upgrade_delay_secs").is_none());
        let zero = written_config_with_delay(false, false, None, false, Some(0));
        assert!(zero.get("min_upgrade_delay_secs").is_none());
        assert_eq!(none, zero);
    }

    #[test]
    fn patch_bundle_preserves_image_capability_sets() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("rootfs/etc")).unwrap();
        let capabilities = serde_json::json!({
            "bounding": ["CAP_NET_BIND_SERVICE"],
            "effective": ["CAP_NET_BIND_SERVICE"],
            "inheritable": [],
            "permitted": ["CAP_NET_BIND_SERVICE"],
            "ambient": []
        });
        let config = serde_json::json!({
            "hostname": "rootless-host",
            "process": { "terminal": true, "capabilities": capabilities },
            "linux": {
                "namespaces": [{"type": "user"}],
                "uidMappings": [{"containerID": 0, "hostID": 1000, "size": 1}],
                "gidMappings": [{"containerID": 0, "hostID": 1000, "size": 1}]
            },
            "mounts": [{"destination": "/proc", "type": "proc", "source": "proc"}]
        });
        std::fs::write(
            tmp.path().join("config.json"),
            serde_json::to_vec(&config).unwrap(),
        )
        .unwrap();

        patch_bundle_config(tmp.path()).unwrap();

        let patched: serde_json::Value =
            serde_json::from_slice(&std::fs::read(tmp.path().join("config.json")).unwrap())
                .unwrap();
        assert_eq!(patched["process"]["capabilities"], capabilities);
        assert_eq!(patched["process"]["terminal"], serde_json::json!(false));
        assert_eq!(patched["linux"]["namespaces"], serde_json::json!([]));
        assert!(patched["linux"].get("uidMappings").is_none());
        assert!(patched["linux"].get("gidMappings").is_none());
        assert!(patched.get("hostname").is_none());
        assert_eq!(patched["mounts"], serde_json::json!([]));
    }

    #[test]
    fn staging_preserves_hardlinks_and_places_measured_config() {
        use std::os::unix::fs::MetadataExt;

        let tmp = tempfile::tempdir().unwrap();
        let bundle = tmp.path().join("bundle");
        let rootfs = bundle.join("rootfs");
        let payload = tmp.path().join("payload");
        std::fs::create_dir_all(rootfs.join("bin")).unwrap();

        std::fs::write(rootfs.join("bin/busybox"), b"BUSYBOX").unwrap();
        std::fs::hard_link(rootfs.join("bin/busybox"), rootfs.join("bin/ls")).unwrap();
        std::fs::write(bundle.join("config.json"), b"{}").unwrap();
        std::fs::write(
            bundle.join("enclavia-config.json"),
            b"{\"listen_vsock_port\":5000}",
        )
        .unwrap();
        std::fs::write(bundle.join("egress.json"), b"{\"version\":1}").unwrap();

        stage_bundle_payload(&bundle, &payload).unwrap();

        assert!(!bundle.exists());
        let staged_rootfs = payload.join("var/lib/oci/bundle/rootfs");
        let busybox = staged_rootfs.join("bin/busybox");
        let ls = staged_rootfs.join("bin/ls");
        let busybox_meta = busybox.metadata().unwrap();
        let ls_meta = ls.metadata().unwrap();
        assert_eq!(busybox_meta.ino(), ls_meta.ino());
        assert_eq!(busybox_meta.nlink(), 2);
        assert!(!ls.symlink_metadata().unwrap().file_type().is_symlink());
        assert_eq!(
            std::fs::read(payload.join("etc/enclavia/config.json")).unwrap(),
            b"{\"listen_vsock_port\":5000}"
        );
        assert_eq!(
            std::fs::read(payload.join("etc/enclavia/egress.json")).unwrap(),
            b"{\"version\":1}"
        );
    }
}
