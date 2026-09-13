use anyhow::{anyhow, Context as _};
use aya_build::Toolchain;

// Keep in sync with the `channel` in ../rust-toolchain.toml — see the
// comment there for why this is pinned to a specific date rather than
// plain "nightly".
const EBPF_TOOLCHAIN: &str = "nightly-2026-07-01";

fn main() -> anyhow::Result<()> {
    let cargo_metadata::Metadata { packages, .. } = cargo_metadata::MetadataCommand::new()
        .no_deps()
        .exec()
        .context("MetadataCommand::exec")?;
    let ebpf_package = packages
        .into_iter()
        .find(|cargo_metadata::Package { name, .. }| name.as_str() == "omablinker-bpfd-ebpf")
        .ok_or_else(|| anyhow!("omablinker-bpfd-ebpf package not found"))?;
    let cargo_metadata::Package {
        name,
        manifest_path,
        ..
    } = ebpf_package;
    let ebpf_package = aya_build::Package {
        name: name.as_str(),
        root_dir: manifest_path
            .parent()
            .ok_or_else(|| anyhow!("no parent for {manifest_path}"))?
            .as_str(),
        ..Default::default()
    };
    aya_build::build_ebpf([ebpf_package], Toolchain::Custom(EBPF_TOOLCHAIN))
}
