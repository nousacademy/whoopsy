/**
 * HTTP controllers — the Worker's edge.
 *
 * Empty. A route here parses a request, calls a service, and shapes a response; it holds no SQL and
 * no policy, so that the question "what does this endpoint do" is answered by reading one file
 * rather than by following a query into a table.
 *
 * The OpenAPI document in `shared/openapi.json` is generated from these, which is why the schemas
 * are declared here as `@hono/zod-openapi` route definitions rather than as hand-written JSON.
 */
export {};
