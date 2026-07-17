use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};

use anyhow::{Context, Result, ensure};
use ort::ep::{CPU, ExecutionProviderDispatch};
use ort::session::Session;
use ort::value::Tensor;
use serde_json::Value;

use crate::manifest::{ChannelOrder, InputRange, ManifestEntry};

static PROFILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static LAST_EP_ALLOCATIONS: OnceLock<RwLock<BTreeMap<String, usize>>> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TileHint {
    pub size: usize,
    pub overlap: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DevicePref {
    #[default]
    Auto,
    Cpu,
    Cuda,
    DirectMl,
    CoreMl,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SrgbTile {
    pub data: Vec<f32>,
    pub w: usize,
    pub h: usize,
}

impl SrgbTile {
    pub fn new(data: Vec<f32>, w: usize, h: usize) -> Result<Self> {
        ensure!(w > 0 && h > 0, "tile dimensions must be greater than zero");
        ensure!(
            data.len() == w * h * 3,
            "tile data length does not match dimensions"
        );
        ensure!(
            data.iter().all(|value| value.is_finite()),
            "tile contains NaN or infinity"
        );
        Ok(Self { data, w, h })
    }
}

pub trait Restorer: Send + Sync {
    fn scale(&self) -> u32;
    fn tile_hint(&self) -> TileHint;
    fn run(&self, tile: &SrgbTile) -> Result<SrgbTile>;
}

struct OrtState {
    session: Session,
    profile_pending: bool,
}

pub struct OrtRestorer {
    state: Mutex<OrtState>,
    scale: u32,
    tile_hint: TileHint,
    static_input_edge: Option<usize>,
    channel_order: ChannelOrder,
    input_range: InputRange,
}

impl OrtRestorer {
    pub fn load(entry: &ManifestEntry, model_path: &Path, device: DevicePref) -> Result<Self> {
        entry.validate()?;
        ensure!(
            model_path.is_file(),
            "model file does not exist: {}",
            model_path.display()
        );

        let profile_path = profile_path(entry);
        let providers = execution_providers(device);
        tracing::info!(
            model = entry.name,
            requested_device = ?device,
            candidates = ?providers.iter().map(|provider| format!("{provider:?}")).collect::<Vec<_>>(),
            "creating ONNX Runtime session"
        );
        let mut builder =
            Session::builder().context("failed to create ONNX Runtime session builder")?;
        builder = builder.with_parallel_execution(false).map_err(|error| {
            anyhow::anyhow!("failed to configure sequential ONNX execution: {error}")
        })?;
        builder = builder
            .with_memory_pattern(false)
            .map_err(|error| anyhow::anyhow!("failed to disable ONNX memory pattern: {error}"))?;
        #[cfg(target_os = "windows")]
        let static_input_edge =
            matches!(device, DevicePref::Auto | DevicePref::DirectMl).then_some(entry.tile);
        #[cfg(not(target_os = "windows"))]
        let static_input_edge = None;
        if let Some(edge) = static_input_edge {
            let input_edge =
                i64::try_from(edge).context("model tile size does not fit an ONNX dimension")?;
            let output_edge = input_edge
                .checked_mul(i64::from(entry.scale))
                .context("model output tile dimension overflowed")?;
            builder = builder
                .with_dimension_override("height", input_edge)
                .map_err(|error| {
                    anyhow::anyhow!("failed to specialize DirectML input height: {error}")
                })?;
            builder = builder
                .with_dimension_override("width", input_edge)
                .map_err(|error| {
                    anyhow::anyhow!("failed to specialize DirectML input width: {error}")
                })?;
            builder = builder
                .with_dimension_override("output_height", output_edge)
                .map_err(|error| {
                    anyhow::anyhow!("failed to specialize DirectML output height: {error}")
                })?;
            builder = builder
                .with_dimension_override("output_width", output_edge)
                .map_err(|error| {
                    anyhow::anyhow!("failed to specialize DirectML output width: {error}")
                })?;
        }
        builder = builder
            .with_execution_providers(providers)
            .map_err(|error| {
                anyhow::anyhow!("failed to register ONNX execution providers: {error}")
            })?;
        builder = builder
            .with_profiling(&profile_path)
            .map_err(|error| anyhow::anyhow!("failed to enable ONNX Runtime profiling: {error}"))?;
        let session = builder
            .commit_from_file(model_path)
            .with_context(|| format!("failed to load ONNX model {}", model_path.display()))?;
        ensure!(
            session.inputs().len() == 1,
            "model must have exactly one input, got {}",
            session.inputs().len()
        );
        ensure!(
            session.outputs().len() == 1,
            "model must have exactly one output, got {}",
            session.outputs().len()
        );

        Ok(Self {
            state: Mutex::new(OrtState {
                session,
                profile_pending: true,
            }),
            scale: entry.scale,
            tile_hint: TileHint {
                size: entry.tile,
                overlap: entry.overlap,
            },
            static_input_edge,
            channel_order: entry.channel_order,
            input_range: entry.input_range,
        })
    }
}

impl Restorer for OrtRestorer {
    fn scale(&self) -> u32 {
        self.scale
    }

    fn tile_hint(&self) -> TileHint {
        self.tile_hint
    }

    fn run(&self, tile: &SrgbTile) -> Result<SrgbTile> {
        ensure!(
            tile.data.len() == tile.w * tile.h * 3,
            "tile data length does not match dimensions"
        );
        let padded = self
            .static_input_edge
            .map(|edge| pad_tile_to_edge(tile, edge))
            .transpose()?;
        let model_input = padded.as_ref().unwrap_or(tile);
        let input = pack_nchw(model_input, self.channel_order, self.input_range);
        let tensor = Tensor::from_array(([1_usize, 3, model_input.h, model_input.w], input))
            .context("failed to create ONNX input tensor")?;

        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("ONNX session lock was poisoned"))?;
        let (shape, output) = {
            let outputs = state
                .session
                .run(ort::inputs![tensor])
                .context("ONNX Runtime inference failed")?;
            let (shape, values) = outputs[0]
                .try_extract_tensor::<f32>()
                .context("ONNX model output is not an f32 tensor")?;
            (shape.to_vec(), values.to_vec())
        };

        if state.profile_pending {
            state.profile_pending = false;
            match state.session.end_profiling() {
                Ok(path) => log_profile(Path::new(&path)),
                Err(error) => tracing::warn!(%error, "failed to finalize ONNX Runtime profiling"),
            }
        }

        ensure!(
            shape.len() == 4,
            "model output must be NCHW rank 4, got shape {shape:?}"
        );
        ensure!(
            shape[0] == 1 && shape[1] == 3,
            "model output must have shape [1, 3, H, W], got {shape:?}"
        );
        let output_h =
            usize::try_from(shape[2]).context("model output height is negative or too large")?;
        let output_w =
            usize::try_from(shape[3]).context("model output width is negative or too large")?;
        let expected_w = model_input
            .w
            .checked_mul(usize::try_from(self.scale).context("model scale does not fit usize")?)
            .context("model output width overflowed")?;
        let expected_h = model_input
            .h
            .checked_mul(usize::try_from(self.scale).context("model scale does not fit usize")?)
            .context("model output height overflowed")?;
        ensure!(
            (output_w, output_h) == (expected_w, expected_h),
            "model output is {output_w}x{output_h}, expected {expected_w}x{expected_h}"
        );
        let output = unpack_nchw(
            &output,
            output_w,
            output_h,
            self.channel_order,
            self.input_range,
        )?;
        if padded.is_some() {
            let scale = usize::try_from(self.scale).context("model scale does not fit usize")?;
            crop_tile(
                &output,
                tile.w
                    .checked_mul(scale)
                    .context("cropped model output width overflowed")?,
                tile.h
                    .checked_mul(scale)
                    .context("cropped model output height overflowed")?,
            )
        } else {
            Ok(output)
        }
    }
}

fn pad_tile_to_edge(tile: &SrgbTile, edge: usize) -> Result<SrgbTile> {
    ensure!(
        tile.w <= edge && tile.h <= edge,
        "DirectML tile is {}x{}, exceeding the manifest tile size {edge}x{edge}; reduce --tile-size",
        tile.w,
        tile.h
    );
    if tile.w == edge && tile.h == edge {
        return Ok(tile.clone());
    }

    let mut data = vec![0.0; edge * edge * 3];
    for y in 0..edge {
        let source_y = y.min(tile.h - 1);
        for x in 0..edge {
            let source_x = x.min(tile.w - 1);
            let source = (source_y * tile.w + source_x) * 3;
            let destination = (y * edge + x) * 3;
            data[destination..destination + 3].copy_from_slice(&tile.data[source..source + 3]);
        }
    }
    SrgbTile::new(data, edge, edge)
}

fn crop_tile(tile: &SrgbTile, width: usize, height: usize) -> Result<SrgbTile> {
    ensure!(
        width > 0 && height > 0 && width <= tile.w && height <= tile.h,
        "invalid model output crop {width}x{height} for {}x{} tile",
        tile.w,
        tile.h
    );
    let mut data = Vec::with_capacity(width * height * 3);
    for y in 0..height {
        let start = y * tile.w * 3;
        data.extend_from_slice(&tile.data[start..start + width * 3]);
    }
    SrgbTile::new(data, width, height)
}

pub fn load_model(entry: &ManifestEntry, device: DevicePref) -> Result<Box<dyn Restorer>> {
    load_model_from_path(entry, Path::new(&entry.file), device)
}

pub fn load_model_from_path(
    entry: &ManifestEntry,
    path: &Path,
    device: DevicePref,
) -> Result<Box<dyn Restorer>> {
    Ok(Box::new(OrtRestorer::load(entry, path, device)?))
}

#[must_use]
pub fn compiled_execution_providers() -> Vec<String> {
    vec![
        #[cfg(feature = "cuda")]
        "CUDAExecutionProvider".to_owned(),
        #[cfg(target_os = "windows")]
        "DmlExecutionProvider".to_owned(),
        #[cfg(target_vendor = "apple")]
        "CoreMLExecutionProvider".to_owned(),
        "CPUExecutionProvider".to_owned(),
    ]
}

#[must_use]
pub fn last_execution_provider_allocations() -> BTreeMap<String, usize> {
    LAST_EP_ALLOCATIONS
        .get_or_init(|| RwLock::new(BTreeMap::new()))
        .read()
        .map_or_else(|_| BTreeMap::new(), |value| value.clone())
}

fn execution_providers(device: DevicePref) -> Vec<ExecutionProviderDispatch> {
    let mut providers = Vec::new();

    match device {
        DevicePref::Cpu => {}
        DevicePref::Cuda => push_cuda(&mut providers),
        DevicePref::DirectMl => push_direct_ml(&mut providers),
        DevicePref::CoreMl => push_core_ml(&mut providers),
        DevicePref::Auto => {
            #[cfg(target_os = "windows")]
            {
                push_cuda(&mut providers);
                push_direct_ml(&mut providers);
            }
            #[cfg(target_vendor = "apple")]
            push_core_ml(&mut providers);
            #[cfg(all(not(target_os = "windows"), not(target_vendor = "apple")))]
            push_cuda(&mut providers);
        }
    }

    providers.push(CPU::default().build());
    providers
}

#[cfg(feature = "cuda")]
fn push_cuda(providers: &mut Vec<ExecutionProviderDispatch>) {
    providers.push(ort::ep::CUDA::default().build().fail_silently());
}

#[cfg(not(feature = "cuda"))]
fn push_cuda(_providers: &mut Vec<ExecutionProviderDispatch>) {
    tracing::info!(
        "CUDA EP is not compiled into this build; use --features rawsr-core/cuda on an NVIDIA host"
    );
}

#[cfg(target_os = "windows")]
fn push_direct_ml(providers: &mut Vec<ExecutionProviderDispatch>) {
    providers.push(
        ort::ep::DirectML::default()
            .with_device_filter(ort::ep::directml::DeviceFilter::Gpu)
            .with_performance_preference(ort::ep::directml::PerformancePreference::HighPerformance)
            .build()
            .fail_silently(),
    );
}

#[cfg(not(target_os = "windows"))]
fn push_direct_ml(_providers: &mut Vec<ExecutionProviderDispatch>) {
    tracing::warn!("DirectML was requested on a non-Windows platform; falling back to CPU");
}

#[cfg(target_vendor = "apple")]
fn push_core_ml(providers: &mut Vec<ExecutionProviderDispatch>) {
    providers.push(ort::ep::CoreML::default().build().fail_silently());
}

#[cfg(not(target_vendor = "apple"))]
fn push_core_ml(_providers: &mut Vec<ExecutionProviderDispatch>) {
    tracing::warn!("CoreML was requested on a non-Apple platform; falling back to CPU");
}

fn pack_nchw(tile: &SrgbTile, channel_order: ChannelOrder, input_range: InputRange) -> Vec<f32> {
    let plane = tile.w * tile.h;
    let mut output = vec![0.0; plane * 3];
    for pixel_index in 0..plane {
        for model_channel in 0..3 {
            let source_channel = channel_index(model_channel, channel_order);
            let value = tile.data[pixel_index * 3 + source_channel].clamp(0.0, 1.0);
            output[model_channel * plane + pixel_index] = match input_range {
                InputRange::ZeroToOne => value,
                InputRange::MinusOneToOne => value.mul_add(2.0, -1.0),
            };
        }
    }
    output
}

fn unpack_nchw(
    input: &[f32],
    width: usize,
    height: usize,
    channel_order: ChannelOrder,
    input_range: InputRange,
) -> Result<SrgbTile> {
    let plane = width
        .checked_mul(height)
        .context("model output dimensions overflowed")?;
    ensure!(
        input.len() == plane * 3,
        "model output data length does not match dimensions"
    );
    let mut output = vec![0.0; input.len()];
    for pixel_index in 0..plane {
        for model_channel in 0..3 {
            let destination_channel = channel_index(model_channel, channel_order);
            let value = match input_range {
                InputRange::ZeroToOne => input[model_channel * plane + pixel_index],
                InputRange::MinusOneToOne => {
                    (input[model_channel * plane + pixel_index] + 1.0) * 0.5
                }
            };
            output[pixel_index * 3 + destination_channel] = value.clamp(0.0, 1.0);
        }
    }
    SrgbTile::new(output, width, height)
}

fn channel_index(model_channel: usize, order: ChannelOrder) -> usize {
    match order {
        ChannelOrder::Rgb => model_channel,
        ChannelOrder::Bgr => 2 - model_channel,
    }
}

fn profile_path(entry: &ManifestEntry) -> PathBuf {
    let sequence = PROFILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "rawsr-ort-{}-{sequence}-{}",
        std::process::id(),
        entry.name
    ))
}

