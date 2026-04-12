#!/usr/bin/env python3
"""
Export RF-DETR Nano model to ONNX for DeepStream/TensorRT.

Uses rfdetr's built-in export, then prepends ImageNet normalization so DeepStream
can feed raw [0,1] RGB pixels (net-scale-factor=1/255, model-color-format=1).

Usage:
    python export_rfdetr_onnx.py community-fish-detector-2026.02.02-rf-detr-nano-640.pth

After export, build TensorRT engine:
    trtexec --onnx=cfd-rfdetr-nano-640.onnx \
        --saveEngine=cfd-rfdetr-nano-640.onnx_b3_gpu0_fp16.engine \
        --fp16 --optShapes=images:3x3x640x640
"""

import sys
import os
import shutil
from pathlib import Path


# ImageNet normalization constants
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]


def add_normalization_to_onnx(onnx_path, output_path):
    """Prepend ImageNet normalization (Sub mean, Div std) to an ONNX model."""
    import onnx
    import numpy as np
    from onnx import helper, numpy_helper, TensorProto

    model = onnx.load(onnx_path)
    graph = model.graph

    # Find the original input
    orig_input = graph.input[0]
    orig_input_name = orig_input.name

    # Create a new input name; rename original input to intermediate
    new_input_name = "images"
    intermediate_name = orig_input_name + "_normalized"

    # Create mean and std constants (shape [1, 3, 1, 1] for broadcasting)
    mean_array = np.array(MEAN, dtype=np.float32).reshape(1, 3, 1, 1)
    std_array = np.array(STD, dtype=np.float32).reshape(1, 3, 1, 1)

    mean_init = numpy_helper.from_array(mean_array, name="imagenet_mean")
    std_init = numpy_helper.from_array(std_array, name="imagenet_std")

    # Sub node: subtract mean
    sub_output = orig_input_name + "_sub_mean"
    sub_node = helper.make_node("Sub", inputs=[new_input_name, "imagenet_mean"],
                                outputs=[sub_output], name="preprocess_sub_mean")

    # Div node: divide by std
    div_node = helper.make_node("Div", inputs=[sub_output, "imagenet_std"],
                                outputs=[intermediate_name], name="preprocess_div_std")

    # Rename all references to original input in the graph
    for node in graph.node:
        for i, inp in enumerate(node.input):
            if inp == orig_input_name:
                node.input[i] = intermediate_name

    # Update the graph input name
    orig_input.name = new_input_name

    # Insert normalization nodes at the beginning
    graph.node.insert(0, sub_node)
    graph.node.insert(1, div_node)

    # Add initializers
    graph.initializer.append(mean_init)
    graph.initializer.append(std_init)

    onnx.save(model, output_path)
    print(f"  Added ImageNet normalization to ONNX: mean={MEAN}, std={STD}")


def rename_outputs_and_add_sigmoid(onnx_path):
    """Rename rfdetr outputs and add sigmoid to logits for DeepStream parser.

    rfdetr export produces:
      dets  → boxes (cxcywh [0,1]) — keep as-is
      labels → scores (raw logits) — apply sigmoid so parser sees probabilities
    """
    import onnx
    from onnx import helper, TensorProto

    model = onnx.load(onnx_path)
    graph = model.graph

    # Rename dets → boxes
    for output in graph.output:
        if output.name == "dets":
            for node in graph.node:
                for i, out in enumerate(node.output):
                    if out == "dets":
                        node.output[i] = "boxes"
            output.name = "boxes"
            print(f"  Renamed output: dets → boxes")

    # Add sigmoid to labels, then rename to scores
    for output in graph.output:
        if output.name == "labels":
            old_name = "labels"
            # Rename the producing node's output to an intermediate
            for node in graph.node:
                for i, out in enumerate(node.output):
                    if out == old_name:
                        node.output[i] = "labels_logits"
            # Add Sigmoid node
            sigmoid_node = helper.make_node("Sigmoid", inputs=["labels_logits"],
                                            outputs=["scores"], name="postprocess_sigmoid")
            graph.node.append(sigmoid_node)
            output.name = "scores"
            print(f"  Added sigmoid: labels (logits) → scores (probabilities)")

    onnx.save(model, onnx_path)


def export(weights_path, output_path=None, batch_size=1):
    from rfdetr import RFDETRNano

    if output_path is None:
        output_path = "cfd-rfdetr-nano-640.onnx"

    print(f"Exporting {weights_path} -> {output_path} (batch_size={batch_size})")

    import torch

    # Force CPU for export — host GPU may not be compatible with installed PyTorch CUDA
    torch.cuda.is_available = lambda: False

    # Use rfdetr's built-in export (handles deformable attention, bicubic interp, etc.)
    model = RFDETRNano(pretrain_weights=weights_path, resolution=640, num_classes=1)
    # Force model context device to CPU
    model.model.device = torch.device("cpu")
    model.export(
        output_dir="/tmp/rfdetr_export",
        batch_size=batch_size,
        dynamic_batch=True,
        opset_version=17,
        verbose=False,
    )

    raw_onnx = "/tmp/rfdetr_export/inference_model.onnx"

    # Rename outputs + add sigmoid to logits for DeepStream parser
    rename_outputs_and_add_sigmoid(raw_onnx)

    # Prepend ImageNet normalization so DeepStream can feed raw [0,1] pixels
    add_normalization_to_onnx(raw_onnx, output_path)

    # Clean up
    shutil.rmtree("/tmp/rfdetr_export", ignore_errors=True)

    size_mb = Path(output_path).stat().st_size / 1e6
    print(f"Exported to {output_path} ({size_mb:.1f} MB)")
    print(f"\nNext: trtexec --onnx={output_path} "
          f"--saveEngine={output_path}_b{batch_size}_gpu0_fp16.engine --fp16")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python export_rfdetr_onnx.py <weights.pth> [output.onnx] [batch_size]")
        sys.exit(1)

    weights = sys.argv[1]
    output = sys.argv[2] if len(sys.argv) > 2 else None
    bs = int(sys.argv[3]) if len(sys.argv) > 3 else 1

    export(weights, output, bs)
