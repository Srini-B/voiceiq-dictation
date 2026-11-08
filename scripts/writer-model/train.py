"""mlx_lm.lora with the chunked gated-delta training path patched in, so
Qwen3.5 trains in bounded memory. Arguments go straight to mlx_lm.lora.

usage: python train.py --config train/qwen3_5-2b.yaml
"""
from chunked_gdn import patch

patch()

from mlx_lm import lora  # noqa: E402

lora.main()