fn log_profile(path: &Path) {
    let result = (|| -> Result<BTreeMap<String, usize>> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("failed to read ONNX profile {}", path.display()))?;
        let profile: Value = serde_json::from_str(&text)
            .with_context(|| format!("failed to parse ONNX profile {}", path.display()))?;
        let events = profile
            .as_array()
            .context("ONNX profile root is not an array")?;
        let mut counts = BTreeMap::new();
        for event in events {
            if let Some(provider) = event
                .get("args")
                .and_then(|args| args.get("provider"))
                .and_then(Value::as_str)
            {
                *counts.entry(provider.to_owned()).or_default() += 1;
            }
        }
        Ok(counts)
    })();

    match result {
        Ok(counts) if counts.is_empty() => {
            tracing::warn!(profile = %path.display(), "ONNX profile contained no node provider assignments");
        }
        Ok(counts) => {
            if let Ok(mut allocations) = LAST_EP_ALLOCATIONS
                .get_or_init(|| RwLock::new(BTreeMap::new()))
                .write()
            {
                *allocations = counts.clone();
            }
            let cpu_nodes = counts.get("CPUExecutionProvider").copied().unwrap_or(0);
            let accelerated_nodes = counts
                .iter()
                .filter(|(provider, _)| provider.as_str() != "CPUExecutionProvider")
                .map(|(_, count)| count)
                .sum::<usize>();
            tracing::info!(providers = ?counts, "ONNX Runtime actual node allocation");
            if accelerated_nodes > 0 && cpu_nodes > 0 {
                tracing::warn!(
                    cpu_fallback_nodes = cpu_nodes,
                    accelerated_nodes,
                    "ONNX Runtime execution provider used CPU fallback nodes"
                );
            }
        }
        Err(error) => {
            tracing::warn!(%error, profile = %path.display(), "could not inspect ONNX node allocation");
        }
    }
    if let Err(error) = std::fs::remove_file(path) {
        tracing::debug!(%error, profile = %path.display(), "could not remove ONNX profile");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{ManifestEntry, ModelKind};

    fn tiny_entry() -> ManifestEntry {
        ManifestEntry {
            name: "tiny-sr-x2".into(),
            file: "tiny_sr_x2.onnx".into(),
            scale: 2,
            kind: ModelKind::Sr,
            tile: 64,
            overlap: 8,
            channel_order: ChannelOrder::Rgb,
            input_range: InputRange::ZeroToOne,
            notes: "test model".into(),
        }
    }

    #[test]
    fn channel_and_range_round_trip() {
        let tile = SrgbTile::new(vec![0.0, 0.25, 1.0, 0.75, 0.5, 0.125], 2, 1).unwrap();
        for order in [ChannelOrder::Rgb, ChannelOrder::Bgr] {
            for range in [InputRange::ZeroToOne, InputRange::MinusOneToOne] {
                let packed = pack_nchw(&tile, order, range);
                let unpacked = unpack_nchw(&packed, tile.w, tile.h, order, range).unwrap();
                assert_eq!(unpacked, tile);
            }
        }
    }

    #[test]
    fn directml_padding_repeats_edges_and_crops_back() {
        let tile = SrgbTile::new(
            vec![1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0],
            2,
            2,
        )
        .unwrap();
        let padded = pad_tile_to_edge(&tile, 3).unwrap();
        assert_eq!((padded.w, padded.h), (3, 3));
        assert_eq!(&padded.data[6..9], &[0.0, 1.0, 0.0]);
        assert_eq!(&padded.data[24..27], &[1.0, 1.0, 1.0]);
        assert_eq!(crop_tile(&padded, 2, 2).unwrap(), tile);
    }

    #[test]
    fn tiny_onnx_model_doubles_spatial_dimensions() {
        let _ = tracing_subscriber::fmt()
            .with_env_filter("rawsr_core=info")
            .with_test_writer()
            .try_init();
        let model = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/test/tiny_sr_x2.onnx");
        let restorer = OrtRestorer::load(&tiny_entry(), &model, DevicePref::Auto).unwrap();
        let input = SrgbTile::new(
            (0..64 * 64 * 3)
                .map(|index| f32::from(u16::try_from(index % 257).unwrap()) / 256.0)
                .collect(),
            64,
            64,
        )
        .unwrap();
        let output = restorer.run(&input).unwrap();
        assert_eq!((output.w, output.h), (128, 128));
        assert!(output.data.iter().all(|value| (0.0..=1.0).contains(value)));
    }
}
