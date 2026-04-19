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

        /// Path to the enclavia-server source directory
        #[arg(long, default_value = "../enclavia-server")]
        enclavia_server_dir: PathBuf,

        /// Directory to write output artifacts (image.eif, pcr.json)
        #[arg(long, default_value = "./out")]
        output_dir: PathBuf,

        /// Port the customer's container listens on inside the enclave
        #[arg(long, default_value = "8080")]
        container_port: u16,

        /// Build for debug mode (QEMU with patched init using CID 2)
        #[arg(long)]
        debug: bool,
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
async fn pull_image(image: &str, dest: &Path, creds: Option<(&str, &str)>) -> Result<()> {
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

/// Build the enclave EIF using nix, overriding the oci-bundle and enclavia-server inputs.
async fn build_eif(
    bundle_dir: &Path,
    enclavia_server_dir: &Path,
    result_link: &Path,
    debug: bool,
) -> Result<()> {
    let bundle_arg = format!("path:{}", bundle_dir.display());
    let server_arg = format!("path:{}", enclavia_server_dir.display());
    let out_arg = result_link.to_string_lossy();

    // Resolve the builder's own directory so `nix build` finds the correct flake
    // regardless of the working directory.
    let builder_dir = std::env::current_exe()?
        .parent()
        .and_then(|p| p.parent()) // target/release -> target -> builder root
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));
    let target = if debug { "enclave-debug" } else { "enclave" };
    let flake_ref = format!("{}#{}", builder_dir.display(), target);

    run_cmd(
        "nix",
        &[
            "build",
            &flake_ref,
            "--override-input",
            "oci-bundle",
            &bundle_arg,
            "--override-input",
            "enclavia-server",
            &server_arg,
            "-o",
            &out_arg,
        ],
    )
    .await?;

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

/// Write the enclavia config into the bundle so enclave.nix picks it up.
fn write_enclavia_config(bundle_dir: &Path, container_port: u16) -> Result<()> {
    let config = serde_json::json!({
        "listen_vsock_port": 5000,
        "oci_bundle_path": "/var/lib/oci/bundle",
        "customer_app": {
            "port": container_port,
            "health_check": "/health",
            "startup_timeout_secs": 30
        }
    });
    let path = bundle_dir.join("enclavia-config.json");
    std::fs::write(&path, serde_json::to_string_pretty(&config).unwrap())?;
    info!(container_port, "wrote enclavia config");
    Ok(())
}

async fn build(
    image: &str,
    creds: Option<(&str, &str)>,
    enclavia_server_dir: &Path,
    output_dir: &Path,
    container_port: u16,
    debug: bool,
) -> Result<BuildResult> {
    let tmp = tempfile::tempdir()?;
    let tmp_path = tmp.path();

    let oci_layout = tmp_path.join("image");
    let bundle_dir = tmp_path.join("bundle");
    let result_link = tmp_path.join("result");

    // Resolve enclavia-server to an absolute path for nix --override-input
    let enclavia_server_abs = std::fs::canonicalize(enclavia_server_dir).map_err(|e| {
        Error::Io(std::io::Error::new(
            e.kind(),
            format!("enclavia-server dir '{}': {e}", enclavia_server_dir.display()),
        ))
    })?;

    // 1. Pull the Docker image
    info!(image, "pulling image");
    pull_image(image, &oci_layout, creds).await?;

    // 2. Unpack into OCI bundle
    info!("unpacking OCI bundle");
    unpack_bundle(&oci_layout, &bundle_dir).await?;

    // 3. Patch OCI config for enclave compatibility
    patch_bundle_config(&bundle_dir)?;

    // 4. Write enclavia config into bundle
    write_enclavia_config(&bundle_dir, container_port)?;

    // 5. Build the EIF
    info!("building enclave image");
    build_eif(&bundle_dir, &enclavia_server_abs, &result_link, debug).await?;

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
            enclavia_server_dir,
            output_dir,
            container_port,
            debug,
        } => {
            let creds = match (&registry_user, &registry_password) {
                (Some(u), Some(p)) => Some((u.as_str(), p.as_str())),
                _ => None,
            };

            match build(&image, creds, &enclavia_server_dir, &output_dir, container_port, debug).await {
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
