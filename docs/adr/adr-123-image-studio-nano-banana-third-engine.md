# ADR-123: Image Studio gets a third engine — nano banana through the Gemini web proxy

- **Status**: Accepted
- **Date**: 2026-11-04
- **Issue**: GUL-893
- **Related**: GUL-28 (FLUX.2-klein as the second engine), the `gemini-web2api-proxy` skill, GUL-896 (the proxy's restart policy)

## Context

Image Studio (`gulasz101/ideogram4-local`) makes the images for the blog and LinkedIn. It had two
engines on one SQLite queue: **Ideogram 4** (canonical JSON prompts, ~21 minutes per 1216×832 render,
a baked-in prompt-vocabulary safety filter that grey-boxes ordinary scenes) and **FLUX.2-klein**
(natural language, ~3 minutes, 4B draft quality).

The backlog is 153 unpublished posts and each one wants a header. At 21 minutes a render, and with a
filter that fails a prompt for its vocabulary rather than its pixels, the queue — not the writer — is
the bottleneck. Matejko (the designer agent) had been working the backlog for weeks.

Separately, the homelab already runs **`gemini-web2api-go`** on the M1 Max (`127.0.0.1:8083`): a proxy
that reverse-engineers `gemini.google.com` into an OpenAI-compatible API using an exported Firefox
cookie, with no Google API key and no paid quota. It backs ZeroClaw. It also exposes the web app's
image tool as the model **`gemini-image`** — which is Gemini's "nano banana".

The owner's instruction was direct: use that engine too, and let Matejko finish the remaining posts
with it.

## Decision

**`nanobanana` becomes the third engine on the existing queue and worker**, and the default engine for
the remaining backlog posts. It is not a local model and it costs no GPU time: the worker posts one
chat completion to the proxy (`POST /v1/chat/completions`, `model: "gemini-image"`), the reply carries
the picture inline as `data:image/jpeg;base64,…` inside a markdown link, and the worker decodes it to
the job's output path.

Measured on the M1 Max, 2026-11-04: **11.5–12.3 s** per image, 1376×768 (sometimes 1584×672) JPEG, no
watermark, clean first-try render. Roughly **100× faster than Ideogram 4** and **15× faster than FLUX**.

Constraints accepted with it, because they come from the upstream and not from us:

- **The size is not ours to choose.** The web tool returns what it returns; `-W/-H` are recorded but
  not enforced.
- **No seed**, and no image-to-image editing through this wrapper yet.
- **A live cookie is a hard dependency.** A stale session or an exhausted quota makes the model answer
  in prose; the job fails with the model's words as its error, which is the fastest diagnosis there is.
- **Rate limits are per exit IP.** About one image a minute is calm; a 150-prompt burst gets the
  account throttled for ~2 hours and takes ZeroClaw's model backend down with it. Hence a pacing rule
  in Matejko's skill, not a promise of a fast backlog.

The API key is not a Google key: it is the proxy's own `sk-gemini-…` token, kept on the Max in a 0600
file at `~/.config/image-studio/gemini-web.key` (or `GEMINI_WEB_API_KEY` in the worker environment).
Nothing secret ever reaches the public repo.

## Consequences

- The backlog is no longer queue-bound. A post's header is a 12-second job, so Matejko can afford
  variants and re-rolls instead of one careful shot.
- **The whole studio now depends on one grey-area container.** The proxy has `restart=no`, runs a
  `:latest` tag and had been dead for 34 hours before this work started, unnoticed. That is a standing
  risk to ZeroClaw too, and it is scoped as GUL-896 rather than accepted here.
- Image quality is the web model's, not a tuned local pipeline: no readable in-image text worth
  shipping, less control, and a vendor that can change the backend under the "model" name at any time.
  Ideogram 4 stays the keeper engine for anything needing an exact canvas or legible type.
- Library records now carry a third label, and Matejko's skill has to state which engine a post should
  use rather than assuming one.

## Alternatives

- **Ideogram 4 only.** Rejected: the render time and the grey-box filter are the actual problem.
- **The official Gemini API (`google-genai`, `GEMINI_API_KEY`).** Cleaner contract, real sizes, a
  documented model id — but it needs a paid/allowanced key, and the homelab's Google key has already
  lost its Pro tier twice. It also throws away an asset the homelab already pays for in complexity.
- **A bigger local model.** Rejected on time: 21 min → maybe 7 min is still 7 minutes, and it keeps the
  GPU busy for hours on a backlog.
- **A new service/port for the web tool.** Rejected: the proxy is already there and already on the
  trusted path to ZeroClaw; a third engine on the existing queue is a smaller surface.

## When to revisit

- The proxy breaks repeatedly, or Google tightens what a cookie session may do (then: official API, or
  back to Ideogram for the backlog).
- We need exact sizes or image-to-image editing for a series (the proxy's native `/v1beta` API in a
  later release can do that; v4.22.0 cannot).
- The backlog is finished: then this engine is optional, and the decision narrows to "keep it for
  drafts".

## Evidence

- PR `gulasz101/ideogram4-local#7`, merged `14a6625`.
- Live job `bLnRpFS8X2g`: `imagegen submit --engine nanobanana` from the Air → 1376×768 JPEG, 110,745
  bytes, fetched to `~/image-studio/staging/2026-11-04/gul893-live2-79a54146.png`.
- Direct engine run on the Max: `11.5 s`, `1376x768`, `model=gemini-image`.
- Runbook: `gulasz101/ideogram4-local` `references/nanobanana-engine.md`; ops memory in the
  `gemini-web2api-proxy` and `image-studio` skills.
