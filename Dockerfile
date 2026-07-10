# Claude Code CLI image for the copy-lane agent runner's Phase-A filesystem jail.
# The runner runs:  docker run --rm --cap-drop ALL --security-opt no-new-privileges \
#   --user 1000 -v $RUNNER_TEMP/target:/work -w /work \
#   -e ANTHROPIC_BASE_URL=https://ai.stitchtec.dev -e ANTHROPIC_API_KEY=<run token> \
#   <this image> --allowedTools "Read Write Edit Glob Grep" --max-turns 20 -p "<brief>"
# So ENTRYPOINT must be the Claude Code CLI and the image must run as uid 1000 with only /work writable.
FROM node:20-slim

# Pin the CLI version (bump deliberately; the workflow pins THIS image by @sha256 digest).
RUN npm install -g @anthropic-ai/claude-code@2.1.206 \
  && useradd -m -u 1000 agent || true

USER 1000
WORKDIR /work
ENTRYPOINT ["claude"]
