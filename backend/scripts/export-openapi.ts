import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
// `URL` is imported rather than used as the ambient global, and that is load-bearing: this project
// loads `@cloudflare/workers-types` (it imports `src/app`, whose `Env` names `D1Database`), and that
// package declares a global `URL` which is *not* the one `fileURLToPath` accepts. The named import
// from `node:url` is the same class at runtime and the right one at compile time.
import { fileURLToPath, URL } from "node:url";
import { createApp } from "../src/app";
import { API_PREFIX, RELATIVE_ORIGIN, openApiConfig, serialiseOpenApiDocument } from "../src/openapi";

/**
 * Writes the API contract to `shared/`: one file per resource, and no whole document.
 *
 * This is the **second reading of one source**. The Worker serves the whole document live at
 * `GET /openapi.json`; this script produces the committed copy the client reads. Both call
 * `createApp()` and `getOpenAPI31Document(openApiConfig)` and both serialise with
 * `serialiseOpenApiDocument`, so the two cannot say different things.
 *
 * ## One folder per resource, and nothing at the root
 *
 * The whole document is ~250 KB and 41 schemas, which is more than a reader wants in one buffer, so
 * it is not committed at all — the deployment serves it. Every resource instead gets a folder named
 * after its path segment, holding **a valid OpenAPI document in its own right**: its own `paths`, and
 * only the components those paths reach. `shared/strains/openapi.json` is the strain resource's
 * contract and nothing else; the eight of them plus `health` add up to the full document's paths,
 * with duplicated schemas because each file has to stand alone. `shared/README.md` is the only
 * hand-written file in the folder and says exactly that to a reader who opens it.
 *
 * **`pruneStaleSlices` is why the root stays empty.** A whole-document `shared/openapi.json` used to
 * be written here; removing it from the generator without removing it from the tree would leave a
 * second contract that no longer had a producer, so this script deletes any such file it finds before
 * writing the slices.
 *
 * **These are generated, exactly like the file above.** They are not the source of anything, they are
 * never hand-edited, and the gate fails if a committed slice differs from the one the code produces —
 * or if a stale folder survives a resource being renamed, which is why this script prunes every
 * `shared/<folder>/openapi.json` it did not just write. A slice is derived from the same document, so
 * a route added to the Worker appears in both places at once and a route renamed cannot leave half
 * the tree describing the old name.
 *
 * **The slice list is derived from `paths`, not typed in.** The folders are the first segment under
 * `API_PREFIX` for each published path, plus `health` for the one path outside it — the same
 * derivation the gate's "every published path carries the prefix" assertion relies on. A resource
 * mounted tomorrow gets a folder the next time this runs; a resource mounted under a segment this
 * script cannot see is the one case that would need it taught something.
 *
 * ## The rest of the file's behaviour
 *
 * **It writes unconditionally, and that is what makes the gate work.** A run that changed nothing
 * rewrites identical bytes, so `git diff --exit-code -- shared` afterwards answers one question —
 * *is the committed contract the one the code generates* — rather than two. A script that skipped the
 * write on "no change" would leave a stale file looking current.
 *
 * **Paths are resolved from this file and never from the working directory.** `npm --prefix backend
 * run openapi` and a bare `tsx scripts/export-openapi.ts` from inside `backend/` both reach this
 * file, and `../shared/` means something different under each. `import.meta.url` is the anchor that
 * makes the two agree — the same reason `vitest.config.ts` resolves the migrations directory this
 * way, and the reason the generated files land in the repo rather than in whichever directory
 * happened to be current.
 *
 * **It runs under `tsx` and not under `node`.** Node 26 strips types by default, but its ESM
 * resolver still demands an explicit extension on every relative import, and this Worker's sources
 * are written extensionlessly under `moduleResolution: "bundler"` — so `node` fails on the first
 * `import` above. `tsx` resolves bundler-style, which is the only reason it is a devDependency.
 *
 * **The committed contract carries a relative origin and the served one an absolute, and that is the
 * asymmetry between the two readings.** `servers[0].url` is the only field in the document that is a
 * fact about a *deployment* rather than about the API — and this file is **committed**, so it must not
 * name one. It writes `RELATIVE_ORIGIN`, the OpenAPI relative form meaning *the origin this document
 * was fetched from*: true of every deployment that serves it, and a single operator's subdomain in a
 * repository everyone reads if it were a hostname instead. The Worker's own reading takes the
 * absolute form, `app.ts` naming the origin each request arrived on, which is why the shell gate
 * drops exactly that line. **There is nothing to configure here**, deliberately: an env var that let
 * a clone write its own hostname into this file would reintroduce the one thing the relative origin
 * exists to keep out of it.
 */

/**
 * The fields this script reads out of a generated document.
 *
 * Deliberately narrow rather than the generator's own type: this file slices a value it does not
 * construct, and `components` here is walked by name, which the generator's type does not describe
 * in a way that is pleasant to consume. `paths` and each component group are `unknown`-valued
 * properties because the script copies them opaquely — it never reads a schema's fields.
 */
