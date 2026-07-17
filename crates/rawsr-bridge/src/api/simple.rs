use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::Instant;

use anyhow::{Context, Result, ensure};
use rawsr_core::{
    BaseCurve, ChannelOrder, DevelopParams, DevicePref, InputRange, Manifest, ManifestEntry,
    ModelKind, Rect, Restorer, SrgbImage, SrgbTile, TileHint, TileOptions,
    compiled_execution_providers, decode_raw, decode_std, develop, extract_thumbnail,
    last_execution_provider_allocations, load_model_from_path, restore_tiled_to_image,
    restore_tiled_to_preview, restore_tiled_to_tiff, write_srgb16_tiff,
};

use crate::frb_generated::StreamSink;

static NEXT_IMAGE_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_JOB_ID: AtomicU64 = AtomicU64::new(1);
static IMAGE_CACHE: OnceLock<RwLock<HashMap<u64, Arc<SrgbImage>>>> = OnceLock::new();
static JOB_CANCEL_FLAGS: OnceLock<RwLock<HashMap<u64, Arc<AtomicBool>>>> = OnceLock::new();

#[derive(Debug, Clone)]
pub struct ExifData {
    pub make: String,
    pub model: String,
    pub lens_model: Option<String>,
    pub iso: Option<u32>,
    pub exposure_seconds: Option<f32>,
    pub aperture: Option<f32>,
    pub focal_length_mm: Option<f32>,
    pub captured_at: Option<String>,
    pub orientation: Option<u16>,
}

#[derive(Debug, Clone)]
pub struct ThumbData {
    pub jpeg: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub exif: ExifData,
}

#[derive(Debug, Clone, Copy)]
pub struct ImageHandle {
    pub id: u64,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct RegionRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone)]
pub struct RgbaBytes {
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone)]
pub struct ModelEntry {
    pub name: String,
    pub file: String,
    pub scale: u32,
    pub kind: String,
    pub tile: u32,
    pub overlap: u32,
    pub channel_order: String,
    pub input_range: String,
    pub notes: String,
    pub installed: bool,
    pub file_size_bytes: u64,
}

