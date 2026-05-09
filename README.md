# postsrsd

A prebuilt Docker image of [PostSRSd](https://github.com/roehling/postsrsd) packaged for use as a sidecar in [mailcow](https://mailcow.email/) deployments. Implements the [Sender Rewriting Scheme](https://en.wikipedia.org/wiki/Sender_Rewriting_Scheme) so a forwarding mailcow instance can rewrite envelope senders to pass SPF at the next hop.

## Brief background and Synopsis
This image and its accompanying configs grew out of a need for SRS (and a stable prebuilt docker image) for my own mailcow deployment and intial iterative implementation after scouring internet for information. The large part of guidance from [mailcow issue #2418](https://github.com/mailcow/mailcow-dockerized/issues/2418), and the [tutorial from the blog](https://nowhere.dk/articles/implementing-srs-with-mailcow/) helped me set it up then. However the need to keep it updated with the upstream [PostSRSd](https://github.com/roehling/postsrsd) and the need for a prebuilt Docker image got me here, and taking inspiration from [ethrgeist's deployment writeup](https://github.com/mailcow/mailcow-dockerized/issues/2418#issuecomment-3416844091), I put together this repo that ships an automated prebuilt Docker image as a multi-arch image. 
 
In addition to the prebuilt Docker image, I have put together a detailed tutorial with documentation that fills in the bits the [issue thread](https://github.com/mailcow/mailcow-dockerized/issues/2418) under-explained — DNS, mailcow domain registration, Dovecot Sieve, and tag pinning, based on my own experience in implementing this, to hopefully helping other mailcow users requiring SRS support with their deployment much more easily than it was for me!

## Image

| | |
| :-- | :-- |
| Registry | `ghcr.io/tekgnosis-net/postsrsd` |
| Architectures | `linux/amd64`, `linux/arm64` |
| Tags | `:latest` (floats), `:<APK-version>` (e.g. `:2.0.11-r0`, pinned) |

The version tag matches the Alpine `community/postsrsd` APK version, including the `-rN` packaging revision. A daily GitHub Actions cron polls the Alpine community index; when a newer APK is published, the image is rebuilt and re-tagged automatically.

---

## Tutorial — Deploy SRS for mailcow

### Prerequisites

- A running mailcow stack (any current release).
- Shell access to the mailcow host with permission to edit `mailcow.conf` and the files under `data/conf/`.
- Admin permissions to add DNS records on the domain you intend to use as the SRS rewrite domain.
- Admin permissions to add a domain and an alias in the mailcow admin UI.

### 1. Choose your SRS domain

Pick a **dedicated subdomain** of one of your hosted domains, it would be preferred to use the mailcow server's domain as it has the reverse DNS, DKIM, DMARC and SPF already setup, validated and in-use. For the rest of this tutorial we will use `srs.example.com` as a placeholder — substitute with your real **_SRS Domain_** throughout.

Two reasons to use a dedicated subdomain rather than a real user-facing domain:

- The SRS domain appears in `Return-Path:` headers of forwarded mail — it is internal infrastructure, not a public face.
- Upstream [PostSRSd](https://github.com/roehling/postsrsd) recommends a dedicated SRS domain *"if you serve multiple unrelated domains, to prevent privacy issues"* — without one, bounces for forwards from one tenant carry the SRS domain of another tenant.

### 2. Configure DNS for the SRS domain

This is the section the original mailcow issue thread skipped, and it routinely catches new SRS users out (It certainly did for me!).

#### Why DNS matters for the SRS domain

When postsrsd rewrites a forwarded message, it changes the envelope sender from the original (e.g. `bob@gmail.com`) to `srs0=hash=tt=gmail.com=bob@srs.example.com`. The receiving mail server uses this rewritten address for two things:

1. **Bounce delivery.** If the mail bounces, the bounce comes back to `srs0=…@srs.example.com`. Your mailcow has to accept that bounce, hand it to postsrsd's reverse map, and forward the bounce on to the original sender. Without an MX record on the SRS domain, the bounce drops on the floor and the original sender never learns the message failed.
2. **SPF at the receiver.** Receiving mail servers check SPF against the *envelope sender's domain*, which is now `srs.example.com`, not `gmail.com`. Without an SPF record authorising mailcow's outbound IPs, your forwarded mail gets flagged or rejected — defeating the entire point of SRS.

#### Records to add (substitute your actual SRS domain)

| Record | Value | Why |
| :-- | :-- | :-- |
| `srs.example.com.` `A` | mailcow's public IPv4 | Lets mailcow accept inbound bounces; lets ACME pass HTTP-01 challenge for the TLS cert. |
| `srs.example.com.` `AAAA` | mailcow's public IPv6 (if available) | **(OPT)** _Same as A but for IPv6; modern receivers prefer IPv6. It should be noted that the Compose only uses IPv4 so this is optional and for future use based on upstream support._ |
| `srs.example.com.` `MX 10` | mailcow's MX hostname (typically the same as your other domains' MX, e.g. `mail.example.com.`) | Receivers look up MX to deliver bounces back to mailcow. |
| `srs.example.com.` `TXT` | `"v=spf1 mx -all"` | Authorises whatever the SRS domain's MX resolves to as a sender, since forwarded mail re-leaves through that MX. |
| `_dmarc.srs.example.com.` `TXT` | `"v=DMARC1; p=none; rua=mailto:dmarc@example.com"` | Optional. `p=none` because forwarded mail can't satisfy stricter alignment. |

**DKIM.** Not strictly required (DKIM signs the `From:` header domain, which SRS leaves unchanged). But if you let mailcow generate a DKIM key for the SRS domain after step 3, forwarded mail picks up an additional valid signature, helping deliverability at strict receivers.

**TLS.** Mailcow's ACME client requests a Let's Encrypt cert for the SRS domain automatically once the domain is added in the admin UI **and** the A record points back at mailcow. Confirm with `docker compose logs acme-mailcow` after step 3.

### 3. Register the SRS domain in mailcow — the easy-to-miss step

Skipping this step is perhaps, the single-most obvious SRS-on-mailcow mistake. Bounces will fail at SMTP time before postsrsd's reverse map ever fires. Debugging SRS related issues can beicome quite frustrating without this.

#### Why two settings, not one

When a bounce comes back to `srs0=…@srs.example.com`, Postfix has to do two things in order:

1. **Accept the recipient at SMTP time.** This happens in the `smtpd` daemon, very early. Mailcow uses MySQL-backed virtual maps; adding the SRS domain to the `domain` table puts it in `virtual_mailbox_domains`, but `virtual_mailbox_maps` then expects a *specific* mailbox. `srs0=…` is never a real mailbox, so Postfix rejects with "User unknown in virtual mailbox table".
2. **Rewrite the recipient back to the original.** This happens later, in the `cleanup` daemon, via the `recipient_canonical_maps` socketmap query to postsrsd. By then it is too late — the recipient was already rejected at step 1.

The fix is to put the SRS domain into Postfix's `virtual_alias_maps` instead, by adding a **catch-all alias**. This affects the two pipeline stages differently:

- At **SMTP time** (the `smtpd` daemon), the catch-all alias makes Postfix accept arbitrary local-parts on the SRS domain, so `srs0=…@srs.example.com` passes recipient validation.
- At **`cleanup` time**, Postfix applies `recipient_canonical_maps` *before* `virtual_alias_maps` rewriting (per Postfix's documented `cleanup(8)` ordering). So `srs0=…@srs.example.com` is matched against postsrsd's reverse map and rewritten to the original recipient before the catch-all alias is consulted — the catch-all only matters as a fallback for non-SRS-formatted addresses that happen to be delivered to the SRS domain.

#### Procedure (mailcow admin UI)

1. **Mail Setup → Domains → Add Domain.**
   - Domain: `srs.example.com`
   - Description: `SRS rewrite domain (PostSRSd)` (free-form; helps the next admin)
   - Aliases / Mailboxes: leave at defaults; you do not need to provision either.
   - **Active**: on. 
   - **Relay this domain**: off.
   - Save.
2. **Mail Setup → Configuration → Aliases → Add Alias.**
   - Alias: leave the local-part empty so the alias becomes `@srs.example.com`.
   - Goto: any valid mailbox you control (e.g. `postmaster@example.com`). This address is functionally a no-op because `recipient_canonical_maps` rewrites `srs0=…` to the original recipient before the catch-all fires. (_Note: You should always have a postmaster email account for all your domains as a good practice, so this is a good time to create one if you don't have it already._)
   - **Active**: on.
   - Save.
3. **Verify.** From any external host: `swaks --to test@srs.example.com --from postmaster@example.com --server <mailcow-host>`. Expected: SMTP transaction completes; no "User unknown" / "Recipient address rejected".

**Optional: enable DKIM.** Mail Setup → Configuration → ARC/DKIM keys → Add → select the SRS domain → save → publish the resulting TXT record on the SRS domain.

### 4. Drop in the postsrsd config from provided template

In the commands below, `<this-repo>` is the directory where you have cloned (or downloaded a tarball of) the [postsrsd repository](https://github.com/tekgnosis-net/postsrsd). Substitute the actual path on your host.

```bash
cd /opt/mailcow-dockerized
mkdir -p data/conf/postsrsd
cp <this-repo>/conf/postsrsd.conf data/conf/postsrsd/postsrsd.conf
$EDITOR data/conf/postsrsd/postsrsd.conf
```

Edit two lines:

- `domains = { … }` — replace with your hosted domains. See "What goes in `domains`" below.
- `srs-domain = "srs.example.net"` (the shipped file's placeholder) — replace with your actual SRS domain. The rest of this tutorial uses `srs.example.com`; substitute your real value.  


#### What goes in `domains`

The `domains = { … }` list tells postsrsd which mail-from domains are *yours* (hosted by this mailcow instance). Any envelope sender ending in one of these domains is treated as local and is **not** rewritten. Anything else, when forwarded by a local user, *is* rewritten.

What to put in it: every domain mailcow accepts mail for. The list under Mail Setup → Domains in the mailcow UI is the authoritative source. Example:

```
domains = { "example.com", "example.org", "another-tenant.test" }
```

What NOT to put in it:

- The `srs-domain` is allowed but not required to appear. Listing it does no harm; leaving it out is also fine because reverse-rewriting is driven by `recipient_canonical_maps`, not by `domains`.
- Domains your users forward *to* (e.g. `gmail.com`) — those are exactly the foreign senders SRS needs to rewrite.
- Subdomains are not implicitly matched. If you accept mail for both `example.com` and `blog.example.com`, list both.

For multi-tenant setups with many domains, use postsrsd's `domains-file` option (see the comment in the sample `postsrsd.conf`) and feed it a one-domain-per-line file.  

<mark>_Note: The conf file is well commented with references back to the sections in this README._</mark>

### 5. Append the Postfix snippet

```bash
cat <this-repo>/conf/extra.cf >> data/conf/postfix/extra.cf
```

The snippet uses `172.22.1.42:10003`. **If you have changed `IPV4_NETWORK` in `mailcow.conf`** away from the default `172.22.1`, edit the IP in `extra.cf` to match before appending — Postfix does not expand shell variables (only Compose does, in step 7).  

<mark>_Note: Refer to mailcow documentation for postfix main.cf extension [here](https://docs.mailcow.email/manual-guides/Postfix/u_e-postfix-extra_cf/)_</mark>

### 6. (Conditional) Configure Dovecot for Sieve-based forwarding

**Skip this step if you only use mailcow's UI Aliases/Goto for forwarding.** Required only if you (or your users) use SOGo "Vacation" / SOGo "Forward" filters, or hand-written Sieve scripts that `redirect` mail externally. Those paths bypass Postfix's `sender_canonical_maps` unless Dovecot is told to preserve the original envelope sender.

#### Why mailcow's default breaks SRS for sieve forwards

Mailcow ships `dovecot.conf` with `sieve_redirect_envelope_from = recipient`. When a Sieve `redirect` action submits the forwarded message to Postfix, Dovecot uses *the recipient address* as the envelope sender — not the original sender. Postsrsd only rewrites *foreign* senders, so a local-domain envelope sender is left alone. Result: forwards leave with the local user's address as envelope-sender, bounces go to the local user instead of the original sender, and DMARC alignment with the unchanged `From:` header silently fails at strict receivers.

Mailcow chose `recipient` as the default because, *without SRS*, it is the only safe option (using the original sender as envelope-from causes SPF failures). With SRS in place, the upstream Dovecot default of `sender` is the right choice: postsrsd rewrites the original sender to `srs0=…@srs.example.com`, SPF passes via the SRS domain, and bounces route correctly.

#### The fix

```bash
cat <this-repo>/conf/dovecot-extra.conf >> data/conf/dovecot/extra.conf
```

(Create `data/conf/dovecot/extra.conf` first if it does not exist — mailcow's `dovecot.conf` line 306 does `!include_try /etc/dovecot/extra.conf`, and the file is invited by a comment on line 2.)

### 7. Splice the docker-compose override

Splice the contents of `<this-repo>/conf/docker-compose.override.yml` into your existing mailcow `docker-compose.override.yml` (or create one). The `${IPV4_NETWORK:-172.22.1}.42` and `${TZ:-UTC}` placeholders are expanded by Compose from `mailcow.conf` at startup.

### 8. Bring up the sidecar

```bash
docker compose pull postsrsd-mailcow
docker compose up -d postsrsd-mailcow
docker compose restart postfix-mailcow
# If you applied step 6:
docker compose restart dovecot-mailcow
```

On the **first start** of a fresh `postsrsd-secrets` volume, the container's entrypoint detects that the secrets file is missing and auto-generates a 32-character SRS HMAC key in `/etc/postsrsd/secrets/list` (mode `600`, owned by the in-container `postsrsd` user). The daemon then reads that file and uses the key to sign rewritten envelope sender addresses. **You do not need to provision the secret yourself.** See [(Optional) Secret rotation](#optional-secret-rotation) below for the lifecycle and how to rotate the key if you ever need to.

### 9. Verify

Three checks:

```bash
# 1. The daemon started cleanly.
docker compose logs postsrsd-mailcow | tail -20
# Expect: postsrsd: listening on socketmap: inet:0.0.0.0:10003 — and no "cannot drop privileges" errors.
```

2. Send a forward through a mailcow alias to an external mailbox you control. Inspect the received message's `Return-Path:` header — it should read `<srs0=…=originaldomain=originaluser@srs.example.com>`. If you applied step 6, repeat for a SOGo "Forward" filter.

3. Mail a known-bad recipient through a mailcow forwarding alias. Confirm the bounce reaches the original sender's inbox — not stuck in `mailq` with "User unknown in virtual mailbox table" (which would mean step 3 was skipped).

---

## Reference

### Available tags and pinning

- `:latest` — floats; whatever the most recently published Alpine APK builds to.
- `:<APK-version>` — pinned, e.g. `:2.0.11-r0`. **Recommended for production.** The `-rN` suffix is Alpine's packaging revision, so an Alpine repackage produces a new pinnable tag even if the upstream postsrsd version is unchanged.

### Image environment variables

| Variable | Type | Default | Honoured at runtime? |
| :-- | :-- | :-- | :-- |
| `TZ` | runtime | unset (UTC) | yes |
| `POSTSRSD_SECRET_PATH` | runtime ENV | `/etc/postsrsd/secrets/list` | **partially** — see footgun note below |
| `POSTSRSD_PACKAGE_VERSION` | build ARG | (current pinned version) | n/a |
| `POSTSRSD_SECRET_DIR_PATH` | build ARG | `/etc/postsrsd/secrets` | n/a |

**Note on `POSTSRSD_SECRET_PATH`:** the Dockerfile sets this `ENV`, so it appears tweakable, but the daemon reads its secrets-file path from `/etc/postsrsd/postsrsd.conf` (sed-patched at *build* time). Overriding the env at runtime causes the auto-generation to write the secret to the new path while postsrsd still reads from the old path — empty file, daemon fails to start. Treat it as a build-time decision; rebuild with `--build-arg POSTSRSD_SECRET_DIR_PATH=/your/path` if you genuinely need a different path.

**No `.env.example` file ships with this repo.** mailcow's `mailcow.conf` already supplies the env vars the override yml substitutes from (`${IPV4_NETWORK}`, `${TZ}`). A separate `.env.example` would compete with `mailcow.conf` for the same values and create ambiguity.

### Standalone-run recipe

For users who want to evaluate the image outside a mailcow stack:

```bash
docker run -d --name postsrsd \
  -e TZ=Etc/UTC \
  -v postsrsd-secrets:/etc/postsrsd/secrets \
  -p 10003:10003 \
  ghcr.io/tekgnosis-net/postsrsd:latest
```

Caveat: standalone-run only smoke-tests the daemon — without a Postfix to talk to, it does no actual rewriting.

### `docker-compose.override.yml` is a reference sample

`conf/docker-compose.override.yml` in this repo is annotated and meant to be **spliced** into the user's existing mailcow override yml, not used standalone. The header comment block in the file documents which variables come from `mailcow.conf` and which line a user might want to edit. See tutorial step 7.

### Building locally

```bash
docker buildx build --platform linux/amd64 -t postsrsd:dev .
# Optionally pin a specific Alpine APK version:
docker buildx build --build-arg POSTSRSD_PACKAGE_VERSION=2.0.11-r0 -t postsrsd:dev .
```

The `Dockerfile` itself documents the rationale behind the three `sed` patches and the empty `unprivileged-user`/`chroot-dir` values — those exist so the container can run as a non-root user without `CAP_SETUID`, `CAP_SETGID`, or `CAP_SYS_CHROOT`.

### Configuration knobs in `postsrsd.conf`

The shipped `conf/postsrsd.conf` surfaces the upstream-documented optional knobs as commented examples:

- `keep-alive` — socketmap connection timeout (default 30s).
- `separator` — SRS tag separator. Valid: `=`, `+`, `-`. Leave at default unless a downstream gateway specifically rejects `=`.
- `syslog` — turn on to forward log messages through Docker's syslog driver.
- `debug` — verbose logging for troubleshooting; disable in production.
- `original-envelope` — `embedded` (default, stateless) vs `database` (SQLite/Redis-backed; only needed for sender addresses longer than 51 octets).

**Do not change `hash-length` or `hash-minimum` unless you understand SRS hash rotation.** Misconfiguration can turn the server into a spam relay. The upstream defaults (`4` / `4`) are correct.

### (Optional) Secret rotation

Most installations never rotate. The SRS secret is internal infrastructure: it never appears in mail headers, isn't transmitted over the wire, and doesn't expire. Rotate only if you suspect the secret has leaked (e.g., a volume backup ended up somewhere it shouldn't), if your security policy mandates periodic rotation, or if you want a clean key after rebuilding the stack.

#### How the SRS secret comes to exist in the first place

The lifecycle is fully automatic — nobody hand-creates the file:

1. **Build time.** The Dockerfile creates `/etc/postsrsd/secrets/` as an empty `0700` directory owned by the in-container `postsrsd` user, and patches the in-image `postsrsd.conf` so its `secrets-file = "/etc/postsrsd/secrets/list"` line points at the right path. No `list` file exists yet.
2. **First container start.** Compose mounts the named volume `postsrsd-secrets` at `/etc/postsrsd/secrets`, masking the empty in-image directory with a likewise-empty Docker volume. The CMD entrypoint runs:
   ```sh
   umask 0077
   if [ ! -s "$POSTSRSD_SECRET_PATH" ]; then
     tr -dc '1-9a-zA-Z' < /dev/urandom | head -c 32 > "$POSTSRSD_SECRET_PATH"
   fi
   exec postsrsd
   ```
   The `[ ! -s ... ]` test fires because `list` doesn't exist, so 32 random alphanumeric characters (excluding visually-ambiguous `0` and `O`) are written to `/etc/postsrsd/secrets/list` with mode `600` (thanks to `umask 0077`). The daemon then reads that file as its HMAC key.
3. **Subsequent starts.** The file already has content, the auto-seed step is skipped, and postsrsd reads the same key. SRS signatures from previous runs continue to verify, so in-flight rewritten addresses still bounce correctly.
4. **Volume lifecycle.** As long as the named volume exists, the secret persists. `docker compose down` (without `-v`) keeps the volume; `docker compose down -v` removes it (and silently rotates the secret on the next `up`, invalidating any in-flight rewritten addresses without a grace period).

You can inspect the current secret if you want to confirm the file was created:

```sh
docker compose exec postsrsd-mailcow cat /etc/postsrsd/secrets/list
```

Expect a single 32-character alphanumeric line.

#### Why postsrsd supports multiple keys

Postsrsd reads the secrets file line by line. The **first** line is used to sign newly-rewritten outgoing addresses. **Any** line is accepted for verifying incoming bounces. Rotation therefore proceeds gracefully:

- Add the new key as the first line, leaving the old key beneath it.
- Restart postsrsd. New outgoing rewrites are signed with the new key; bounces returning with addresses that were signed by *either* the new or the old key still verify.
- Wait until any in-flight forwarded mail has been delivered or bounced. This is the **bounce-handling window** — typically 7-30 days, longer if you forward to receivers known to retry slowly.
- Remove the old key and restart again. From this point only the new key verifies.

Without the two-line interim, overwriting the old key with a new one in a single step would break verification of any bounce returning for a forward that was rewritten with the old key — your sender would silently lose those bounce notifications.

#### Detailed rotation procedure

1. **Generate a new 32-character secret** on the mailcow host:
   ```sh
   NEW=$(tr -dc '1-9a-zA-Z' < /dev/urandom | head -c 32)
   echo "New SRS secret (will be prepended to the secrets file): $NEW"
   ```
2. **Prepend the new secret** to the existing file inside the container. The shell pipe below works on busybox/POSIX sh, so it's portable to Alpine without depending on GNU sed quirks:
   ```sh
   docker compose exec postsrsd-mailcow sh -c "
     current=\$(cat /etc/postsrsd/secrets/list)
     printf '%s\n%s\n' '$NEW' \"\$current\" > /etc/postsrsd/secrets/list
     echo '--- secrets file now contains: ---'
     cat /etc/postsrsd/secrets/list
   "
   ```
   Expect two 32-character lines, the new key on top.
3. **Restart postsrsd** so it re-reads the file:
   ```sh
   docker compose restart postsrsd-mailcow
   ```
   New outgoing rewrites are now signed with the new key; bounces signed with either key still verify.
4. **Wait for the bounce-handling window to elapse** — commonly 7-30 days, depending on your typical forward latency.
5. **Remove the old line** and restart:
   ```sh
   docker compose exec postsrsd-mailcow sh -c '
     head -n 1 /etc/postsrsd/secrets/list > /etc/postsrsd/secrets/list.new
     mv /etc/postsrsd/secrets/list.new /etc/postsrsd/secrets/list
     echo "--- secrets file now contains: ---"
     cat /etc/postsrsd/secrets/list
   '
   docker compose restart postsrsd-mailcow
   ```
   Expect a single line. After this point, only signatures from the new key verify. Rotation complete.

### Why `extra.cf` uses a literal IPv4 address, not a service name

Mailcow's `postfix-mailcow` container runs Postfix's `cleanup(8)` daemon under chroot — the `cleanup` line in `master.cf` has its 5th column set to `y`, jailing the daemon at `/var/spool/postfix/`. The chrooted `cleanup` is the daemon that consults `sender_canonical_maps` and `recipient_canonical_maps`, which our `extra.cf` snippet wires to postsrsd via socketmap.

The chroot intentionally **does not contain `/etc/resolv.conf`**:

```sh
$ docker compose exec postfix-mailcow ls /var/spool/postfix/etc/
# (no resolv.conf)
$ docker compose exec postfix-mailcow cat /var/spool/postfix/etc/resolv.conf
cat: /var/spool/postfix/etc/resolv.conf: No such file or directory
```

Without a resolver configuration inside the chroot, the chrooted `cleanup` process cannot do DNS at all. A service-name lookup like `socketmap:inet:postsrsd-mailcow:10003:forward` produces:

```
postfix/cleanup: warning: host or service postsrsd-mailcow:10003 not found: Temporary failure in name resolution
postfix/cleanup: warning: connect to postsrsd-mailcow:10003: Cannot assign requested address
postfix/cleanup: warning: table socketmap:inet:postsrsd-mailcow:10003:forward lookup error: Cannot assign requested address
postfix/cleanup: warning: <message-id>: sender_canonical_maps map lookup problem for <sender> -- message not accepted, try again later
```

…and the message is deferred. (`Cannot assign requested address` here is `EADDRNOTAVAIL`, returned by the kernel when Postfix tries `connect(2)` to a result of a failed `getaddrinfo` — not a network reachability issue.)

Mailcow's design choice is deliberate. Their normal mail flow doesn't need in-chroot DNS:

- **Recipient validation** goes through the MySQL-backed `virtual_mailbox_maps` / `virtual_alias_maps` queries, not DNS.
- **Outbound MX lookups** happen in the non-chrooted `smtp(8)` daemon, which has full resolver access.
- The chroot acts as defence-in-depth for the cleanup pipeline, which doesn't normally do network lookups.

A custom socketmap added in `extra.cf` is the unusual case that trips this constraint.

The literal IPv4 address in the shipped `conf/extra.cf` (`172.22.1.42`) bypasses DNS entirely — Postfix passes the address straight to `connect(2)`, which works inside the chroot the same as outside. This is why the next subsection exists: Compose substitutes `${IPV4_NETWORK}` in `docker-compose.override.yml`, but Postfix's plain config in `extra.cf` cannot, so the literal IP must match by hand if you ever change `IPV4_NETWORK` in `mailcow.conf`.

**Operators running postsrsd outside mailcow** (or with a non-chrooted Postfix) can use service-name resolution; that path is documented in the [Standalone-run recipe](#standalone-run-recipe).

**Could mailcow fix this on their side?** Yes — by either (a) adding `resolv.conf` and `nsswitch.conf` to the chroot at container build time, or (b) switching the `cleanup` line in `master.cf` to `chroot=n`. Both are mailcow-side decisions; this image cannot make either change. If you'd find this useful upstream, opening an issue or PR on `mailcow/mailcow-dockerized` is the path.

### `IPV4_NETWORK` and the postfix-vs-compose asymmetry

`docker-compose.override.yml` uses `${IPV4_NETWORK:-172.22.1}.42` — Compose expands this from `mailcow.conf` automatically. But `data/conf/postfix/extra.cf` does **not** expand environment variables; it is plain Postfix config. If you have changed `IPV4_NETWORK` away from the default `172.22.1`, you must hand-edit the literal IP in `extra.cf` to match. The two files will silently disagree otherwise, and Postfix will fail to reach postsrsd on the docker network.

(For the underlying reason `extra.cf` carries a literal IP instead of a service name, see the previous subsection.)

### Alternative architecture: selective routing via transport map

This image and tutorial use the upstream-canonical postsrsd integration: `sender_canonical_maps` and `recipient_canonical_maps` directives in Postfix's `extra.cf`, with postsrsd's own `domains = { … }` list (in `postsrsd.conf`) deciding what's local vs. foreign. Every outbound message's envelope sender is consulted via socketmap; postsrsd passes local senders through unchanged and rewrites foreign senders.

[nowhere.dk's *Implementing SRS with Mailcow*](https://nowhere.dk/articles/implementing-srs-with-mailcow/) documents an **alternative architecture** that pushes that local-vs-foreign decision into Postfix itself, using a MySQL transport map (querying mailcow's `domain` and `alias_domain` tables directly) plus a dedicated `cleanup-srs` service declared in `master.cf` and an internal `127.0.0.1:10029 smtpd` listener. postsrsd is then only consulted for the subset of mail that's already been determined to be a non-local outbound forward.

The two approaches are functionally equivalent for the SRS rewrite itself. The selective-routing approach trades a higher up-front config-file count (two new MySQL `.cf` files, two new Postfix services, plus careful coordination between them) for tighter automatic sync with mailcow's domain list — when you add a domain in the mailcow UI, the routing decision picks it up immediately, with no `domains = { … }` edit in `postsrsd.conf` to remember. It also depends on mailcow's internal MySQL schema and on paths like `/opt/postfix/conf/sql/` that may shift in future mailcow releases.

Choose the alternative architecture if you operate at multi-tenant or high-volume scale and want the local-domain decision to live in mailcow's database. Stick with this image's tutorial setup otherwise — it is upstream-canonical, simpler, and resilient to mailcow internal changes.

### Milter mode is not supported in this image

The Alpine `community/postsrsd` package is built without `-DWITH_MILTER=ON`, and the shipped binary contains zero libmilter linkage. This image therefore runs in socketmap mode only. Socketmap is the upstream-default integration and is functionally equivalent to milter for SRS — the rewrite happens in Postfix's `cleanup` daemon either way.

If you specifically need milter mode (e.g., to integrate alongside a non-Postfix MTA, or to chain SRS rewrites with header modifications), please [open a GitHub issue](https://github.com/tekgnosis-net/postsrsd/issues) describing your use case. If there is sustained demand a `:latest-milter` variant tag, built from source with `-DWITH_MILTER=ON`, will be published alongside the default image.

---

## Acknowledgements and additional references

- Timo Röhling and the upstream [postsrsd](https://github.com/roehling/postsrsd) project.
- [nowhere.dk's *Implementing SRS with Mailcow*](https://nowhere.dk/articles/implementing-srs-with-mailcow/) — surfaced the Dovecot Sieve `sieve_redirect_envelope_from` requirement; also documents an alternative architecture using a MySQL transport map and a dedicated `cleanup-srs` Postfix service (referenced in [Reference → Alternative architecture: selective routing via transport map](#alternative-architecture-selective-routing-via-transport-map)).
- [alvinhochun's original mailcow GitHub issue](https://github.com/mailcow/mailcow-dockerized/issues/2418) - The issue thread that really helped me setup SRS initially.
- [ethrgeist](https://github.com/mailcow/mailcow-dockerized/issues/2418#issuecomment-3416844091) — the deployment writeup that the Dockerfile and configs are based on.

## License

[MIT](LICENSE).