interface Document {
  openapi: string;
  info: { title: string; version: string; description?: string };
  servers?: unknown[];
  paths: Record<string, Record<string, unknown>>;
  components?: Record<string, Record<string, unknown>>;
}

/**
 * One slice's identity: the folder it is written to and the path prefix it covers.
 *
 * `health` is in the list by hand because it is the one published path outside `API_PREFIX`. Every
 * other entry is derived from the document (`resourceSegments`), so a new resource needs no edit
 * here.
 */
interface Slice {
  readonly folder: string;
  readonly prefix: string;
}

/** The path prefix a resource slice covers, e.g. `/v1/strains`. */
function pathMatches(path: string, prefix: string): boolean {
  return path === prefix || path.startsWith(`${prefix}/`);
}

/**
 * The resource segments this document publishes, in first-appearance order.
 *
 * A segment is the first path component under `API_PREFIX`, which is the same string the mount table
 * interpolates — so the folder name is the URL segment rather than a camel-cased resource type. That
 * is deliberate: a reader looking for the contract of `/v1/step-counts` opens
 * `shared/step-counts/openapi.json`, and no translation step is needed to guess it.
 */
function resourceSegments(document: Document): string[] {
  const prefixed = `${API_PREFIX}/`;
  const segments = new Set<string>();

  for (const path of Object.keys(document.paths)) {
    if (!path.startsWith(prefixed)) continue;
    const segment = path.slice(prefixed.length).split("/")[0];
    if (segment !== undefined && segment !== "" && !segment.startsWith("{")) {
      segments.add(segment);
    }
  }

  return [...segments];
}

/** Every `$ref` string anywhere inside `value`, in traversal order. */
function collectRefs(value: unknown, into: Set<string>): void {
  if (Array.isArray(value)) {
    for (const item of value) collectRefs(item, into);
    return;
  }
  if (value === null || typeof value !== "object") return;

  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    if (key === "$ref" && typeof child === "string") {
      into.add(child);
    } else {
      collectRefs(child, into);
    }
  }
}

/** A JSON Pointer segment, unescaped the way RFC 6901 defines it. */
function pointerSegment(raw: string): string {
  return raw.replaceAll("~1", "/").replaceAll("~0", "~");
}

/**
 * The component a `#/components/<group>/<name>` reference names, or `null`.
 *
 * `null` for every other shape of reference and for a name this document does not hold. Kept as one
 * function because the closure below and the resolvability assertion at the write site have to agree
 * about what a reference means — two parsers of the same pointer would be free to disagree about a
 * name and only one of them would be checking the other's work.
 */
function componentFor(
  document: Document,
  ref: string,
): { group: string; name: string; value: unknown } | null {
  const match = /^#\/components\/([^/]+)\/(.+)$/.exec(ref);
  if (match === null) return null;
  const group = match[1];
  const rawName = match[2];
  if (group === undefined || rawName === undefined) return null;

  const name = pointerSegment(rawName);
  const value = document.components?.[group]?.[name];
  return value === undefined ? null : { group, name, value };
}

/**
 * The components the given roots reference, transitively, in the shape `components` takes.
 *
 * **A slice has to be a valid document, not a fragment.** Every `$ref` in the paths it keeps points
 * at `#/components/...`, and a file carrying the paths without the schemas they name is a document no
 * OpenAPI validator or client generator can resolve. So the closure is computed here rather than
 * copied wholesale: `shared/strains/openapi.json` holds `Strain` and the few schemas `Strain` itself
 * refers to, and not the 34 belonging to other resources.
 *
 * A reference to a component that does not exist is skipped rather than thrown on. The generator
 * cannot produce one — a `$ref` comes from a registered schema — and failing the whole export over a
 * dangling pointer would turn a contract detail into a broken build; the slice simply lacks it, and
 * the next regeneration after the schema is registered carries it. The write site asserts that the
 * result has no dangling reference left, which is the check that keeps this skip from hiding a bug
 * in the walk itself.
 */
function reachableComponents(
  document: Document,
  roots: readonly unknown[],
): Record<string, Record<string, unknown>> {
  const pending = new Set<string>();
  for (const root of roots) collectRefs(root, pending);

  const included: Record<string, Record<string, unknown>> = {};
  const queue = [...pending];

  while (queue.length > 0) {
    const ref = queue.pop();
    if (ref === undefined) continue;

    const component = componentFor(document, ref);
    if (component === null) continue;

    const target = (included[component.group] ??= {});
    if (target[component.name] !== undefined) continue;
    target[component.name] = component.value;

    const nested = new Set<string>();
    collectRefs(component.value, nested);
    for (const child of nested) {
      if (!pending.has(child)) {
        pending.add(child);
        queue.push(child);
      }
    }
  }

  return included;
}