#[derive(Debug, Clone)]
pub struct StripEvent {
    pub model: String,
    pub state: String,
    pub progress: f32,
    pub elapsed_ms: u64,
    pub image: Option<RgbaBytes>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ExportJob {
    pub handle: ImageHandle,
    pub output_path: String,
    pub crop: Option<RegionRect>,
    pub denoise_model: Option<String>,
    pub sr_model: Option<String>,
    pub device: String,
    pub tile_size: Option<u32>,
    pub memory_budget_mib: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct JobEvent {
    pub job_id: u64,
    pub state: String,
    pub progress: f32,
    pub message: String,
    pub output_path: Option<String>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ImportModelRequest {
    pub source_path: String,
    pub name: String,
    pub kind: String,
    pub scale: u32,
    pub tile: u32,
    pub overlap: u32,
    pub channel_order: String,
    pub input_range: String,
    pub notes: String,
}

#[derive(Debug, Clone)]
pub struct ProviderAllocation {
    pub provider: String,
    pub node_count: u32,
}

#[derive(Debug, Clone)]
pub struct RuntimeInfo {
    pub platform: String,
    pub compiled_providers: Vec<String>,
    pub last_allocations: Vec<ProviderAllocation>,
    pub preferred_device: String,
}

pub fn extract_thumb(path: String) -> std::result::Result<ThumbData, String> {
    extract_thumb_impl(Path::new(&path)).map_err(display_error)
}

pub fn open_image(
    path: String,
    exposure_ev: f32,
    filmic_contrast: Option<f32>,
) -> std::result::Result<ImageHandle, String> {
    open_image_impl(Path::new(&path), exposure_ev, filmic_contrast).map_err(display_error)
}

pub fn render_preview(
    handle: ImageHandle,
    max_edge: u32,
) -> std::result::Result<RgbaBytes, String> {
    render_image(handle, None, max_edge).map_err(display_error)
}

pub fn render_region(
    handle: ImageHandle,
    rect: RegionRect,
    max_edge: u32,
) -> std::result::Result<RgbaBytes, String> {
    render_image(handle, Some(rect), max_edge).map_err(display_error)
}

pub fn close_image(handle: ImageHandle) -> std::result::Result<bool, String> {
    let removed = cache()
        .write()
        .map_err(|_| "image cache lock is poisoned".to_owned())?
        .remove(&handle.id)
        .is_some();
    Ok(removed)
}

pub fn list_models() -> std::result::Result<Vec<ModelEntry>, String> {
    list_models_impl().map_err(display_error)
}

pub fn run_test_strip(
    handle: ImageHandle,
    rect: RegionRect,
    models: Vec<String>,
    sink: StreamSink<StripEvent>,
) -> std::result::Result<(), String> {
    run_test_strip_impl(handle, rect, &models, &sink).map_err(display_error)
}

pub fn enqueue_export(
    job: ExportJob,
    sink: StreamSink<JobEvent>,
) -> std::result::Result<(), String> {
    enqueue_export_impl(job, &sink).map_err(display_error)
}

pub fn cancel_job(job_id: u64) -> std::result::Result<bool, String> {
    let flags = job_cancel_flags()
        .read()
        .map_err(|_| "job cancellation lock is poisoned".to_owned())?;
    let Some(flag) = flags.get(&job_id) else {
        return Ok(false);
    };
    flag.store(true, Ordering::Relaxed);
    Ok(true)
}

pub fn import_model(request: ImportModelRequest) -> std::result::Result<ModelEntry, String> {
    import_model_impl(request).map_err(display_error)
}

#[must_use]
pub fn runtime_info() -> RuntimeInfo {
    let last_allocations = last_execution_provider_allocations()
        .into_iter()
        .map(|(provider, node_count)| ProviderAllocation {
            provider,
            node_count: u32::try_from(node_count).unwrap_or(u32::MAX),
        })
        .collect();
    RuntimeInfo {
        platform: std::env::consts::OS.to_owned(),
        compiled_providers: compiled_execution_providers(),
        last_allocations,
        preferred_device: if cfg!(target_os = "windows") {
            "DirectML → CPU".to_owned()
        } else if cfg!(target_vendor = "apple") {
            "CoreML → CPU".to_owned()
        } else {
            "CPU".to_owned()
        },
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

fn extract_thumb_impl(path: &Path) -> Result<ThumbData> {
    let thumbnail = extract_thumbnail(path)?;
    Ok(ThumbData {
        jpeg: thumbnail.jpeg,
        width: thumbnail.width,
        height: thumbnail.height,
        exif: ExifData {
            make: thumbnail.exif.make,
            model: thumbnail.exif.model,
            lens_model: thumbnail.exif.lens_model,
            iso: thumbnail.exif.iso,
            exposure_seconds: thumbnail.exif.exposure_seconds,
            aperture: thumbnail.exif.aperture,
            focal_length_mm: thumbnail.exif.focal_length_mm,
            captured_at: thumbnail.exif.captured_at,
            orientation: thumbnail.exif.orientation,
        },
    })
}

fn open_image_impl(
    path: &Path,
    exposure_ev: f32,
    filmic_contrast: Option<f32>,
) -> Result<ImageHandle> {
    ensure!(
        path.is_file(),
        "image file does not exist: {}",
        path.display()
    );
    ensure!(exposure_ev.is_finite(), "exposure EV must be finite");
    if let Some(contrast) = filmic_contrast {
        ensure!(contrast.is_finite(), "filmic contrast must be finite");
    }
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    let linear = if extension.eq_ignore_ascii_case("arw") {
        decode_raw(path)?.0
    } else {
        decode_std(path)?
    };
    let params = DevelopParams {
        exposure_ev,
        curve: filmic_contrast.map_or(BaseCurve::Srgb, |contrast| BaseCurve::Filmic { contrast }),
        ..DevelopParams::default()
    };
    let image = Arc::new(develop(&linear, &params));
    let width = u32::try_from(image.w).context("image width exceeds u32")?;
    let height = u32::try_from(image.h).context("image height exceeds u32")?;
    let id = NEXT_IMAGE_ID.fetch_add(1, Ordering::Relaxed);
    ensure!(id != u64::MAX, "image handle space is exhausted");
    cache()
        .write()
        .map_err(|_| anyhow::anyhow!("image cache lock is poisoned"))?
        .insert(id, image);
    Ok(ImageHandle { id, width, height })
}

fn render_image(
    handle: ImageHandle,
    region: Option<RegionRect>,
    max_edge: u32,
) -> Result<RgbaBytes> {
    ensure!(max_edge > 0, "maximum edge must be greater than zero");
    let image = cache()
        .read()
        .map_err(|_| anyhow::anyhow!("image cache lock is poisoned"))?
        .get(&handle.id)
        .cloned()
        .with_context(|| format!("image handle {} is no longer open", handle.id))?;
    ensure!(
        image.w == usize::try_from(handle.width)? && image.h == usize::try_from(handle.height)?,
        "image handle dimensions do not match the cached image"
    );

    let region = region.unwrap_or(RegionRect {
        x: 0,
        y: 0,
        width: handle.width,
        height: handle.height,
    });
    validate_region(region, handle.width, handle.height)?;
    let (output_width, output_height) = fit_dimensions(region.width, region.height, max_edge);
    let capacity = usize::try_from(output_width)?
        .checked_mul(usize::try_from(output_height)?)
        .and_then(|pixels| pixels.checked_mul(4))
        .context("RGBA output size overflowed")?;
    let mut bytes = Vec::with_capacity(capacity);
    for output_y in 0..output_height {
        for output_x in 0..output_width {
            let source_x = f64::from(region.x)
                + (f64::from(output_x) + 0.5) * f64::from(region.width) / f64::from(output_width)
                - 0.5;
            let source_y = f64::from(region.y)
                + (f64::from(output_y) + 0.5) * f64::from(region.height) / f64::from(output_height)
                - 0.5;
            let rgb = sample_bilinear(&image, source_x, source_y);
            bytes.extend(rgb.map(to_u8));
            bytes.push(u8::MAX);
        }
    }
    Ok(RgbaBytes {
        bytes,
        width: output_width,
        height: output_height,
    })
}

fn validate_region(region: RegionRect, image_width: u32, image_height: u32) -> Result<()> {
    ensure!(
        region.width > 0 && region.height > 0,
        "region dimensions must be greater than zero"
    );
    let right = region
        .x
        .checked_add(region.width)
        .context("region x extent overflowed")?;
    let bottom = region
        .y
        .checked_add(region.height)
        .context("region y extent overflowed")?;
    ensure!(
        right <= image_width && bottom <= image_height,
        "region lies outside the image"
    );
    Ok(())
}

fn fit_dimensions(width: u32, height: u32, max_edge: u32) -> (u32, u32) {
    let longest = width.max(height);
    if longest <= max_edge {
        return (width, height);
    }
    if width >= height {
        let scaled_height = (u64::from(height) * u64::from(max_edge) / u64::from(width)).max(1);
        (max_edge, u32::try_from(scaled_height).unwrap_or(1))
    } else {
        let scaled_width = (u64::from(width) * u64::from(max_edge) / u64::from(height)).max(1);
        (u32::try_from(scaled_width).unwrap_or(1), max_edge)
    }
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn sample_bilinear(image: &SrgbImage, x: f64, y: f64) -> [f32; 3] {
    let max_x = (image.w - 1) as f64;
    let max_y = (image.h - 1) as f64;
    let x = x.clamp(0.0, max_x);
    let y = y.clamp(0.0, max_y);
    let x0 = x.floor() as usize;
    let y0 = y.floor() as usize;
    let x1 = (x0 + 1).min(image.w - 1);
    let y1 = (y0 + 1).min(image.h - 1);
    let tx = (x - x0 as f64) as f32;
    let ty = (y - y0 as f64) as f32;
    let mut output = [0.0; 3];
    for (channel, value) in output.iter_mut().enumerate() {
        let top_left = image.data[(y0 * image.w + x0) * 3 + channel];
        let top_right = image.data[(y0 * image.w + x1) * 3 + channel];
        let bottom_left = image.data[(y1 * image.w + x0) * 3 + channel];
        let bottom_right = image.data[(y1 * image.w + x1) * 3 + channel];
        let top = top_left + (top_right - top_left) * tx;
        let bottom = bottom_left + (bottom_right - bottom_left) * tx;
        *value = top + (bottom - top) * ty;
    }
    output
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn to_u8(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * 255.0).round() as u8
}

fn run_test_strip_impl(
    handle: ImageHandle,
    rect: RegionRect,
    models: &[String],
    sink: &StreamSink<StripEvent>,
) -> Result<()> {
    ensure!(
        (2..=4).contains(&models.len()),
        "test strip requires between 2 and 4 models"
    );
    for (index, model) in models.iter().enumerate() {
        ensure!(
            !models[..index].contains(model),
            "test strip contains duplicate model {model}"
        );
    }
    let image = cached_image(handle)?;
    validate_region(rect, handle.width, handle.height)?;
    for model in models {
        let started = Instant::now();
        send_strip_event(
            sink,
            StripEvent {
                model: model.clone(),
                state: "running".to_owned(),
                progress: 0.0,
                elapsed_ms: 0,
                image: None,
                reason: None,
            },
        )?;
        match run_one_strip(&image, rect, model, sink, started) {
            Ok(output) => send_strip_event(
                sink,
                StripEvent {
                    model: model.clone(),
                    state: "completed".to_owned(),
                    progress: 1.0,
                    elapsed_ms: elapsed_millis(started),
                    image: Some(output),
                    reason: None,
                },
            )?,
            Err(error) => send_strip_event(
                sink,
                StripEvent {
                    model: model.clone(),
                    state: "failed".to_owned(),
                    progress: 1.0,
                    elapsed_ms: elapsed_millis(started),
                    image: None,
                    reason: Some(format!("{error:#}")),
                },
            )?,
        }
    }
    Ok(())
}

fn run_one_strip(
    image: &SrgbImage,
    rect: RegionRect,
    model: &str,
    sink: &StreamSink<StripEvent>,
    started: Instant,
) -> Result<RgbaBytes> {
    let (_, restorer) = load_named_model(model, None, DevicePref::Auto)?;
    let last_progress = Mutex::new(-1.0_f32);
    let core_rect = to_core_rect(rect)?;
    let restored = restore_tiled_to_preview(
        image,
        restorer.as_ref(),
        Some(core_rect),
        TileOptions::default(),
        16 * 1024 * 1024,
        &|progress| {
            if let Ok(mut last) = last_progress.lock()
                && (progress - *last >= 0.02 || progress >= 1.0)
            {
                *last = progress;
                let _ = sink.add(StripEvent {
                    model: model.to_owned(),
                    state: "running".to_owned(),
                    progress,
                    elapsed_ms: elapsed_millis(started),
                    image: None,
                    reason: None,
                });
            }
        },
    )?;
    render_standalone(restored, 2048)
}

fn enqueue_export_impl(job: ExportJob, sink: &StreamSink<JobEvent>) -> Result<()> {
    let job_id = NEXT_JOB_ID.fetch_add(1, Ordering::Relaxed);
    ensure!(job_id != u64::MAX, "job id space is exhausted");
    let cancelled = Arc::new(AtomicBool::new(false));
    job_cancel_flags()
        .write()
        .map_err(|_| anyhow::anyhow!("job cancellation lock is poisoned"))?
        .insert(job_id, Arc::clone(&cancelled));

    send_job_event(
        sink,
        JobEvent {
            job_id,
            state: "queued".to_owned(),
            progress: 0.0,
            message: "已加入队列".to_owned(),
            output_path: None,
            reason: None,
        },
    )?;
    send_job_event(
        sink,
        JobEvent {
            job_id,
            state: "running".to_owned(),
            progress: 0.0,
            message: "正在准备图像".to_owned(),
            output_path: None,
            reason: None,
        },
    )?;

    let output_path = job.output_path.clone();
    let result = export_job_work(job_id, &job, sink, Arc::clone(&cancelled));
    let final_event = match result {
        Ok(()) => JobEvent {
            job_id,
            state: "completed".to_owned(),
            progress: 1.0,
            message: "导出完成".to_owned(),
            output_path: Some(output_path),
            reason: None,
        },
        Err(error) if cancelled.load(Ordering::Relaxed) => JobEvent {
            job_id,
            state: "cancelled".to_owned(),
            progress: 1.0,
            message: "任务已取消".to_owned(),
            output_path: None,
            reason: Some(format!("{error:#}")),
        },
        Err(error) => JobEvent {
            job_id,
            state: "failed".to_owned(),
            progress: 1.0,
            message: "导出失败".to_owned(),
            output_path: None,
            reason: Some(format!("{error:#}")),
        },
    };
    job_cancel_flags()
        .write()
        .map_err(|_| anyhow::anyhow!("job cancellation lock is poisoned"))?
        .remove(&job_id);
    send_job_event(sink, final_event)
}

fn export_job_work(
    job_id: u64,
    job: &ExportJob,
    sink: &StreamSink<JobEvent>,
    cancelled: Arc<AtomicBool>,
) -> Result<()> {
    let image = cached_image(job.handle)?;
    let mut current = if let Some(crop) = job.crop {
        crop_srgb(&image, to_core_rect(crop)?)?
    } else {
        image.as_ref().clone()
    };
    ensure_not_cancelled(&cancelled)?;

    let output = PathBuf::from(&job.output_path);
    ensure!(
        !job.output_path.trim().is_empty(),
        "output path must not be empty"
    );
    let extension = output
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    ensure!(
        extension.eq_ignore_ascii_case("tif") || extension.eq_ignore_ascii_case("tiff"),
        "output path must use .tif or .tiff"
    );
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create output directory {}", parent.display()))?;
    }
    let options = TileOptions {
        tile_size: job.tile_size.map(|value| value as usize),
        overlap: None,
        memory_budget_bytes: job
            .memory_budget_mib
            .map(|value| value as usize * 1024 * 1024),
    };
    let device = parse_device(&job.device)?;
    let stage_count =
        usize::from(job.denoise_model.is_some()) + usize::from(job.sr_model.is_some());
    let stage_count = stage_count.max(1) as f32;
    let mut completed_stages = 0.0_f32;

    if let Some(model) = job.denoise_model.as_deref() {
        let (_, restorer) = load_named_model(model, Some(ModelKind::Denoise), device)?;
        let restorer = CancellableRestorer::new(restorer, Arc::clone(&cancelled));
        current = restore_tiled_to_image(&current, &restorer, None, options, &|progress| {
            let overall = (completed_stages + progress) / stage_count;
            let _ = sink.add(JobEvent {
                job_id,
                state: "running".to_owned(),
                progress: overall,
                message: format!("正在降噪 · {}%", (progress * 100.0).round()),
                output_path: None,
                reason: None,
            });
        })?;
        completed_stages += 1.0;
        ensure_not_cancelled(&cancelled)?;
    }

    if let Some(model) = job.sr_model.as_deref() {
        let (_, restorer) = load_named_model(model, Some(ModelKind::Sr), device)?;
        let restorer = CancellableRestorer::new(restorer, Arc::clone(&cancelled));
        restore_tiled_to_tiff(&output, &current, &restorer, None, options, &|progress| {
            let overall = (completed_stages + progress) / stage_count;
            let _ = sink.add(JobEvent {
                job_id,
                state: "running".to_owned(),
                progress: overall,
                message: format!("正在超分 · {}%", (progress * 100.0).round()),
                output_path: None,
                reason: None,
            });
        })?;
    } else {
        ensure_not_cancelled(&cancelled)?;
        write_srgb16_tiff(&output, &current)?;
    }
    ensure_not_cancelled(&cancelled)
}

fn load_named_model(
    name: &str,
    expected_kind: Option<ModelKind>,
    device: DevicePref,
) -> Result<(ManifestEntry, Box<dyn Restorer>)> {
    let manifest_path = find_manifest()?;
    let manifest = Manifest::load(&manifest_path)?;
    let entry = manifest
        .find(name)
        .with_context(|| {
            format!(
                "model {name:?} is not present in {}",
                manifest_path.display()
            )
        })?
        .clone();
    if let Some(expected) = expected_kind {
        ensure!(
            entry.kind == expected,
            "model {name:?} has kind {:?}, expected {:?}",
            entry.kind,
            expected
        );
    }
    let model_path = manifest_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(&entry.file);
    let restorer = load_model_from_path(&entry, &model_path, device)?;
    Ok((entry, restorer))
}

fn parse_device(value: &str) -> Result<DevicePref> {
    match value.trim().to_ascii_lowercase().as_str() {
        "" | "auto" => Ok(DevicePref::Auto),
        "cpu" => Ok(DevicePref::Cpu),
        "cuda" => Ok(DevicePref::Cuda),
        "directml" | "direct_ml" | "dml" => Ok(DevicePref::DirectMl),
        "coreml" | "core_ml" => Ok(DevicePref::CoreMl),
        other => anyhow::bail!("unknown inference device {other:?}"),
    }
}

fn cached_image(handle: ImageHandle) -> Result<Arc<SrgbImage>> {
    let image = cache()
        .read()
        .map_err(|_| anyhow::anyhow!("image cache lock is poisoned"))?
        .get(&handle.id)
        .cloned()
        .with_context(|| format!("image handle {} is no longer open", handle.id))?;
    ensure!(
        image.w == usize::try_from(handle.width)? && image.h == usize::try_from(handle.height)?,
        "image handle dimensions do not match the cached image"
    );
    Ok(image)
}

fn to_core_rect(rect: RegionRect) -> Result<Rect> {
    Rect::new(
        usize::try_from(rect.x)?,
        usize::try_from(rect.y)?,
        usize::try_from(rect.width)?,
        usize::try_from(rect.height)?,
    )
}

fn crop_srgb(image: &SrgbImage, crop: Rect) -> Result<SrgbImage> {
    let crop = crop.validate_inside(image.w, image.h)?;
    let mut data = Vec::with_capacity(crop.w * crop.h * 3);
    for y in crop.y..crop.y + crop.h {
        let start = (y * image.w + crop.x) * 3;
        data.extend_from_slice(&image.data[start..start + crop.w * 3]);
    }
    SrgbImage::new(data, crop.w, crop.h)
}

fn render_standalone(image: SrgbImage, max_edge: u32) -> Result<RgbaBytes> {
    let width = u32::try_from(image.w).context("image width exceeds u32")?;
    let height = u32::try_from(image.h).context("image height exceeds u32")?;
    let id = NEXT_IMAGE_ID.fetch_add(1, Ordering::Relaxed);
    ensure!(id != u64::MAX, "image handle space is exhausted");
    let handle = ImageHandle { id, width, height };
    cache()
        .write()
        .map_err(|_| anyhow::anyhow!("image cache lock is poisoned"))?
        .insert(id, Arc::new(image));
    let rendered = render_image(handle, None, max_edge);
    cache()
        .write()
        .map_err(|_| anyhow::anyhow!("image cache lock is poisoned"))?
        .remove(&id);
    rendered
}

fn send_strip_event(sink: &StreamSink<StripEvent>, event: StripEvent) -> Result<()> {
    sink.add(event)
        .map_err(|error| anyhow::anyhow!("failed to send test-strip event: {error}"))
}

fn send_job_event(sink: &StreamSink<JobEvent>, event: JobEvent) -> Result<()> {
    sink.add(event)
        .map_err(|error| anyhow::anyhow!("failed to send export event: {error}"))
}

fn elapsed_millis(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}

fn ensure_not_cancelled(cancelled: &AtomicBool) -> Result<()> {
    ensure!(!cancelled.load(Ordering::Relaxed), "job cancelled by user");
    Ok(())
}

struct CancellableRestorer {
    inner: Box<dyn Restorer>,
    cancelled: Arc<AtomicBool>,
}

impl CancellableRestorer {
    fn new(inner: Box<dyn Restorer>, cancelled: Arc<AtomicBool>) -> Self {
        Self { inner, cancelled }
    }
}

impl Restorer for CancellableRestorer {
    fn scale(&self) -> u32 {
        self.inner.scale()
    }

    fn tile_hint(&self) -> TileHint {
        self.inner.tile_hint()
    }

    fn run(&self, tile: &SrgbTile) -> Result<SrgbTile> {
        ensure_not_cancelled(&self.cancelled)?;
        self.inner.run(tile)
    }
}

fn import_model_impl(request: ImportModelRequest) -> Result<ModelEntry> {
    let source = PathBuf::from(&request.source_path);
    ensure!(
        source.is_file(),
        "ONNX source file does not exist: {}",
        source.display()
    );
    ensure!(
        source
            .extension()
            .and_then(|value| value.to_str())
            .is_some_and(|value| value.eq_ignore_ascii_case("onnx")),
        "model source must use the .onnx extension"
    );
    let name = request.name.trim();
    ensure!(!name.is_empty(), "model name must not be empty");
    let kind = match request.kind.trim().to_ascii_lowercase().as_str() {
        "denoise" => ModelKind::Denoise,
        "sr" => ModelKind::Sr,
        other => anyhow::bail!("unknown model kind {other:?}"),
    };
    let channel_order = match request.channel_order.trim().to_ascii_uppercase().as_str() {
        "RGB" => ChannelOrder::Rgb,
        "BGR" => ChannelOrder::Bgr,
        other => anyhow::bail!("unknown channel order {other:?}"),
    };
    let input_range = match request.input_range.trim().to_ascii_lowercase().as_str() {
        "zero_to_one" | "0_1" => InputRange::ZeroToOne,
        "minus_one_to_one" | "-1_1" => InputRange::MinusOneToOne,
        other => anyhow::bail!("unknown input range {other:?}"),
    };
    let file_stem: String = name
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .collect();
    ensure!(
        file_stem
            .chars()
            .any(|character| character.is_ascii_alphanumeric()),
        "model name does not contain a usable filename"
    );
    let file = format!("{file_stem}.onnx");
    let entry = ManifestEntry {
        name: name.to_owned(),
        file: file.clone(),
        scale: request.scale,
        kind,
        tile: usize::try_from(request.tile)?,
        overlap: usize::try_from(request.overlap)?,
        channel_order,
        input_range,
        notes: request.notes,
    };
    entry.validate()?;

    let manifest_path = find_manifest()?;
    let mut manifest = Manifest::load(&manifest_path)?;
    ensure!(
        manifest.find(name).is_none(),
        "model name {name:?} already exists in the manifest"
    );
    ensure!(
        !manifest
            .models
            .iter()
            .any(|value| value.file.eq_ignore_ascii_case(&file)),
        "model file {file:?} already exists in the manifest"
    );
    let model_root = manifest_path
        .parent()
        .context("model manifest has no parent directory")?;
    let destination = model_root.join(&file);
    let source_canonical = source
        .canonicalize()
        .with_context(|| format!("failed to resolve model source {}", source.display()))?;
    let destination_canonical = destination.canonicalize().ok();
    let copied = destination_canonical.as_ref() != Some(&source_canonical);
    if copied {
        ensure!(
            !destination.exists(),
            "destination model file already exists: {}",
            destination.display()
        );
        fs::copy(&source, &destination).with_context(|| {
            format!(
                "failed to copy ONNX model {} to {}",
                source.display(),
                destination.display()
            )
        })?;
    }
    manifest.models.push(entry.clone());
    if let Err(error) = manifest.validate().and_then(|()| {
        let mut json =
            serde_json::to_vec_pretty(&manifest).context("failed to serialize manifest")?;
        json.push(b'\n');
        fs::write(&manifest_path, json).with_context(|| {
            format!(
                "failed to update model manifest {}",
                manifest_path.display()
            )
        })
    }) {
        if copied {
            let _ = fs::remove_file(&destination);
        }
        return Err(error);
    }
    model_entry_to_bridge(entry, Some(destination))
}

fn list_models_impl() -> Result<Vec<ModelEntry>> {
    let manifest_path = find_manifest()?;
    let manifest = Manifest::load(&manifest_path)?;
    let model_root = manifest_path.parent().unwrap_or_else(|| Path::new("."));
    manifest
        .models
        .into_iter()
        .map(|entry| {
            let path = model_root.join(&entry.file);
            model_entry_to_bridge(entry, Some(path))
        })
        .collect()
}

fn model_entry_to_bridge(entry: ManifestEntry, path: Option<PathBuf>) -> Result<ModelEntry> {
    let metadata = path.and_then(|value| value.metadata().ok());
    Ok(ModelEntry {
        name: entry.name,
        file: entry.file,
        scale: entry.scale,
        kind: format!("{:?}", entry.kind).to_lowercase(),
        tile: u32::try_from(entry.tile).context("model tile size exceeds u32")?,
        overlap: u32::try_from(entry.overlap).context("model overlap exceeds u32")?,
        channel_order: format!("{:?}", entry.channel_order).to_uppercase(),
        input_range: match entry.input_range {
            InputRange::ZeroToOne => "zero_to_one",
            InputRange::MinusOneToOne => "minus_one_to_one",
        }
        .to_owned(),
        notes: entry.notes,
        installed: metadata.is_some(),
        file_size_bytes: metadata.map_or(0, |value| value.len()),
    })
}

fn find_manifest() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("RAWSR_MANIFEST") {
        let path = PathBuf::from(path);
        ensure!(
            path.is_file(),
            "RAWSR_MANIFEST does not point to a file: {}",
            path.display()
        );
        return Ok(path);
    }
    let mut candidates = Vec::new();
    if let Ok(executable) = std::env::current_exe()
        && let Some(directory) = executable.parent()
    {
        candidates.push(directory.join("models/manifest.json"));
    }
    if let Ok(current) = std::env::current_dir() {
        candidates.push(current.join("models/manifest.json"));
        candidates.push(current.join("../models/manifest.json"));
    }
    candidates.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../models/manifest.json"));
    candidates
        .into_iter()
        .find(|path| path.is_file())
        .context("could not locate models/manifest.json; set RAWSR_MANIFEST")
}

fn cache() -> &'static RwLock<HashMap<u64, Arc<SrgbImage>>> {
    IMAGE_CACHE.get_or_init(|| RwLock::new(HashMap::new()))
}

fn job_cancel_flags() -> &'static RwLock<HashMap<u64, Arc<AtomicBool>>> {
    JOB_CANCEL_FLAGS.get_or_init(|| RwLock::new(HashMap::new()))
}

fn display_error(error: anyhow::Error) -> String {
    format!("{error:#}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_and_region_return_exact_rgba_lengths() {
        let image = Arc::new(SrgbImage::new(vec![0.5; 8 * 4 * 3], 8, 4).unwrap());
        let handle = ImageHandle {
            id: NEXT_IMAGE_ID.fetch_add(1, Ordering::Relaxed),
            width: 8,
            height: 4,
        };
        cache().write().unwrap().insert(handle.id, image);
        let preview = render_preview(handle, 4).unwrap();
        assert_eq!((preview.width, preview.height), (4, 2));
        assert_eq!(preview.bytes.len(), 4 * 2 * 4);
        let region = render_region(
            handle,
            RegionRect {
                x: 2,
                y: 1,
                width: 4,
                height: 2,
            },
            8,
        )
        .unwrap();
        assert_eq!((region.width, region.height), (4, 2));
        assert_eq!(region.bytes.len(), 4 * 2 * 4);
        assert!(close_image(handle).unwrap());
    }

    #[test]
    fn rejects_out_of_bounds_regions() {
        let image = Arc::new(SrgbImage::new(vec![0.0; 2 * 2 * 3], 2, 2).unwrap());
        let handle = ImageHandle {
            id: NEXT_IMAGE_ID.fetch_add(1, Ordering::Relaxed),
            width: 2,
            height: 2,
        };
        cache().write().unwrap().insert(handle.id, image);
        let error = render_region(
            handle,
            RegionRect {
                x: 1,
                y: 1,
                width: 2,
                height: 2,
            },
            2,
        )
        .unwrap_err();
        assert!(error.contains("outside"));
        close_image(handle).unwrap();
    }
}
