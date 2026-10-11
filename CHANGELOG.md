# Changelog

## 1.0.0 — 2026-10-11

First release. Immich v3.3.1 with Postgres (VectorChord) and Valkey in
Container Manager, the images and versions of that release's own compose file:
- uploads go to the photos folder of the immich shared folder;
- your administrator account is made at the first start, with the password
  shown once;
- the package works through an API key of its own, never your password.

The DSM window adds:
- **Photo libraries:**
  - up to five folders already on the Synology, read-only, as Immich external
    libraries, each in someone's timeline;
  - scan one or all now; counts and the last scan;
  - missing folders are refused, never created; DSM's @eaDir thumbnails are
    skipped;
  - what's in the photos folder, and what Immich is still working on.
- **Machine learning:** on or off. Off frees 1–2 GB of memory on smaller
  Synologys; smart search and faces follow the switch. Memory in use, per
  container.
- **Users:** add people (a password shown once, their own chosen at the first
  sign-in), and reset the administrator's password with immich-admin.
- **Phones:** a QR code, the server address and the apps.

Also included: database backups as Immich documents them (pg_dump), with
restore; updates that move to a newer Immich only with a package update, after
backing up the database; and removal.
