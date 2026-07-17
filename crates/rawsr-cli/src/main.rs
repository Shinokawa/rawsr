use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use clap::{Parser, ValueEnum};
use indicatif::{ProgressBar, ProgressStyle};
use rawsr_core::{
    BaseCurve, DevelopParams, DevicePref, Manifest, ModelKind, Rect, Restorer, SrgbImage,
    TileOptions, decode_raw, decode_std, develop, inspect_tiff, load_model_from_path,
    restore_tiled_to_image, restore_tiled_to_tiff, write_srgb16_tiff,
};
use tracing_subscriber::EnvFilter;

#[derive(Debug, Clone, Copy, ValueEnum)]
enum CliDevice {
    Auto,
    Cpu,
    Cuda,
    DirectMl,
    CoreMl,
}

impl From<CliDevice> for DevicePref {
    fn from(value: CliDevice) -> Self {
        match value {
            CliDevice::Auto => Self::Auto,
            CliDevice::Cpu => Self::Cpu,
            CliDevice::Cuda => Self::Cuda,
            CliDevice::DirectMl => Self::DirectMl,
            CliDevice::CoreMl => Self::CoreMl,
        }
    }
}

#[derive(Debug, Parser)]
#[command(
    name = "rawsr",
    version,
    about = "Local RAW denoise and super-resolution pipeline"
)]
struct Args {
    #[arg(value_name = "INPUT")]
    input: Option<PathBuf>,

    #[arg(short, long, value_name = "PATH")]
    output: Option<PathBuf>,

    #[arg(long, value_name = "PATH", default_value = "models/manifest.json")]
    manifest: PathBuf,

    #[arg(long)]
    list_models: bool,

    #[arg(long, value_name = "PATH")]
    inspect_tiff: Option<PathBuf>,

    #[arg(long, value_name = "MODEL")]
    denoise: Option<String>,

    #[arg(long, value_name = "MODEL")]
    sr: Option<String>,

    #[arg(long, value_name = "X,Y,W,H", value_parser = parse_rect)]
    crop: Option<Rect>,

    #[arg(long, value_name = "PIXELS")]
    tile_size: Option<usize>,

    #[arg(long, value_name = "MIB")]
    memory_budget_mib: Option<usize>,

    #[arg(long, value_enum, default_value_t = CliDevice::Auto)]
    device: CliDevice,

    #[arg(long, default_value_t = 0.0)]
    exposure_ev: f32,

    #[arg(long, value_name = "CONTRAST")]
    filmic: Option<f32>,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    let args = Args::parse();
    if args.list_models {
        list_models(&args.manifest)?;
        return Ok(());
    }
    if let Some(path) = args.inspect_tiff.as_deref() {
        let info = inspect_tiff(path)?;
        println!(
            "{}x{}\tRGB16\tICC={} bytes",
            info.width, info.height, info.icc_profile_bytes
        );
        return Ok(());
    }

    let input = args
        .input
        .as_deref()
        .context("INPUT is required unless --list-models or --inspect-tiff is used")?;
    let output = args
        .output
        .as_deref()
        .context("--output is required when processing an image")?;
    let linear = decode_input(input)?;
    let params = DevelopParams {
        exposure_ev: args.exposure_ev,
        curve: args
            .filmic
            .map_or(BaseCurve::Srgb, |contrast| BaseCurve::Filmic { contrast }),
        ..DevelopParams::default()
    };
    let mut current = develop(&linear, &params);
    let tile_options = TileOptions {
        tile_size: args.tile_size,
        overlap: None,
        memory_budget_bytes: args
            .memory_budget_mib
            .map(|mib| mib.saturating_mul(1024 * 1024)),
    };
    let device = DevicePref::from(args.device);

    let manifest = if args.denoise.is_some() || args.sr.is_some() {
        Some(Manifest::load(&args.manifest)?)
    } else {
        None
    };

