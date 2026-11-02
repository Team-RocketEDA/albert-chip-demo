#!/usr/bin/env bash
# Fetch the gated Meta checkpoint with YOUR HuggingFace account.
# Usage: HF_TOKEN=hf_xxx ./fetch_weights.sh   (token needs license accept on
#        https://huggingface.co/facebook/MobileLLM-125M first)
set -u
REPO_ID="facebook/MobileLLM-125M"
DEST="$(cd "$(dirname "$0")" && pwd)/mobilellm-125m"
: "${HF_TOKEN:?Set HF_TOKEN to your HuggingFace token first.}"

if command -v hf >/dev/null 2>&1; then
  hf download "$REPO_ID" --repo-type model --token "$HF_TOKEN" --local-dir "$DEST"
elif command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$REPO_ID" --token "$HF_TOKEN" --local-dir "$DEST"
else
  echo "Need 'hf' or 'huggingface-cli'. Install: pip install -U 'huggingface_hub[cli]'"
  exit 1
fi

echo "--- inventory ---"
ls -la "$DEST"
echo "--- compare against MANIFEST.md; report anything missing ---"
