# Manyfold Printables

A [Manyfold](https://manyfold.app) plugin that adds
[Printables.com](https://www.printables.com) as an external site source, the
same way the built-in Thingiverse and Cults3D integrations work.

<img align="right" alt="Screenshot_20260905_005807" src="https://github.com/user-attachments/assets/64782c59-8a21-4a88-9dd9-683bc20af3dc" />

Paste a Printables model or creator URL on the **Import** page (or attach it to
an existing model via a **Link**) and Manyfold will fetch the metadata, cover
image, and **downloadable 3D files** — including `.stl`, `.3mf`, `.stp`, `.obj`,
and `.gcode` — directly from Printables' public GraphQL API.

> **How it works**
>
> The plugin uses Printables' public `getDownloadLink` GraphQL mutation
> (the same endpoint the printables.com website uses for its "Download all"
> button). For each file, the mutation returns a 24-hour signed CDN URL on
> `files.printables.com`. Manyfold downloads the file from that URL.
>
> **Works without authentication** for every public print we tested — both
> old (pre-2024) and new (post-2024) layouts, all file extensions. For
> private / unlisted prints that return `files_cannot_be_downloaded`, see
> the optional cookie instructions in [Installation](#installation).

## What it does

- **Model URLs** like `https://www.printables.com/model/46705` or
  `https://www.printables.com/model/46705-battery-tray-...` will be detected
  and synced. Metadata, tags, license, summary, description, NSFW flag,
  creator, all images, and every STL / SLA / gcode file the print exposes are
  imported. The cover image becomes the model preview.
- **Creator URLs** like `https://www.printables.com/@100prznt` are matched too:
  importing one creates a Creator record linked back to the Printables profile.
- **Visible on `/imports/new`** — the plugin prepends a copy of Manyfold's
  imports/new view with a `✅ Printables` entry added to the Supported
  Sites sidebar. No API key is required, so the indicator is always ✅ when
  the plugin is loaded.
- **No API key is required** — Printables' GraphQL endpoint is public.
- **File downloads use 24-hour signed CDN URLs** obtained from the
  `getDownloadLink` mutation. The plugin never stores credentials.

## Installation

1. Download or clone this repository into your Manyfold `plugins/` directory so
   that the path ends in `…/plugins/manyfold_printables/manyfold_printables.gemspec`.
   - If you run Manyfold via Docker, mount a host directory at
     `/usr/src/app/plugins` (or wherever your existing `PLUGINS_PATH` points)
     and drop this plugin in there.
2. **Restart Manyfold.** Plugins are only picked up on boot.
3. There's nothing to enable in admin settings — the plugin is active as soon
   as Manyfold loads it. You can confirm by visiting **Settings → Plugins** and
   looking for "Manyfold Printables" in the list.

### Optional: authenticated downloads for private prints

The `getDownloadLink` mutation works **without authentication** for every
public print we've tested — including all `.stl`, `.3mf`, `.stp`, `.obj`,
and `.gcode` files on every print, both old (pre-2024) and new (post-2024)
layouts.

For private / unlisted prints that return `files_cannot_be_downloaded`,
you can supply a Printables session cookie so the plugin can fetch those
files:

1. Log in to printables.com in your browser.
2. Open DevTools → Network → click any printables.com request → Headers →
   copy the entire `Cookie:` header value (it usually starts with something
   like `cf_clearance=...; __cf_bm=...; session=...`).
3. Set the `PRINTABLES_SESSION_COOKIE` environment variable on your
   Manyfold container to that value. Example for docker-compose:
   ```yaml
   environment:
     PRINTABLES_SESSION_COOKIE: "cf_clearance=abc123...; session=xyz789..."
   ```
4. Restart Manyfold.

The plugin will send the cookie on every download request. The cookie
expires every few weeks — re-copy it from your browser when downloads
start failing with `HTTP 403` or `files_cannot_be_downloaded`. Treat the
cookie like a password: don't commit it, don't share it.

## Usage

### Importing a new model

1. Go to **Import** in the Manyfold UI.
2. Paste a Printables URL:
   - `https://www.printables.com/model/46705`
   - `https://www.printables.com/model/46705-battery-tray-16x-aa-16x-aaa-4x-cr2032`
3. Click through. Manyfold will create a Model, fetch the metadata, download
   the printable files and images, set the preview to the cover image, and
   link or upsert the creator automatically.

### Linking an existing model to its Printables page

1. Open the model detail page.
2. Add a link pointing at the Printables URL (either `/model/<id>` or
   `/model/<id>-<slug>` form).
3. Manyfold will detect the Printables deserializer on next sync and import
   the metadata into the existing model.

### Importing a creator

1. Paste `https://www.printables.com/@handle` on the Import page.
2. Manyfold creates a Creator linked back to Printables.

## How it works internally

Manyfold's core supports a list of `Integrations::*::BaseDeserializer` classes
that know how to turn a URL into a hash of attributes for the relevant model
(`Model`, `Creator`, `Collection`). The official Thingiverse, Cults3D,
MyMiniFactory, and Thangs integrations live in Manyfold's source tree and are
referenced from `Link.deserializer_for`.

This plugin:

1. Ships two deserializer classes under the `Integrations::Printables` namespace
   (`app/deserializers/integrations/printables/`):
   - `ModelDeserializer` — matches `/model/<id>[-<slug>]`
   - `CreatorDeserializer` — matches `/@<handle>`
2. Provides an initializer (`config/initializers/register_deserializers.rb`)
   that prepends both classes to `Link.deserializer_for` so they run before the
   built-in list.

**Note on the registration mechanism:** Manyfold does not currently expose a
public plugin hook for adding deserializers — the core `Link.deserializer_for`
method is a hardcoded array. This plugin prepends to the class method via
`singleton_class.prepend` in an initializer, which is the standard way to
extend Manyfold's core from a plugin today. If/when Manyfold adds a
`PluginManager.register_deserializer` API, this initializer can be replaced
with that registration.

### Caveats

1. **Printables' GraphQL schema is undocumented and unstable.** Some fields the
   third-party `PrintablesGraphQL` reference (https://github.com/100prznt/PrintablesGraphQL)
   documents (`user.slug`, `user.printsCount`, `shareCount`, …) have already
   been removed. The plugin uses only fields that have been verified against
   the live schema. If a field is renamed, update `PRINT_QUERY` /
   `USER_QUERY` accordingly and release a new version.
2. **Private / unlisted prints may fail.** Public prints all download
   via the `getDownloadLink` mutation without authentication, but prints
   that are private or unlisted may return `files_cannot_be_downloaded`.
   For those prints, supply a Printables session cookie via the
   `PRINTABLES_SESSION_COOKIE` env var (see Installation § Optional
   above). The plugin will retry with the cookie in the Cookie header.
   For either case, download the file manually from printables.com and
   upload it to Manyfold — metadata, tags, images, license, and creator
   will still be imported correctly.
3. **Creator URL → numeric ID** requires one HTML fetch to resolve the
   `@handle` to the internal user id (Printables doesn't expose a
   handle-based GraphQL lookup). If that page returns a Cloudflare challenge
   from your server's IP, the creator import will fail and report an
   `http_error` problem on the link.
4. **Files are pulled from `media.printables.com`.** That CDN serves files
   unmodified under the same path as the preview (with the `_preview` suffix
   stripped). If Printables changes that CDN layout, file downloads will break
   but metadata will still sync.

## Development

The plugin is a standard Manyfold Rails engine gem. No new runtime
dependencies are added — it uses `Net::HTTP`, `JSON`, `URI`, and `CGI` from
the standard library plus `Faraday::ResourceNotFound` for the "not found"
error type that Manyfold's existing integrations already use.

### Running the tests

The tests live in `test/` and run as plain Ruby scripts (no RSpec). They
need the Manyfold source tree checked out at `/tmp/manyfold-research/manyfold`
so they can stub the deserializer base classes. The tests do **not** need
Manyfold to be running — they load only the deserializer classes plus
minimal stubs.

```bash
# 1. Clone the Manyfold source (sparse, you only need app/deserializers and db/migrate):
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/manyfold3d/manyfold.git /tmp/manyfold-research/manyfold
cd /tmp/manyfold-research/manyfold
git sparse-checkout set app/deserializers db

# 2. Run the tests:
cd /path/to/manyfold_printables
ruby test/schema_guard.rb                # asserts every deserializer key
                                         # maps to a real Model/Creator
                                         # column or accepted special key.
ruby test/print_26497_regression.rb      # end-to-end check against a real
                                         # captured Printables response that
                                         # previously failed in production:
                                         # SPDX license mapping, .stp/3mf
                                         # files under /previews/ being
                                         # filtered out, all STL URLs
                                         # actually 200 from the CDN.
ruby test/view_workaround.rb             # asserts the Link#deserializer
                                         # workaround keeps the per-link
                                         # "resync" button out of the
                                         # Manyfold/Phlex rendering bug
                                         # (ArgumentError at link_list.rb:27)
                                         # while still letting the actual
                                         # sync job use our deserializer.
```

### Updating the schema-guard test when Manyfold adds columns

If Manyfold adds a new column to the `models` table (e.g. via a new
migration), update the `KNOWN_MODEL_COLUMNS` set in
`test/schema_guard.rb`. Otherwise the test will fail with a false positive
when your deserializer starts using the new column.

## License

MIT. See [LICENSE.md](LICENSE.md).
