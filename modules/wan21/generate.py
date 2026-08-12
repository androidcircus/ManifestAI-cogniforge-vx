#!/usr/bin/env python3
# modules/wan21/generate.py
# Wan 2.1 image-to-video CLI entrypoint.
#
# Argo Workflows runs THIS instead of the uvicorn server, because a workflow
# step must start, produce a file, and exit:
#
#   python generate.py \
#     --image-url https://example.com/cat.jpg \
#     --duration 5 \
#     --output /app/outputs/out.mp4
import argparse
import os
import sys
import time
import torch


def parse_args():
    parser = argparse.ArgumentParser(description="Wan 2.1 image-to-video (CLI)")
    parser.add_argument("--image-url", required=True, help="URL of the input image")
    parser.add_argument("--duration", type=int, default=5, help="video length in seconds")
    parser.add_argument("--output", default="/app/outputs/out.mp4", help="output mp4 path")
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--width", type=int, default=832)
    parser.add_argument("--steps", type=int, default=50)
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)

    print(f"[wan21] model:   {os.environ.get('WAN_MODEL_ID', 'Wan-AI/Wan2.1-I2V-14B-480P-Diffusers')}")
    print(f"[wan21] image:   {args.image_url}")
    print(f"[wan21] output:  {args.output}")
    print(f"[wan21] gpu:     {torch.cuda.is_available()}")
    start = time.time()

    from diffusers import WanImageToVideoPipeline
    from diffusers.utils import export_to_video, load_image
    from transformers import T5EncoderModel

    model_id = os.environ.get("WAN_MODEL_ID", "Wan-AI/Wan2.1-I2V-14B-480P-Diffusers")
    text_encoder = T5EncoderModel.from_pretrained(
        model_id, subfolder="text_encoder", torch_dtype=torch.bfloat16
    )
    pipe = WanImageToVideoPipeline.from_pretrained(
        model_id, text_encoder=text_encoder, torch_dtype=torch.bfloat16
    )
    if torch.cuda.is_available():
        pipe.to("cuda")
    else:
        pipe.enable_model_cpu_offload()

    image = load_image(args.image_url).convert("RGB")
    frames = pipe(
        image=image,
        duration=args.duration * 16,
        num_frames=16,
        height=args.height,
        width=args.width,
        guidance_scale=5.0,
        num_inference_steps=args.steps,
        generator=torch.manual_seed(args.seed),
    ).frames[0]

    export_to_video(frames, args.output, fps=16)
    print(f"[wan21] wrote {os.path.getsize(args.output)} bytes in "
          f"{time.time() - start:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
