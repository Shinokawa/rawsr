#!/usr/bin/env python3
"""Generate the deterministic dynamic-shape 2x nearest-neighbor ONNX test model."""

from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "assets" / "test"


def make_sr_model() -> onnx.ModelProto:
    input_info = helper.make_tensor_value_info(
        "input", TensorProto.FLOAT, [1, 3, "height", "width"]
    )
    output_info = helper.make_tensor_value_info(
        "output", TensorProto.FLOAT, [1, 3, "height_x2", "width_x2"]
    )
    roi = numpy_helper.from_array(np.asarray([], dtype=np.float32), name="roi")
    scales = numpy_helper.from_array(
        np.asarray([1.0, 1.0, 2.0, 2.0], dtype=np.float32), name="scales"
    )
    resize = helper.make_node(
        "Resize",
        inputs=["input", "roi", "scales"],
        outputs=["output"],
        mode="nearest",
        coordinate_transformation_mode="asymmetric",
        nearest_mode="floor",
    )
    graph = helper.make_graph(
        [resize],
        "rawsr_tiny_sr_x2",
        [input_info],
        [output_info],
        initializer=[roi, scales],
    )
    return helper.make_model(
        graph,
        producer_name="rawsr",
        opset_imports=[helper.make_opsetid("", 13)],
    )


def make_identity_model() -> onnx.ModelProto:
    input_info = helper.make_tensor_value_info(
        "input", TensorProto.FLOAT, [1, 3, "height", "width"]
    )
    output_info = helper.make_tensor_value_info(
        "output", TensorProto.FLOAT, [1, 3, "height", "width"]
    )
    identity = helper.make_node("Identity", inputs=["input"], outputs=["output"])
    graph = helper.make_graph(
        [identity], "rawsr_tiny_denoise", [input_info], [output_info]
    )
    return helper.make_model(
        graph,
        producer_name="rawsr",
        opset_imports=[helper.make_opsetid("", 13)],
    )


def write_model(name: str, model: onnx.ModelProto) -> None:
    path = OUTPUT_DIR / name
    onnx.checker.check_model(model)
    onnx.save_model(model, path)
    print(f"wrote {path} ({path.stat().st_size} bytes)")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    write_model("tiny_sr_x2.onnx", make_sr_model())
    write_model("tiny_denoise.onnx", make_identity_model())


if __name__ == "__main__":
    main()