    if let Some(name) = args.denoise.as_deref() {
        let model = load_named_model(
            manifest.as_ref().context("model manifest was not loaded")?,
            &args.manifest,
            name,
            ModelKind::Denoise,
            device,
        )?;
        let progress = progress_bar("降噪");
        current = restore_tiled_to_image(&current, model.as_ref(), None, tile_options, &|value| {
            set_progress(&progress, value);
        })?;
        progress.finish_with_message("降噪完成");
    }

    if let Some(name) = args.sr.as_deref() {
        let model = load_named_model(
            manifest.as_ref().context("model manifest was not loaded")?,
            &args.manifest,
            name,
            ModelKind::Sr,
            device,
        )?;
        let progress = progress_bar("超分");
        let container = restore_tiled_to_tiff(
            output,
            &current,
            model.as_ref(),
            args.crop,
            tile_options,
            &|value| set_progress(&progress, value),
        )?;
        progress.finish_with_message("超分完成");
        tracing::info!(path = %output.display(), ?container, "wrote restored 16-bit TIFF");
    } else {
        let output_image = if let Some(crop) = args.crop {
            crop_image(&current, crop)?
        } else {
            current
        };
        let container = write_srgb16_tiff(output, &output_image)?;
        tracing::info!(path = %output.display(), ?container, "wrote 16-bit TIFF");
    }
    Ok(())
}

fn list_models(path: &Path) -> Result<()> {
    let manifest = Manifest::load(path)?;
    for model in manifest.models {
        println!(
            "{}\t{:?}\t{}x\t{}",
            model.name, model.kind, model.scale, model.notes
        );
    }
    Ok(())
}

fn decode_input(path: &Path) -> Result<rawsr_core::LinearImage> {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or_default();
    let is_raw = extension.eq_ignore_ascii_case("arw");
    if is_raw {
        let (image, meta) = decode_raw(path)?;
        tracing::info!(
            make = meta.clean_make,
            model = meta.clean_model,
            width = image.w,
            height = image.h,
            cfa = meta.cfa_pattern,
            "decoded RAW"
        );
        Ok(image)
    } else {
        decode_std(path)
    }
}

fn load_named_model(
    manifest: &Manifest,
    manifest_path: &Path,
    name: &str,
    expected_kind: ModelKind,
    device: DevicePref,
) -> Result<Box<dyn Restorer>> {
    let entry = manifest.find(name).with_context(|| {
        format!(
            "model {name:?} is not present in {}",
            manifest_path.display()
        )
    })?;
    ensure!(
        entry.kind == expected_kind,
        "model {name:?} has kind {:?}, expected {:?}",
        entry.kind,
        expected_kind
    );
    let model_path = manifest_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(&entry.file);
    load_model_from_path(entry, &model_path, device)
}

fn crop_image(image: &SrgbImage, crop: Rect) -> Result<SrgbImage> {
    let crop = crop.validate_inside(image.w, image.h)?;
    let mut data = Vec::with_capacity(crop.w * crop.h * 3);
    for y in crop.y..crop.y + crop.h {
        let start = (y * image.w + crop.x) * 3;
        data.extend_from_slice(&image.data[start..start + crop.w * 3]);
    }
    SrgbImage::new(data, crop.w, crop.h)
}

fn parse_rect(value: &str) -> std::result::Result<Rect, String> {
    let values = value
        .split(',')
        .map(str::trim)
        .map(|part| part.parse::<usize>().map_err(|error| error.to_string()))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    if values.len() != 4 {
        return Err("crop must contain exactly four comma-separated integers: x,y,w,h".into());
    }
    Rect::new(values[0], values[1], values[2], values[3]).map_err(|error| error.to_string())
}

fn progress_bar(label: &'static str) -> ProgressBar {
    let progress = ProgressBar::new(1000);
    let style = ProgressStyle::with_template("{msg} [{bar:32}] {percent:>3}%")
        .unwrap_or_else(|_| ProgressStyle::default_bar())
        .progress_chars("=>-");
    progress.set_style(style);
    progress.set_message(label);
    progress
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn set_progress(progress: &ProgressBar, value: f32) {
    let position = (value.clamp(0.0, 1.0) * 1000.0).round() as u64;
    progress.set_position(position);
}
