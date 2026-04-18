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
/// Removes the "mount" namespace from the OCI config because the enclave runs on
/// an initramfs rootfs that doesn't support mount propagation changes (EINVAL).
/// This is safe because there's only a single container inside the enclave.
fn patch_bundle_config(bundle_dir: &Path) -> Result<()> {
    let config_path = bundle_dir.join("config.json");
    let content = std::fs::read_to_string(&config_path)?;
    let mut config: serde_json::Value = serde_json::from_str(&content)?;

    if let Some(namespaces) = config
        .pointer_mut("/linux/namespaces")
        .and_then(|v| v.as_array_mut())
    {
        let before = namespaces.len();
        namespaces.retain(|ns| {
            ns.get("type").and_then(|t| t.as_str()) != Some("mount")
        });
        let removed = before - namespaces.len();
        if removed > 0 {
            info!(removed, "stripped mount namespace(s) from OCI config");
        }
    }

    let patched = serde_json::to_string_pretty(&config)?;
    std::fs::write(&config_path, patched)?;
    Ok(())
}

/// Build the enclave EIF using nix, overriding the oci-bundle and enclavia-server inputs.
async fn build_eif(
    bundle_dir: &Path,
    enclavia_server_dir: &Path,
    result_link: &Path,
) -> Result<()> {
    let bundle_arg = format!("path:{}", bundle_dir.display());
    let server_arg = format!("path:{}", enclavia_server_dir.display());
    let out_arg = result_link.to_string_lossy();

    run_cmd(
        "nix",
        &[
            "build",
            ".#enclave",
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

async fn build(
    image: &str,
    creds: Option<(&str, &str)>,
    enclavia_server_dir: &Path,
    output_dir: &Path,
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

    // 4. Build the EIF
    info!("building enclave image");
    build_eif(&bundle_dir, &enclavia_server_abs, &result_link).await?;

    // 5. Read PCR values
    let pcrs = read_pcrs(&result_link)?;
    info!(pcr0 = %pcrs.pcr0, pcr1 = %pcrs.pcr1, pcr2 = %pcrs.pcr2, "PCR values");

    // 6. Copy artifacts to output
    copy_artifacts(&result_link, output_dir)?;

    Ok(BuildResult {
        eif_path: output_dir.join("image.eif"),
        pcrs,
    })
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
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
        } => {
            let creds = match (&registry_user, &registry_password) {
                (Some(u), Some(p)) => Some((u.as_str(), p.as_str())),
                _ => None,
            };

            match build(&image, creds, &enclavia_server_dir, &output_dir).await {
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
