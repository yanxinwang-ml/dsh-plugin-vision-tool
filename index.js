import { basename, extname } from "node:path";
import z from "@deepseek-ai/schemastery";
import { defineTool } from "@deepseek-ai/dsh-tools";
import { createUserMessage } from "@deepseek-ai/dsh-llm";

/**
 * dsh-plugin-vision-tool
 *
 * Registers the `analyze_image` tool on the host. The tool reads an image file
 * from the session workspace, durably commits its bytes through the attachment
 * service (same lifecycle as a user-uploaded image), and sends the image to a
 * dedicated vision model route through the harness's own `ctx.llm` seam. It
 * returns the vision model's text description.
 *
 * The conversation model therefore does NOT need to declare image input: the
 * image only ever travels to the vision route inside this tool, so a text-only
 * model such as DeepSeek-V4-Flash stays the default while image recognition is
 * handled by the configured vision model.
 *
 * Transient provider rate-limit responses (HTTP 429 / Zhipu code 1305, "model
 * too busy") are retried with exponential backoff so a momentarily overloaded
 * free-tier model still yields a result.
 */

export const name = "dsh-plugin-vision-tool";

/** Hard dependency: wait for the tool registry before registering analyze_image
 *  (without `inject`, a fresh startup may activate this plugin before the
 *  `tools` service mounts, and apply() would then return without registering). */
export const inject = ["tools"];

/** Provider route and vision model, configurable through the plugin row's `config`. */
export const Config = z.object({
  provider: z.string().default("zhipu"),
  model: z.string().default("glm-4.6v-flash")
});

const DEFAULT_QUESTION = "请详细描述这张图片的内容：包括主体、场景、文字、图表、数据以及任何值得注意的细节。";

const SYSTEM_PROMPT = [
  "You are an image recognition assistant.",
  "The user provides one image. Look at it carefully and answer the user's question about it.",
  "Answer in the same language the question is written in.",
  "Be precise about text, numbers, charts, and layout when they are visible."
].join(" ");

/** Extensions `analyze_image` accepts; magic-byte validation at the attachment service stays authoritative. */
const IMAGE_EXTENSIONS = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".gif": "image/gif"
};

/** Max whole-stream attempts against a transient provider rate limit. */
const MAX_STREAM_ATTEMPTS = 4;
/** Base backoff between retries, in milliseconds (attempt 2 waits base, 3 waits base*2, ...). */
const RETRY_BACKOFF_MS = 3000;

/** True when a provider failure message looks like a transient capacity/rate limit. */
function isRetryableLimit(message) {
  return /429|\b1305\b|访问量过大|流量过大|too busy|rate\s*limit|overloaded/i.test(message);
}

/** Sleep with abort support. */
function sleep(ms, signal) {
  return new Promise((resolve) => {
    if (signal?.aborted) {
      resolve();
      return;
    }
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
  });
}

