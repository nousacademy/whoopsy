import { type Hook, z } from "@hono/zod-openapi";
import type { ErrorHandler } from "hono";
import { HTTPException } from "hono/http-exception";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { Env } from "../env";
import { API_ERROR_CODES, ApiRefusal, type ApiErrorCode, apiError } from "../utils/errors";

/**
 * The published error envelope, and the one hook that produces it.
 *
 * Every non-2xx response this Worker emits has the shape below, including the ones Hono itself would
 * otherwise answer with its own body — a 404 for an unmatched path, a 400 for a failed validation.
 * A client therefore parses one thing, and the OpenAPI document describes it once.
 *
 * The `code` enum is built from `API_ERROR_CODES` rather than typed out, so `utils/errors.ts` is the
 * single source: adding a code there adds it to the runtime union and to the published schema at the
 * same time, and the two cannot drift into the state where a client switches on a code the server
 * can no longer send, or the reverse.
 */

/** The shared error body. Named `Error` so it lands in `components.schemas` under that name. */
export const ErrorSchema = z
  .object({
    error: z.object({
      code: z.enum(API_ERROR_CODES).openapi({
        description: "A stable, machine-readable reason. Switch on this rather than on the message.",
        example: "invalid_request",
      }),
      message: z.string().openapi({
        description: "A human-readable explanation. Not stable — do not parse it.",
        example: "date: must be a calendar day in YYYY-MM-DD form",
      }),
    }),
  })
  .openapi("Error", {
    description: "Every non-2xx response this API produces, from every route.",
  });

/**
 * A response definition for a route's `responses` map.
 *
 * A helper rather than the literal repeated per route, because the literal is four levels deep and
 * the one part that differs between call sites is the description. Getting the nesting wrong in one
 * of them produces a document that is still valid and simply omits that response's schema.
 */
export function errorResponse(description: string) {
  return {
    description,
    content: { "application/json": { schema: ErrorSchema } },
  };
}

/**
 * The 401 every `/v1` operation publishes, for the gate in `app.ts`.
 *
 * **A value rather than a function**, which is the opposite of `errorResponse` above and deliberate.
 * That helper takes a description because each route's 400, 404 and 500 describe *that route's*
 * failures. This one describes a single Worker-wide gate, so a per-operation description would be
 * invented variation — thirty spellings of one sentence, each of which could drift.
 *
 * It is attached per operation rather than declared once as a `securitySchemes` block, so the
 * document keeps the property `openapi.ts` claims for it: every byte generated from the route
 * definitions. A `security` key would also fail *open* — a route mounted tomorrow would silently
 * inherit "requires auth" whether or not the gate covers it.
 */
export const unauthorizedResponse = errorResponse(
  "The `Authorization: Bearer` credential is missing, or it does not match the one this deployment accepts.",
);

/**
 * Maps every Zod validation failure to a `400` in the shared envelope.
 *
 * Installed once on the app rather than passed as a third argument per route, so that a route added
 * later is covered by construction. Without it, `@hono/zod-openapi` answers a failed validation with
 * a bare `400` and no body at all — which is the one response a client cannot tell apart from a
 * proxy error, and the one thing the shared envelope exists to prevent.
 *
 * On success it returns `undefined` and the request proceeds to the handler; the `data` it validated
 * is already on `c.req.valid(...)`, so there is nothing to forward.
 *
 * The message flattens every issue into one line, path-prefixed. A client showing it verbatim is not
 * the intent — the intent is that a developer reading a 400 knows *which* field failed without
 * turning on a debugger, since the alternative is a body that says only "invalid".
 */
export const validationHook: Hook<any, { Bindings: Env }, any, any> = (result, c) => {
  if (result.success) return;

  const message = result.error.issues
    .map((issue) => {
      const path = issue.path.join(".");
      return path === "" ? issue.message : `${path}: ${issue.message}`;
    })
    .join("; ");

  return c.json(apiError("invalid_request", message), 400);
};

/**
 * The status a code travels as.
 *
 * A `Record` over the union rather than a `switch`, so it is **exhaustive by construction**: adding a
 * code to `API_ERROR_CODES` is a compile error here until it is given a status, which is the same
 * one-source rule the published enum follows two files over. A `switch` with no `default` would also
 * be exhaustive, and a `switch` with one — which is what gets written under time pressure — would let
 * a new code travel as whatever the `default` arm happened to say.
 *
 * This is the only place an `ApiErrorCode` becomes a number. The service raises codes and this
 * translates them, so a refusal's *meaning* is decided where the policy is and its *plumbing* is
 * decided here.
 */
const STATUS_FOR: Record<ApiErrorCode, ContentfulStatusCode> = {
  invalid_request: 400,
  unauthorized: 401,
  no_measurement_for_day: 404,
  not_found: 404,
  route_not_found: 404,
  internal_error: 500,
};

export function statusFor(code: ApiErrorCode): ContentfulStatusCode {
  return STATUS_FOR[code];
}

/**
 * The app's single error funnel.
 *
 * Three kinds of failure reach it, and each is answered in the shared envelope — which is what makes
 * "every non-2xx response has this shape" a property of the Worker rather than a habit.
 *
 * An **`ApiRefusal`** — a `RecoveryError` or a `WorkoutError` — is a refusal a service made on
 * purpose, carrying a published code. It is translated, not logged: it is a control-flow outcome, and
 * the request was handled correctly.
 *
 * **The arm tests the base class and not a subclass, and that is the whole reason `ApiRefusal`
 * exists.** Testing `RecoveryError` here was correct while `recoveries` was the only resource; the
 * day `workouts` arrived, a `WorkoutError` would have missed this arm and fallen to the 500 below —
 * answering a caller's malformed body with "the request could not be completed" and an
 * `internal_error`, which reads as a Worker bug and is a validation refusal. It would also have
 * logged, on every bad request, a stack trace that names files and columns. A new resource's refusal
 * type extends `ApiRefusal`, which is what makes that unreachable rather than remembered.
 *
 * An **`HTTPException` with a 400** is Hono refusing the request before any handler ran, and the one
 * reachable instance is a body that is not JSON — `hono/validator`'s `json` target throws it rather
 * than a `SyntaxError`. (A body that is JSON but wrong is *not* this: it is a failed Zod parse, which
 * the hook above answers.) Any other `HTTPException` falls through to the 500 arm deliberately —
 * nothing in this Worker raises one, so one arriving means an assumption is wrong and it should be
 * reported rather than mapped onto a code that would make it look understood.
 *
 * Anything else is a bug. The detail is logged and **not** returned: an internal message names files
 * and columns, and a response body is the one place that reaches a stranger.
 */
export const errorHandler: ErrorHandler<{ Bindings: Env }> = (err, c) => {
  if (err instanceof ApiRefusal) {
    return c.json(err.body, statusFor(err.code));
  }

  if (err instanceof HTTPException && err.status === 400) {
    return c.json(apiError("invalid_request", err.message), 400);
  }

  console.error("unhandled error", err);

  return c.json(
    apiError("internal_error", "the request could not be completed; the detail is in the worker logs"),
    500,
  );
};