/**
 * Every `#/components/...` reference in `value` that the same document cannot resolve.
 *
 * The export throws on a non-empty result rather than writing the file. A slice is what a reader
 * opens instead of the 259 KB document, so a slice with a dangling `$ref` is a contract that
 * describes schemas that are not there — and it would be committed, because the gate only asks
 * whether the committed bytes are the generated ones.
 */
function unresolvedRefs(value: unknown): string[] {
  const refs = new Set<string>();
  collectRefs(value, refs);

  return [...refs].filter(
    (ref) => ref.startsWith("#/components/") && componentFor(value as unknown as Document, ref) === null,
  );
}

/**
 * The slice document for one folder: the whole document's identity, its own paths, and the components
 * they reach.
 *
 * `info.title` gains the folder as a suffix so an editor tab named `openapi.json` still says which
 * resource it is, and the description gains one sentence saying so in words. Everything else is
 * copied from the full document untouched, including `servers` — a slice is a reading of the same
 * contract, so it must not describe a different origin or a different version.
 */
function sliceFor(document: Document, slice: Slice): Record<string, unknown> {
  const paths: Record<string, Record<string, unknown>> = {};
  for (const [path, item] of Object.entries(document.paths)) {
    if (pathMatches(path, slice.prefix)) paths[path] = item;
  }

  const components = reachableComponents(document, Object.values(paths));
  const separator = document.info.description === undefined ? "" : " ";

  return {
    openapi: document.openapi,
    info: {
      ...document.info,
      title: `${document.info.title} — ${slice.folder}`,
      description:
        `${document.info.description ?? ""}${separator}` +
        `This file is the \`${slice.folder}\` slice of that document: the \`${slice.prefix}\` paths ` +
        "and the components they reference. The whole document is not committed — the Worker " +
        "serves it at `GET /openapi.json`.",
    },
    servers: document.servers,
    paths,
    ...(Object.keys(components).length > 0 ? { components } : {}),
  };
}

/**
 * Removes slice folders this run did not write.
 *
 * **A renamed resource would otherwise leave its old folder behind, and nothing would say so.** The
 * gate diffs the working tree against what is committed, and a stale directory that is *already
 * committed* is not a diff — it is just a second contract for a path the Worker no longer mounts.
 * Only directories containing an `openapi.json` are touched, and `shared/` holds nothing else.
 */
function pruneStaleSlices(sharedDirectory: string, kept: ReadonlySet<string>): string[] {
  const removed: string[] = [];

  for (const entry of readdirSync(sharedDirectory, { withFileTypes: true })) {
    if (!entry.isDirectory() || kept.has(entry.name)) continue;
    if (!existsSync(join(sharedDirectory, entry.name, "openapi.json"))) continue;

    rmSync(join(sharedDirectory, entry.name), { recursive: true, force: true });
    removed.push(entry.name);
  }

  return removed;
}

const sharedDirectory = fileURLToPath(new URL("../../shared", import.meta.url));
const staleWholeDocument = join(sharedDirectory, "openapi.json");

try {
  const generated = createApp().getOpenAPI31Document(openApiConfig(RELATIVE_ORIGIN));
  const document = generated as unknown as Document;

  // The whole document is served by the Worker and is not committed. A checkout that still holds
  // one cleans itself here rather than carrying a contract with no producer.
  if (existsSync(staleWholeDocument)) {
    rmSync(staleWholeDocument, { force: true });
    console.log("openapi: removed the whole-document ../shared/openapi.json");
  }

  const slices: Slice[] = [
    { folder: "health", prefix: "/health" },
    ...resourceSegments(document).map((segment) => ({
      folder: segment,
      prefix: `${API_PREFIX}/${segment}`,
    })),
  ];

  for (const slice of slices) {
    if (!Object.keys(document.paths).some((path) => pathMatches(path, slice.prefix))) {
      throw new Error(
        `the ${slice.folder} slice covers no published path — its prefix is ${slice.prefix}`,
      );
    }

    mkdirSync(join(sharedDirectory, slice.folder), { recursive: true });
    const sliceDocument = sliceFor(document, slice);

    const unresolved = unresolvedRefs(sliceDocument);
    if (unresolved.length > 0) {
      throw new Error(
        `the ${slice.folder} slice has unresolved references: ${unresolved.join(", ")}`,
      );
    }

    writeFileSync(
      join(sharedDirectory, slice.folder, "openapi.json"),
      serialiseOpenApiDocument(sliceDocument),
      "utf8",
    );
    console.log(`openapi: wrote ../shared/${slice.folder}/openapi.json`);
  }

  for (const folder of pruneStaleSlices(sharedDirectory, new Set(slices.map((s) => s.folder)))) {
    console.log(`openapi: removed stale slice ../shared/${folder}/openapi.json`);
  }
} catch (error) {
  // Named before it is rethrown: an uncaught exception from here prints a stack whose top frame is
  // inside the generator or the filesystem, and "which output file was it trying to write" is the
  // first thing a reader wants and the one thing that stack does not say.
  console.error("openapi: could not write the contract under ../shared/");
  throw error;
}