export function apply(ctx, config) {
  const provider = config.provider;
  const model = config.model;
  const tools = ctx.get("tools");
  if (tools === undefined) return;
  const systemPrompt = ctx.get("systemPrompt");
  if (systemPrompt !== undefined) {
    systemPrompt.section({
      name: "tool:analyze-image",
      order: 100,
      text: "Use the analyze_image tool to recognize or describe an image file. The current conversation model may be text-only: analyze_image sends the image to a dedicated vision model and returns its text description, so the image never needs to enter the conversation model itself."
    });
  }
  tools.register(defineTool({
    name: "analyze_image",
    description: "Recognize and describe an image file using a dedicated vision model. The current conversation model does not need image support. Paths are resolved against the session workspace, same as the read tool.",
    parameters: {
      file_path: {
        type: "string",
        required: true,
        description: "Path to the image file (PNG/JPEG/WebP/GIF), resolved by the filesystem backend."
      },
      question: {
        type: "string",
        description: "Optional specific question about the image. Defaults to a general detailed description."
      }
    },
    output: {
      schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          description: {
            type: "string",
            required: true
          }
        }
      },
      render: (_args, value) => [{
        type: "text",
        text: value.description
      }]
    },
    isConcurrencySafe: () => true,
    timeoutMs: 150000,
    async execute(args, exec) {
      if (typeof args.file_path !== "string" || args.file_path.trim().length === 0) {
        throw new Error("file_path must be a non-empty string");
      }
      const mediaType = IMAGE_EXTENSIONS[extname(args.file_path).toLowerCase()];
      if (mediaType === undefined) {
        throw new Error(`cannot recognize "${args.file_path}": analyze_image only accepts PNG/JPEG/WebP/GIF paths`);
      }
      const fs = ctx.get("fs");
      if (fs === undefined) throw new Error(`cannot recognize "${args.file_path}": no filesystem service is mounted`);
      const attachments = ctx.get("attachments");
      if (attachments === undefined) throw new Error(`cannot recognize "${args.file_path}": no attachment service is mounted`);
      const llm = ctx.get("llm");
      if (llm === undefined) throw new Error(`cannot recognize "${args.file_path}": no LLM service is mounted`);
      if (!attachments.imageLimits.mediaTypes.includes(mediaType)) {
        throw new Error(`cannot recognize "${args.file_path}": ${mediaType} images are not accepted by this deployment`);
      }

      // Resolve against the calling session's workspace cwd, mirroring the fs tools.
      const sessionCwd = exec.agent?.session?.header?.cwd;
      const target = await fs.resolve(args.file_path, {
        ...(sessionCwd === undefined ? {} : { cwd: sessionCwd }),
        signal: exec.signal
      });
      const info = await fs.stat(target, exec.signal);
      if (info === undefined) throw new Error(`cannot recognize "${target.displayPath}": not found`);
      if (info.type !== "file") throw new Error(`cannot recognize "${target.displayPath}": not a regular file`);

      const byteCap = Math.min(attachments.imageLimits.maxImageBytes, attachments.imageLimits.maxMessageImageBytes);
      const data = await fs.readBytes(target, exec.signal, byteCap);

      let ref;
      try {
        ref = await attachments.saveImage({
          data,
          mediaType,
          name: basename(target.displayPath)
        });
      } catch (error) {
        throw new Error(`cannot recognize "${target.displayPath}": image bytes were rejected (${error instanceof Error ? error.message : String(error)})`, { cause: error });
      }

      const question = typeof args.question === "string" && args.question.trim().length > 0
        ? args.question
        : DEFAULT_QUESTION;
      const message = createUserMessage({
        content: [
          { type: "text", text: question },
          { type: "image", attachment: ref }
        ],
        source: { kind: "plugin", plugin: name }
      });

      let textParts = [];
      let attempt = 1;
      for (;;) {
        if (exec.signal?.aborted) throw new Error("image recognition aborted");
        try {
          const chunks = llm.stream({
            provider,
            model,
            system: SYSTEM_PROMPT,
            messages: [message],
            signal: exec.signal
          });
          for await (const chunk of chunks) {
            if (chunk.type === "text-delta") {
              textParts.push(chunk.text);
            } else if (chunk.type === "finish") {
              if (chunk.reason?.kind === "error") {
                const failure = chunk.reason.failure;
                throw new Error(failure?.message ?? String(failure));
              }
              if (chunk.reason?.kind === "aborted") {
                throw new Error("vision model call was aborted");
              }
            }
          }
          break;
        } catch (error) {
          const failureMessage = error instanceof Error ? error.message : String(error);
          const retryable = isRetryableLimit(failureMessage);
          if (!retryable || attempt >= MAX_STREAM_ATTEMPTS) {
            throw new Error(`image recognition via ${model} failed: ${failureMessage}`);
          }
          textParts = [];
          await sleep(attempt * RETRY_BACKOFF_MS, exec.signal);
          attempt += 1;
        }
      }

      const description = textParts.join("").trim();
      if (description.length === 0) throw new Error(`image recognition via ${model} returned an empty description`);

      ctx.emit("fs/observed", target, {
        kind: "present",
        version: info.version
      }, exec);

      return { description };
    },
    presentCall(args) {
      return {
        card: "generic",
        title: `Recognize image ${args.file_path}`,
        kind: "read",
        locations: [{ path: args.file_path }]
      };
    }
  }));
}
