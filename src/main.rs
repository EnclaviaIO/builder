use std::path::{Path, PathBuf};
use std::process::Stdio;

use clap::Parser;
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tracing::{error, info};

#[derive(Debug, thiserror::Error)]
enum Error {
    #[error("command `{cmd}` failed with status {status}:\n{stderr}")]
    Command {
        cmd: String,
        status: std::process::ExitStatus,
        stderr: String,
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

    let output = Command::new(cmd)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?
        .wait_with_output()
        .await?;

    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    if !stderr.is_empty() {
        info!(cmd, stderr = %stderr.trim(), "command stderr");
    }

    if !output.status.success() {
        return Err(Error::Command {
            cmd: cmd.to_string(),
            status: output.status,
            stderr,
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

    // Ensure /etc/resolv.conf exists in the container rootfs.
    // Docker normally bind-mounts this, but crun on initramfs doesn't.
    // Without it, some images (e.g. nginx) fail to start.
    let resolv = bundle_dir.join("rootfs/etc/resolv.conf");
    if !resolv.exists() {
        std::fs::create_dir_all(bundle_dir.join("rootfs/etc"))?;
        std::fs::write(&resolv, "nameserver 127.0.0.1\n")?;
        info!("created missing /etc/resolv.conf in container rootfs");
    }

    Ok(())
}

/// Build the enclave EIF using nix, overriding the oci-bundle input.
///
/// In production the deployment also overrides `enclavia-crates` with a
/// pinned source path via the `ENCLAVIA_CRATES_FLAKE` env var; in dev the
/// flake's default (`./dummy-enclavia-crates`) is replaced by passing
/// `--override-input enclavia-crates path:/path/to/enclavia-crates` to the
/// QEMU wrapper.
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

    // ENCLAVIA_CRATES_FLAKE — production-side override so the in-enclave
    // binaries (enclavia-server, enclavia-crypto, nbd-client, mock-kms)
    // come from the deployment's pinned `inputs.enclavia-crates` rather
    // than the dummy stub baked into the builder flake.
    if let Some(p) = std::env::var_os("ENCLAVIA_CRATES_FLAKE") {
        args.push("--override-input".into());
        args.push("enclavia-crates".into());
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

    let path = bundle_dir.join("enclavia-config.json");
    std::fs::write(&path, serde_json::to_string_pretty(&config).unwrap())?;
    info!(
        container_port,
        storage,
        control_channel = control_pubkey.is_some(),
        "wrote enclavia config"
    );
    Ok(())
}

async fn build(
    image: &str,
    creds: Option<(&str, &str)>,
    registry_token: Option<&str>,
    output_dir: &Path,
    container_port: u16,
    debug: bool,
    storage: bool,
    control_pubkey: Option<&str>,
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
    write_enclavia_config(&bundle_dir, container_port, storage, control_pubkey)?;

    // 5. Build the EIF
    info!(storage, "building enclave image");
    build_eif(&bundle_dir, &result_link, debug, storage).await?;

    // 6. Read PCR values
    let pcrs = read_pcrs(&result_link)?;
    info!(pcr0 = %pcrs.pcr0, pcr1 = %pcrs.pcr1, pcr2 = %pcrs.pcr2, "PCR values");

    // 7. Copy artifacts to output
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
