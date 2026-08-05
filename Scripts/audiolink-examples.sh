#!/usr/bin/env bash
set -euo pipefail

# Run from the repository root. Set AUDIO_LINK_CLI to a built binary when
# running repeatedly; the default uses SwiftPM and therefore needs no guessed
# build-artifact path.
set -- "${@:-batch-analyze}"
COMMAND="$1"

case "$COMMAND" in
  batch-analyze)
    REFERENCE="${2:?reference WAV is required}"
    RECORDINGS_DIR="${3:?recordings directory is required}"
    OUTPUT_DIR="${4:-results}"
    if [[ -n "${AUDIO_LINK_CLI:-}" ]]; then
      "$AUDIO_LINK_CLI" analyze-files --reference "$REFERENCE" --input-directory "$RECORDINGS_DIR" \
        --output-directory "$OUTPUT_DIR" --continue-on-error --json
    else
      swift run --package-path Packages/AudioLinkAutomation audiolink analyze-files \
        --reference "$REFERENCE" --input-directory "$RECORDINGS_DIR" \
        --output-directory "$OUTPUT_DIR" --continue-on-error --json
    fi
    ;;
  generate-signal)
    OUTPUT="${2:-validation-sweep.wav}"
    swift run --package-path Packages/AudioLinkAutomation audiolink generate-signal \
      --output "$OUTPUT" --sample-rate 48000 --duration 2 --json
    ;;
  run-plan)
    CONFIG="${2:?plan JSON is required}"
    swift run --package-path Packages/AudioLinkAutomation audiolink run-plan --config "$CONFIG" --json
    ;;
  export-csv)
    INPUT="${2:?report JSON is required}"
    OUTPUT="${3:-report.csv}"
    swift run --package-path Packages/AudioLinkAutomation audiolink export-report \
      --input "$INPUT" --format csv --output "$OUTPUT" --json
    ;;
  benchmark-device)
    # Deliberately returns exit code 4 until a headless hardware adapter is
    # implemented; it must never claim a benchmark was performed.
    swift run --package-path Packages/AudioLinkAutomation audiolink benchmark-device --json
    ;;
  ci-file-analysis)
    REFERENCE="${2:?reference WAV is required}"
    RECORDING="${3:?recording WAV is required}"
    swift run --package-path Packages/AudioLinkAutomation audiolink analyze-files \
      --reference "$REFERENCE" --recording "$RECORDING" --json --quiet
    ;;
  *)
    echo "usage: $0 {batch-analyze|generate-signal|run-plan|export-csv|benchmark-device|ci-file-analysis} ..." >&2
    exit 2
    ;;
esac
