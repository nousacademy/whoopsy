import type { Env } from "./env";

/**
 * The Worker's entry point.
 *
 * **No sync is implemented.** Every request reaches the 501 below. This file exists so that
 * `wrangler.toml`'s `main` points at something real — a config naming a missing entry point fails
 * `wrangler dev` with an error about the path rather than about the missing feature, which is the
 * wrong thing to be told when the missing feature is the whole story.
 *
 * The three directories beside this one are the split the sync will be built on:
 *
 *   routes/        Hono controllers. Parse a request, call a service, shape a response. No SQL.
 *   services/      Orchestration and policy — what a sync is allowed to overwrite, what a device
 *                  may see. No SQL either.
 *   repositories/  The D1 and R2 adapters — the only files that know a table or a bucket exists.
 *
 * They are empty on purpose. The structure is the part that is settled; the behaviour is the next
 * pass, and a stub that returns a real answer would be a claim about a system that does not exist.
 */
export default {
  fetch(): Response {
    return new Response("Whoopsy sync is not implemented yet.\n", {
      status: 501,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
} satisfies ExportedHandler<Env>;
