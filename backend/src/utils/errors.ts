/**
 * The error envelope every failure in this Worker answers with.
 *
 * One shape — `{ "error": { "code": "...", "message": "..." } }` — so a client parses one thing.
 * This is the envelope `bodymap-api` already speaks, adopted here so a client that talks to that
 * Worker does not need a second parser.
 *
 * `API_ERROR_CODES` is the single source: the TypeScript union and the Zod enum published in the
 * OpenAPI document are both derived from this array, so the runtime helpers and the published
 * schema cannot drift. Adding a code is one line here.
 *
 * There is deliberately no `param`/`allowed` detail on this Worker's errors yet. `bodymap-api`
 * attaches them for query-parameter failures; nothing here needs it, and an unused field in a
 * published contract is a field a client will start depending on.
 */
export const API_ERROR_CODES = [
  /** The request was malformed — a bad path parameter, query, header or body. */
  "invalid_request",
  /**
   * The `Authorization: Bearer` credential is missing, or it is not the one this deployment accepts.
   *
   * One code for both, deliberately: telling "you sent no token" apart from "you sent the wrong one"
   * is an oracle this API has no reason to publish. Distinct from `internal_error`, which is what an
   * *unarmed* deployment answers — a missing `SYNC_API_TOKEN` is the operator's problem and not a
   * refusal of the caller.
   */
  "unauthorized",
  /** The day asked for exists as a day but carries no measurement. See `GET .../{date}`. */
  "no_measurement_for_day",
  /** The addressed thing is not here. */
  "not_found",
  /** No route matches the method and path. */
  "route_not_found",
  /** Anything unhandled. The detail is logged, never returned. */
  "internal_error",
] as const;

export type ApiErrorCode = (typeof API_ERROR_CODES)[number];

/** The body of every non-2xx response this Worker produces. */
export interface ApiErrorBody {
  readonly error: {
    readonly code: ApiErrorCode;
    readonly message: string;
  };
}

/**
 * Build an error body.
 *
 * A constructor rather than an object literal at each throw site, so the envelope's nesting is
 * written once. A second literal somewhere is how a client ends up parsing two shapes.
 */
export function apiError(code: ApiErrorCode, message: string): ApiErrorBody {
  return { error: { code, message } };
}

/**
 * A refusal a layer below the route made on purpose, carrying the code the API publishes for it.
 *
 * Each resource has its own named subclass — `RecoveryError`, `WorkoutError` — because the name is
 * what reaches the log, and a stack saying `ApiRefusal` says nothing about which resource refused.
 * What the subclass does *not* do is restate the envelope or the status lookup: `body` is built
 * here, once, and `routes/errors.ts` catches this type alone.
 *
 * **That single catch is the reason this class exists.** The funnel used to test
 * `err instanceof RecoveryError`, which meant every new resource needed a second arm added to a file
 * that has nothing to do with it — and the failure mode of forgetting is not a compile error, it is
 * a 500 with the detail in the logs and a published `internal_error` for what was a perfectly
 * ordinary 400. A funnel that needs an arm per resource is a funnel that will silently mis-handle
 * the sixth one, so the shared half of the refusal lives here instead.
 */
export class ApiRefusal extends Error {
  constructor(
    readonly code: ApiErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "ApiRefusal";
  }

  get body(): ApiErrorBody {
    return apiError(this.code, this.message);
  }
}
