LANraragi API quick reference (extracted from GitBook pages)

Source docs (saved links):
- https://sugoi.gitbook.io/lanraragi/api-documentation/getting-started
- https://sugoi.gitbook.io/lanraragi/api-documentation/search-api
- https://sugoi.gitbook.io/lanraragi/api-documentation/archive-api
- https://sugoi.gitbook.io/lanraragi/api-documentation/database-api
- https://sugoi.gitbook.io/lanraragi/api-documentation/category-api
- https://sugoi.gitbook.io/lanraragi/api-documentation/tankoubon-api
- https://sugoi.gitbook.io/lanraragi/api-documentation/plugin-api
- https://sugoi.gitbook.io/lanraragi/api-documentation/shinobu-api
- https://sugoi.gitbook.io/lanraragi/api-documentation/minion-api
- https://sugoi.gitbook.io/lanraragi/api-documentation/opds-catalog
- https://sugoi.gitbook.io/lanraragi/api-documentation/miscellaneous-other-api

Authentication
- Most endpoints require an API key. Add header:
  Authorization: Bearer <base64(api_key)>
- If No-Fun Mode is enabled on the server, empty keys will NOT work.
- Responses without valid auth return HTTP 401 with JSON {"error": "This API is protected..."}

Common headers
- Accept: application/json
- For uploads use appropriate Content-Type (multipart/form-data or application/x-www-form-urlencoded as specified).

Key endpoints (summary)

1) /api/search (Search API)
- GET /api/search?filter=<query>&start=<n>&page=<n>
  - filter: query string (supports quotes, wildcards, -, $ for exact tag)
  - start: numeric offset; from v0.8.2 you can use -1 to request unpaged full data
  - returns JSON: { "data": [ { "arcid": "...", "title": "...", "pagecount": 34, ... }, ... ], "recordsFiltered": n, "recordsTotal": n }
- GET /api/search/random, DELETE /api/search/cache

2) /api/archives (Archive API)
- GET /api/archives — list all archives
- GET /api/archives/untagged — archive IDs without tags
- POST/PUT /api/archives/upload — upload archive (Authorization required)
- GET /api/archives/{id} — single archive metadata
- GET /api/archives/{id}/thumbnail — returns binary thumbnail (page param optional)
- GET /api/archives/{id}/download — download archive (CBZ/CBR)
- PUT /api/archives/{id}/metadata — update title/tags/summary (Authorization required)
- The archive JSON items commonly contain: arcid (40-char sha1), title, filename, tags, summary, isnew, extension, progress, pagecount, lastreadtime, size, toc

3) Pages / reading
- OPDS stream: /api/opds/{id}/pse?page={pageNumber} returns an image (useful as a stable per-page image endpoint)
- Prometheus metrics mention /api/archives/:id/files — this endpoint appears on servers (returns file list / page list). Many LRR clients use either:
  - /api/archives/{id}/files  (returns pages or files array)
  - /api/opds/{id}/pse?page={n} (returns single page image)
- For v1 client: preferred approach: call /api/archives/{id}/files (if present) or /api/opds/{id}/pse (per-page) /api/archives/{id}/download for full archive

4) /api/tankoubons (Tankoubon API)
- Manage tankoubon collections: GET /api/tankoubons, GET /api/tankoubons/{id}, PUT/DELETE to create/update/delete, add/remove archives

5) /api/categories (Category API)
- GET /api/categories, GET /api/categories/{id}, manage categories (create/update/delete), bookmark_link management

6) /api/plugins (Plugin API)
- List plugins (GET /api/plugins/{type}), POST /api/plugins/use to run a plugin synchronously, POST /api/plugins/queue to run async and get a Minion job id

7) /api/minion (Minion / job queue)
- Query jobs, queue jobs (GET /api/minion/{jobid}, POST /api/minion/{jobname}/queue)

8) /api/database (Database management)
- /api/database/stats, /api/database/backup (Authorization required), /api/database/clean, /api/database/drop, /api/database/isnew (clear New flags)

9) /api/shinobu (Filewatcher)
- /api/shinobu status, /api/shinobu/stop, /api/shinobu/restart, /api/shinobu/rescan (Authorization required)

10) Misc / server info
- GET /api/info returns JSON with server metadata: name, version, nofun_mode, archives_per_page, server_resizes_images, server_tracks_progress, total_archives, total_pages_read, etc.
- POST /api/download_url?url=... to enqueue a URL download (Authorization required)
- POST /api/regen_thumbs to queue thumbnail regeneration

Parsing notes / response shapes
- Search returns a top-level `data` array for archives. Items include `arcid`, `title`, `pagecount`, `tags`, `progress`, `filename`, `summary`.
- Many admin endpoints return { operation: "...", success: 1/0, error?: "...", successMessage?: "..." }
- Image endpoints return binary blobs (Content-Type: image/* or application/octet-stream)

Implementation guidance for this client (v1)
- Authenticate with header: Authorization: Bearer <base64(api_key)> (persist base64 string)
- Use GET /api/search?filter=<q>&start=-1 to fetch full library when server supports it
- Fetch per-archive page list using either /api/archives/{id}/files (preferred if available) or fallback to per-page /api/opds/{id}/pse?page=N
- Thumbnails: GET /api/archives/{id}/thumbnail?page=1 returns binary image; use for cover cards
- Download/read: /api/archives/{id}/download (CBZ) or per-page images for reader

Notes & caveats
- Server versions vary; endpoints/parameters may differ. Code should be tolerant (try expected endpoints and multiple JSON shapes).
- Respect rate limits and protect API key (store encoded key securely if needed; v1 will use shared_preferences per plan).

---
Reference saved on $(date)
