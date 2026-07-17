use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelKind {
    Denoise,
    Sr,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum ChannelOrder {
    Rgb,
    Bgr,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputRange {
    ZeroToOne,
    MinusOneToOne,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ManifestEntry {
    pub name: String,
    pub file: String,
    pub scale: u32,
    pub kind: ModelKind,
    pub tile: usize,
    pub overlap: usize,
    pub channel_order: ChannelOrder,
    pub input_range: InputRange,
    #[serde(default)]
    pub notes: String,
}

impl ManifestEntry {
    pub fn validate(&self) -> Result<()> {
        ensure!(!self.name.trim().is_empty(), "model name must not be empty");
        ensure!(!self.file.trim().is_empty(), "model file must not be empty");
        ensure!(
            matches!(self.scale, 1 | 2 | 4),
            "model scale must be 1, 2, or 4"
        );
        ensure!(self.tile > 0, "model tile size must be greater than zero");
        ensure!(
            self.overlap * 2 < self.tile,
            "model overlap must be less than half the tile size"
        );
        match self.kind {
            ModelKind::Denoise if self.scale != 1 => {
                bail!("denoise model {} must use scale 1", self.name)
            }
            ModelKind::Sr if self.scale == 1 => {
                bail!("super-resolution model {} must use scale 2 or 4", self.name)
            }
            ModelKind::Denoise | ModelKind::Sr => {}
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    pub models: Vec<ManifestEntry>,
}

impl Manifest {
    pub fn load(path: &Path) -> Result<Self> {
        let file = File::open(path)
            .with_context(|| format!("failed to open model manifest {}", path.display()))?;
        let manifest: Self = serde_json::from_reader(BufReader::new(file))
            .with_context(|| format!("failed to parse model manifest {}", path.display()))?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn validate(&self) -> Result<()> {
        for entry in &self.models {
            entry.validate()?;
        }
        for (index, entry) in self.models.iter().enumerate() {
            ensure!(
                !self.models[..index]
                    .iter()
                    .any(|other| other.name == entry.name),
                "duplicate model name {}",
                entry.name
            );
        }
        Ok(())
    }

    #[must_use]
    pub fn find(&self, name: &str) -> Option<&ManifestEntry> {
        self.models.iter().find(|entry| entry.name == name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_model_constraints() {
        let entry = ManifestEntry {
            name: "span-x4".into(),
            file: "span-x4.onnx".into(),
            scale: 4,
            kind: ModelKind::Sr,
            tile: 256,
            overlap: 32,
            channel_order: ChannelOrder::Rgb,
            input_range: InputRange::ZeroToOne,
            notes: String::new(),
        };
        entry.validate().unwrap();
    }

    #[test]
    fn rejects_duplicate_names() {
        let entry = ManifestEntry {
            name: "same".into(),
            file: "model.onnx".into(),
            scale: 1,
            kind: ModelKind::Denoise,
            tile: 128,
            overlap: 16,
            channel_order: ChannelOrder::Rgb,
            input_range: InputRange::ZeroToOne,
            notes: String::new(),
        };
        let manifest = Manifest {
            models: vec![entry.clone(), entry],
        };
        assert!(manifest.validate().is_err());
    }
}
