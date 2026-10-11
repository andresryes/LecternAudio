# OpenAudible 5.0.1 functional spec (clean-room rebuild reference)

Sources examined (read-only), 2026-10-11:

- `/Applications/OpenAudible.app/Contents/Resources/app/openaudible_mac_universal.jar` (57.7 MB). 831 app classes under `org/openaudible/**`, inspected with `javap -p -c -v` (JDK 21). Code is not obfuscated; class, method and field names are original.
- `bin/mac/ffmpeg`, `bin/mac/whisper-cli`, `webapp/` (static viewer and its 5 .md docs).
- `~/Library/OpenAudible/*.json` (prefs dir) and `/Volumes/Mac/OpenAudible/` (the library: `books.json` with 518 records).
- Secrets (`credentials.json`, `license.json`, cookies, tokens, serials, keys) are described by shape only. All values are redacted.

Conventions: "confirmed" claims come from bytecode, string constants or on-disk files. Claims marked **(inferred)** come from naming or partial evidence.

---

## 0. Architecture overview

| Layer | Packages / classes | Notes |
|---|---|---|
| Launcher | install4j (`com/install4j`), bundled JRE 21.0.9 at `Contents/Resources/jre.bundle` | `debug_mac.sh` runs the jar with logging |
| UI | `org.openaudible.desktop.swt.*` (SWT/JFace) | Main window, dialogs, player, preferences |
| Core | `org.openaudible.Audible` (singleton), `books`, `library`, `bookfiles`, `filenaming` | Book model, library load/save, file accounting |
| Audible API | `org.openaudible.audible.api.*`, `audible.APIManager`, `audible.LibraryScanner` | Login, device registration, signed API calls |
| Jobs | `queues`, `download`, `convert`, `transcribe` | Queues with configurable concurrency |
| Web | `org.openaudible.webserver.*` (Javalin), `feeds.pagebuilder.BuildWebPage` | Embedded server and static web export |
| License | `license.*`, `desktop.license.AppLicense`, `convert.PersonalUseCheck` | Paid license, demo mode, account limits |

Third-party libs in the jar: SWT/JFace (`org/eclipse`), Apache Commons/HttpClient/POI (Excel export)/Batik/Log4j, Jackson, Kotlin runtime, Javalin + OpenAPI/Swagger plugin, jsoup (login HTML parsing), opencsv, org.json.

---

## 1. Audible authentication

### 1.1 Regions (enum `AudibleRegion`, confirmed via `tableswitch` on ordinal)

| Region | TLD | Marketplace ID | Language |
|---|---|---|---|
| US | .com | AF2M0KC94RCEA | en-US |
| UK | .co.uk | A2I9A3Q2GNFNGQ | en-GB |
| DE | .de | AN7V1F1VY261K | de-DE |
| FR | .fr | A2728XDNODOQ8T | fr-FR |
| ES | .es | A1RKKUPIHCS9HS | es-ES |
| AU | .com.au | AN7EY7DTAW63G | en-AU |
| IN | .in | AJO3FBRUE6J4S | en-IN |
| IT | .it | A2N7FU2W2BU2ZC | it |
| JP | .co.jp | A1QAP3MOU4173J | ja |
| CA | .ca | A2CQZ5RBY40XE | en-CA |
| BR | .com.br | A10J1VAYUDTYRN | pt-BR |

Hosts derived per region: `www.audible.{tld}`, `api.audible.{tld}`, `www.amazon.{tld}`, `api.amazon.{tld}`, `cds.audible.{tld}` (methods `audibleURL`, `getAudibleAPIHost`, `getAmazonAPIHost`, `getAudibleHost`). The JP language string is `ja` and IT is `it` (no country suffix).

### 1.2 Login methods (`LoginMethod` enum, UI label in parentheses)

1. `DIALOG` ("Secure OpenAudible Login (without browser)"): the app fetches the Amazon sign-in HTML, parses forms with jsoup (`LoginParser`) and shows native dialogs for each step.
2. `INTERNAL_BROWSER` ("Secure Web Browser Login (recommended)"): embedded SWT browser loads `https://www.amazon.{tld}/ap/signin?...` and watches for the redirect to `/ap/maplanding`.
3. `EXTERNAL_BROWSER`: the user opens the sign-in URL in their own browser and pastes back the final `https://www.amazon.{tld}/ap/maplanding?...` URL (`LoginExternalDialog`).

A "Login with Audible Username (for Legacy users)" checkbox switches to the pre-Amazon Audible account pool (`amzn_audible_ios_lap_{cc}` assoc handle, `legacy_user=true`, register against `api.audible.{tld}` instead of `api.amazon.{tld}`) **(inferred from the `legacy` branches in `Login` and `Register`)**.

### 1.3 OAuth sign-in URL (class `Login`)

PKCE OpenID/OAuth2 request mimicking the Audible iOS app:

- `code_verifier`: 32 random bytes, base64url, 43 chars (`Expected length=43`). `code_challenge = base64url(SHA-256(verifier))`, method `S256`.
- Device serial: random hex (`Register.get_random_device_serial`) or SHA-256 derived (`get_nonrandom_device_serial`).
- `client_id = "device:" + hex( serial + "#A2CZJZGLK2JJVM" )`. `A2CZJZGLK2JJVM` is the Audible iOS device type.
- Query parameters:

```
openid.oa2.response_type=code
openid.oa2.code_challenge_method=S256
openid.oa2.code_challenge=<challenge>
openid.return_to=https://www.amazon.{tld}/ap/maplanding
openid.assoc_handle=amzn_audible_ios_{cc}          (legacy: amzn_audible_ios_lap_{cc})
openid.identity / openid.claimed_id=http://specs.openid.net/auth/2.0/identifier_select
openid.mode=checkid_setup
openid.ns=http://specs.openid.net/auth/2.0
openid.ns.oa2=http://www.amazon.com/ap/ext/oauth/2
openid.ns.pape=http://specs.openid.net/extensions/pape/1.0
openid.pape.max_auth_age=0
openid.oa2.client_id=device:<hex>
openid.oa2.scope=device_auth_access
pageId=amzn_audible_ios        (also seen: amzn_audible_ios_privatepool)
marketPlaceId=<marketplace id>
accountStatusPolicy=P1
forceMobileLayout=true
```

- User-Agent: `Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148`.
- Pre-seeded cookies (`DefaultCookies`): `frc` (random), `map-md` (base64 JSON with `device_user_dictionary`, `device_registration_data{software_version:33501644}`, `app_identifier{app_version:3.35.1, bundle_id:com.audible.iphone}`), `amzn-app-id=MAPiOSLib/6.0/ToHideRetailLink`.
- Form field `metadata1`: a browser-fingerprint JSON (template in class `MetaData`: fwcim collectors, iPhone A9 GPU, 320x568 screen) encrypted with XXTEA (class `XXTEA`) and base64-encoded **(inferred: same scheme as Amazon's fwcim script)**.

### 1.4 Dialog-mode interaction loop (`LoginInteractionKind`)

Each fetched page is classified, the UI collects input, the form is posted, and the loop repeats until the redirect reaches `/ap/maplanding`:

| Kind | Detected by | Input collected |
|---|---|---|
| `region` | first step | region choice |
| `userpass` | form with `email`/`password` | username, password (`rememberDevice`, `showPasswordChecked`) |
| `captcha` / `captcha_only` | `CAPTCHA` img, `use_image_captcha`/`use_audio_captcha` | captcha text (`CaptchaDialog`) |
| `otp` | `auth-mfa-form`, `otpCode`, `mfaSubmit` | 2FA code |
| `choice` | `auth-select-device-form`, `otpDeviceContext` | OTP delivery method |
| `cvf` | `cvf-page-content` | verification code / approval (`resend-approval-form`) |
| `ex_request` / `ex_response` | external-browser mode | URL paste-back |
| `welcome` | intro | none |

Errors: `auth-error-message-box`, "Password reset required". The final URL carries `openid.oa2.authorization_code` (or `openid.oa2.access_token` for `AuthMode.TOKEN`; `AuthMode.CODE` is the normal path).

### 1.5 Device registration (`Register`)

`POST https://api.amazon.{tld}/auth/register` (legacy: `api.audible.{tld}`)

Headers: `Host`, `Content-Type: application/json`, `Accept-Charset: utf-8`, `Accept-Language: en`, `x-amzn-identity-auth-domain: api.amazon.{tld}`, `User-Agent: AmazonWebView/Audible/3.7/iOS/12.3.1/iPhone`.

Body:

```json
{
  "requested_token_type": ["bearer","mac_dms","website_cookies","store_authentication_cookie"],
  "cookies": {"website_cookies": [], "domain": ".amazon.{tld}"},
  "registration_data": {
    "domain": "Device", "app_version": "3.56.2", "device_serial": "<serial>",
    "device_type": "A2CZJZGLK2JJVM",
    "device_name": "%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%Audible for iPhone",
    "os_version": "15.0.0", "software_version": "35602678", "device_model": "iPhone", "app_name": "Audible"
  },
  "auth_data": {"client_id": "<hex client id>", "authorization_code": "<code>",
                "code_verifier": "<verifier>", "code_algorithm": "SHA-256", "client_domain": "DeviceLegacy"},
  "requested_extensions": ["device_info","customer_info"]
}
```

Response path `response.success` holds `tokens.{bearer{access_token,refresh_token,expires_in}, mac_dms{adp_token,device_private_key}, website_cookies[], store_authentication_cookie{cookie}}`, `extensions.{device_info, customer_info}`, `customer_id`. The raw response is also dumped to `register_resp_<timestamp>.json` in the prefs dir (debug).

Deregister: `POST https://api.amazon.{tld}/auth/deregister` with `Authorization: Bearer <access_token>` and body `{"deregister_all_existing_accounts": false}` **(inferred: the boolean value; the key is confirmed)**.

### 1.6 Token refresh (`API.renewCredentials`)

`POST https://api.amazon.{tld}/auth/token` with `app_name=Audible`, `app_version=3.56.2`, `source_token=<refresh_token>`, `source_token_type=refresh_token`, `requested_token_type=access_token`. Response fields `access_token`, `expires_in` (seconds). Credentials store `expires` (epoch ms), `renew_count`, `renew_date`. On failure the account status becomes Error and the UI prompts "Your Audible Connection needs to be refreshed".

### 1.7 Request signing (`SignRequest`, `Client`)

Every call to `https://api.audible.{tld}/1.0/...` is signed with the device RSA key:

- `date` = UTC ISO-8601 with microseconds and `Z` (example constant `2020-06-29T22:39:34.379198Z`).
- `data = METHOD + "\n" + path_with_query + "\n" + date + "\n" + body + "\n" + adp_token`.
- `signature = base64( SHA256withRSA(data, device_private_key) )`.
- Headers: `x-adp-token: <adp_token>`, `x-adp-alg: SHA256withRSA:1.0`, `x-adp-signature: <signature>:<date>`, `Accept: application/json`, `Accept-Charset: utf-8`.
- The private key is a PEM `-----BEGIN RSA PRIVATE KEY-----` parsed by a hand-written DER reader (`PrivateKeyReader`).
- Response header `total-count` gives the library size.

### 1.8 Multi-account storage (`AccountManager`, `Credentials`)

`credentials.json` shape (values redacted):

```json
{
  "active_device": "<account key>",
  "<sha1-hex account key>": {
    "region": "<US|UK|...>", "audible_region": "<str>", "legacy_user": false,
    "access_token": "<redacted>", "refresh_token": "<redacted>", "expires": 0,
    "renew_count": 0, "renew_date": "<str>", "last_scan": 0, "error": "<str>",
    "adp_token": "<redacted>", "device_private_key": "<redacted>",
    "device_info": {"device_name": "", "device_serial_number": "", "device_type": ""},
    "customer_info": {"account_pool": "", "user_id": "", "home_region": "", "name": "", "given_name": ""},
    "login_cookies": {"ubid-main": "", "at-main": "", "session-token": "", "x-main": "", "sess-at-main": "", "session-id": ""},
    "store_authentication_cookie": {"cookie": ""},
    "details": { "request_id": "", "response": { "success": { "tokens": {}, "extensions": {}, "customer_id": "" } } }
  }
}
```

Account states: `OK`, `ERROR`, `DUPLICATE`. Manage Accounts dialog columns: Active, Nickname (`nick_name`), User ID (truncated Amazon ID), Last Scan Date, Status, Logout. Active accounts are scanned; inactive accounts can still download/convert. Credentials can be imported from Libation `AccountsSettings.json` and audible-cli files (`ImportLibationCredentials`, `ImportAudibleCLICredentials`).

---

## 2. Library sync (`LibraryScanner`, `API`, `APIToBook`)

### 2.1 Endpoints (all under `https://api.audible.{tld}/1.0`, signed)

| Purpose | Request |
|---|---|
| Library page | `GET /library?response_groups={G}&num_results=100&page={n}&sort_by=PurchaseDate[&purchased_after={yyyy-MM-dd'T'HH:mm:ssXXX}]` |
| One library item | `GET /library/{asin}?response_groups=...` |
| Chapters | `GET /content/{asin}/metadata?response_groups=chapter_info, last_position_heard, always-returned, content_reference, content_url` |
| Catalog product | `GET /catalog/products/{asin}?response_groups=contributors, media, price, product_attrs, product_desc, product_extended_attrs, product_plan_details, product_plans, rating, sample, sku, series, reviews, relationships, review_attrs, category_ladders, ...` |
| Catalog search / categories | `GET /catalog/products?...`, `/catalog/categories[/{id}]`, `/catalog/categories?product_plan=AllYouCanEat` |
| Customer info | `GET /customer/information?response_groups=migration_details,subscription_details_rodizio,subscription_details_premium,customer_segment,subscription_details_channels` |
| Last positions | `GET /annotations/lastpositions?asins={a1,a2,...}` |
| Collections / orders | `GET /collections`, `/collections/{id}/items`, `/library/collections`, `/library/orders` |
| PDF | `GET {audibleURL}/companion-file/{asin}` and follow `Location` |
| Podcast episodes | `GET /library?parent_asin={asin}&page={n}&num_results=...&response_groups=claim_code_url, ws4v, sample, is_downloaded, is_finished, percent_complete, always-returned, ...` |

Default library response groups `G` (field `library_groups`): `product_attrs, contributors, customer_rights, relationships, media, product_desc, product_extended_attrs, pdf_url, series, category_ladders, rating, sku, listening_status, percent_complete, is_finished`. Enum `API.Group` lists the full set Audible accepts (badge_types, categories, claim_code_url, is_downloaded, is_playable, is_removable, is_returnable, is_visible, order_details, origin, origin_asin, price, provided_review, review_attrs, reviews, sample, ws4v, ...).

### 2.2 Paging and sync modes

- `perPage = 100`. Page counter starts at 1. Loop stops when `items` is empty or `items.length < perPage` (confirmed). A failing page is retried up to 10 times.
- Each page JSON is written to `api_lib_{n}.json` in TMP (debug).
- "Quick sync" (`Sync_Quick`) passes `since` = last scan time as `purchased_after`. "Full sync" (`Sync_Full`) passes 0 **(inferred from `getLibrary(int,int,long)` and per-account `last_scan`)**.
- After the list pass, a `MetaQueue` ("DRAIN_META", "FETCHING_DETAILS") fetches per-book details: chapters, product info, annotations.
- Books not present in the API response are reported as "missing" (`FindRemovedBooks`, stat `Missing_Links`) and the user can remove them.
- Items are skipped by setting: AYCE/Plus catalog titles (`is_ayce` or `benefit_id=AYCL`) unless "Enable Included Titles", podcasts unless `enable_podcasts`, periodicals unless `enable_periodicals`.

### 2.3 API to Book mapping (`APIToBook.parseBook`)

| Book field | API source |
|---|---|
| asin, title, subtitle | `asin`, `title`, `subtitle` |
| author, narrated_by | `authors[].name`, `narrators[].name` joined with ", " |
| publisher | `publisher_name` |
| summary / description | `publisher_summary` (HTML) / `merchandising_summary` |
| duration, seconds | `runtime_length_min` |
| release_date, purchase_date | `release_date`, `purchase_date` (`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`) |
| genre | `category_ladders[].ladder[].name` joined with ":" (example "History:Americas") |
| series_name, series_sequence, series_link | `series[].title`, `.sequence`, `/series/...` |
| rating_average, rating_count | `rating.overall_distribution.average_rating`, `.num_ratings` |
| image_url | `product_images["500"]` |
| language, abridged | `language`, `format_type` (unabridged/abridged/original_recording) |
| product_id | `sku_lite` / `sku` |
| ayce | `is_ayce` |
| read_status / finished | `listening_status`, `is_finished`, `percent_complete` |
| pdf_url | `pdf_url` |
| podcast flags | `content_delivery_type` = `Periodical` / `Podcast` / `PodcastParent`; `episode_number`, `episode_count`, `new_episode_added_date`; `relationships[relationship_to_product=child, relationship_type=episode]` |
| info_link | `https://www.audible.{tld}/pd/{asin}` |
| user_id, region | from the scanning account |

### 2.4 Throttling

License responses with `license_denial_reasons` (or "being throttled" text) trigger a one-time "Account Throttled Alert" and cancel the whole download queue (`DownloadAAXQueue.cancelAll`).

---

## 3. Download

### 3.1 Codec preference

`goodCodecs = [LC_128_44100_stereo, LC_64_44100_stereo, LC_64_22050_stereo, LC_32_22050_stereo]`. The best available codec from `available_codecs` / `enhanced_codec` wins.

### 3.2 AAX path (legacy Adrm, activation-bytes protected)

1. Get a content URL: `GET https://cde-ta-g7g.amazon.com/FionaCDEServiceEngine/FSDownloadContent?type=AUDI&currentTransportMethod=WIFI&key={asin}&codec={codec}` (signed). The `Location` header is rewritten so the host is `cds.audible.{tld}`. The sidecar endpoint `.../FionaCDEServiceEngine/sidecar?type=AUDI&key={asin}` is also called (bookmark/sidecar data).
2. Resulting `download_link` shape (stored in books.json): `https://cds.audible.com/download?asin={asin}&cust_id=<redacted>&codec=LC_64_22050_stereo&source=audible_iPhone&type=AUDI&encryptParams=<redacted>`.
3. Download with `User-Agent: Audible/671 CFNetwork/1240.0.4 Darwin/20.6.0`, `Accept: */*`, `Accept-Encoding: gzip, deflate`. `Expires` in the link is checked first ("Download expires: ... in ... ms"). An older `admhelper` / `assemble_url` path also exists.
4. File lands in `{library}/aax/{filename}.AAX` (uppercase extension in the real library: 193 files).

### 3.3 AAXC path (license request, voucher)

`POST /1.0/content/{asin}/licenserequest`

```json
{"supported_drm_types": ["Mpeg","Adrm"], "consumption_type": "Download",
 "response_groups": "last_position_heard, pdf_url, content_reference, chapter_info",
 "quality": "High"}
```

(`quality` is `High` or `Normal`, enum `API.Quality`.) Dolby Atmos has a separate `getAtmosLicenseForBook` call.

- URL: `content_license.content_metadata.content_url.offline_url`.
- Codec: `content_license.content_metadata.content_reference.content_format`.
- `drm_type` from `content_license`. Mpeg means unencrypted.
- Voucher: `content_license.license_response` is base64. Decrypt with AES-128-CBC, NoPadding. `h = SHA-256(device_type + device_serial_number + customer_id + asin)`, `key = h[0:16]`, `iv = h[16:32]`. The plaintext is JSON with `key` and `iv` (32 hex chars each). The concatenation order is **(inferred)** from the 4-string concat and the public audible-cli scheme.
- Persistence (both confirmed):
  - Appended to the book's `download_link` after `#`: `url#key,iv` or `url#drm_type=...` (`Voucher.getIVKeyPairFromURL`, `cleanDownloadURL` strips it).
  - Appended to the end of the downloaded `.aaxc` file as an 82-byte trailer `{"iv":"<32 hex>","key":"<32 hex>"}` (`writeAAXCVoucher`; read back with `RandomAccessFile.seek(length-82)`).
- Downloads write to TMP first, then move into place. "All you can consume books can't be downloaded at this time" is shown for AYCE titles when licensing refuses.

### 3.4 Other download queues

- `DownloadPDFQueue` / `DownloadPDFJob`: PDF via `pdf_url` or `/companion-file/{asin}`, saved as `{library}/books/{filename}.pdf` (47 in the sample library; status shows `PDFs 47/78` = downloaded/available).
- `GetBookImageQueue`: cover from `image_url` (`..._SL500_.jpg`) to `art/{filename}.jpg`; fallback extracts embedded art with ffmpeg. Thumbnails go to `thumb/`.
- `Import_URL`: user can paste a URL of an m4a, m4b, mp3, zip or aax file.
- Concurrency: `concurrentDownloads` (default 3).

---

## 4. Conversion (`ConvertJob`, `ConvertQueue`, `FFMPEG`, `MetaTags`)

### 4.1 Key sources

| Input | Key | Source |
|---|---|---|
| `.aax` | `-activation_bytes <8 hex>` | `LookupKey.getKeyFromAAX` (below) |
| `.aaxc` | `-audible_key <32 hex> -audible_iv <32 hex>` | voucher from file trailer, `download_link`, or a fresh `licenserequest` |
| `.aa` | none (`aa` demuxer fixed key) | |
| m4a/m4b/mp3 | none | |

Activation bytes (`LookupKey`), confirmed:

1. Run `ffmpeg -i file.aax`; parse the line `[aax] file checksum == <40 hex>`. Also read the checksum directly from the file at a fixed offset and compare (`hash_ff` vs `hash_offset`; error "Hashes not equal").
2. Look up the checksum in the local cache `keys.json`.
3. On a miss, call `GET {serverBase}/api/hash/{...}/{...}?version=5.0.1` where `serverBase = https://openaudible.org`. The two path segments are the AAX checksum and the app license code (order not confirmed). Refused in demo mode ("Function not allowed in demo mode"). The response carries `key` and may carry an updated `license` object.
4. Validate the key by decoding with ffmpeg ("validate key failed for hash ..."). Cache it.

Consequence for a rebuild: OpenAudible 5.0.1 does not derive activation bytes locally and does not fetch them from Audible. The old Audible player-auth-token flow (`GetActivationBytes`: `https://www.audible.com/license/token?action=register&player_manuf=Audible,iPhone&player_model=iPhone`, `act.dat`) is present in the jar but has zero callers. A new implementation needs its own activation-bytes source (for example the registration flow or a local derivation) or should use AAXC downloads only.

### 4.2 ffmpeg command template

Steps: probe input (`AudibleProbe`), write an FFMETADATA file `TMP/{input}_meta.txt` from `MetaTags.createMetaData()`, extract or reuse cover art, run ffmpeg into `TMP/{name}_temp.{ext}`, re-probe and compare tags, then move to the final path. Argument order below follows the bytecode; positions of `-map_metadata`/`-map_chapters` relative to each other are **(inferred)**.

```
ffmpeg
  [-audible_iv IV -audible_key KEY]     # AAXC
  [-activation_bytes AB]                # AAX
  -i <input>
  -i <TMP/meta.txt>                     # input 1: ffmetadata (tags + chapters)
  [-i <cover.jpg>]                      # input 2 when art exists (artInputIndex)
  -map_metadata 1
  -map_chapters 1                       # 0 when the book has no chapter list
  -y
  # M4B / M4A:
  -c:a copy -map 0:a:0 [-map 2:v -c:v copy -disposition:v:0 attached_pic] -vn?
  -map_metadata 0 -movflags +faststart -metadata media_type=2
  # MP3:
  -codec:a libmp3lame (-qscale:a <0-9> | -b:a <N>k) -id3v2_version 3
  -metadata:s:v title=Album cover -metadata:s:v comment=Cover (front)
  [extra args, one per line, from {META}/ffmpeg_args_{m4b|mp3}.txt]
  <TMP/output_temp.ext>
```

- Progress: stderr `time=HH:MM:SS.xx` divided by the book duration; UI shows percent.
- Failure: stderr ring buffer saved as JSON `{cmd, arguments, result, stderr, err, error}` to `ffmpeg_args_*.txt` / log. "scalefactor bands" errors and `.aax` failures show the `AAXC_WARNING` text.
- M4B output is AAC stream copy (no re-encode). MP3 re-encodes with LAME.
- MP3 quality (`MP3Qualities`): CBR `160,128,112,96,64,48,40,32,24,16` kbps, VBR `-qscale:a 0..9`; default CBR 64 kbps **(inferred from the first constant)**. Stored in settings key `mp3Quality`.
- After success: optional delete of the AAX (`autoDeleteAAX`), sound effect `convert_done.wav`, library file entry added.
- Personal-use gate (`PersonalUseCheck`): each converted book's `user_id` counts toward the license's account limit (`account_max`, 5 in demo text, "up to 10" in another tip). Over the limit, conversion is refused (`USAGE_EXCEED_*`).

### 4.3 FFMETADATA and tags (`MetaTags`)

FFMETADATA file:

```
;FFMETADATA1
title=...
artist=...
...
[CHAPTER]
TIMEBASE=1/1000
START=<ms>
END=<ms>
title=<chapter title>
```

Generic tag map (written for both formats):

| Tag | Value |
|---|---|
| title | short title |
| artist, album_artist, author | author |
| album | full title (with series prefix when present) |
| album-sort | sortable full title **(inferred)** |
| composer | narrator |
| description, comment | summary with HTML stripped |
| SERIES, SERIES-PART | series_name, series_sequence |
| compilation | 0 |
| language | language |
| RATING WMP | rating_average |
| WWW | info_link |
| year, date, release_date | release date (sortable form) |
| ASIN | asin |
| genre / book_genre | genre |
| json64 | base64 of the book JSON |

M4B/M4A additional keys: `synopsys`, `copyright`, `narrated_by`, `publisher`, `asin`, `product_id`, `series_name`, `series_sequence`, `series_link`, `info_link`, `short_title`, `ldes`. MP4 atom names referenced: `©nam ©ART aART ©alb ©day ©pub cprt ©des ©cmt ©gen ©nrt ©wrt prID TCOM rldt CDEK CDET AACR stik pgap`. The `ausr` tag (Audible user) is removed from output.

Chapters: `ChaptersUtils.determineBestChapters` chooses between API chapters and the file's embedded chapters.

### 4.4 Split and join

- Split modes (`SplitMode`): `NONE`, `CHAPTER`, `TIME`, `TIME_AND_CHAPTER`, `YOTO`. Per-chapter command: `ffmpeg -ss <start> -to <end> -i <in> -map_chapters -1 -c copy | -codec:a libmp3lame ...`. Library settings: `split_by_chapter`, `split_by_time`, `split_ms` (default 3,600,000 = 60 min; minimum 10 min), `split_yoto` (Yoto player cards, `yoto_<n>.jpg`), `split_cover` (`cover.jpg`), `split_nfo`, `split_json`, `split_delete_source`, `split_automatically`. Output goes to a per-book directory with numbered tracks; `last_split.txt` log.
- Join (`JoinAudio`): ffmpeg `-f concat -safe 0 -i files_<n>.txt` plus a generated FFMETADATA with one chapter per input file; output m4b (AAC copy) or mp3 (128k libmp3lame). Needs at least 2 files of one format.
- Retag (`UpdateMetaData`): rewrites tags/cover in place via a temp file when the user edits metadata.
- Artwork add (`AddArtwork`): `-map 0:0 -map 1:0 -c copy -disposition:v:0 attached_pic -id3v2_version 3`.

---

## 5. PDFs, podcasts, other content

- PDFs: see 3.4. Setting `autoPDF` downloads them alongside the book. Status counter `PDFs = downloaded/available`.
- Podcasts: enabled per library (`enable_podcasts`). Parent shows (`PodcastParent`) are expanded via `/library?parent_asin=`. Episodes go to `{library}/podcasts/` (path template `podcasts_path`). Podcast table columns: title, episodes, latest. Commands: Ignore Podcast, Stop Ignoring, Delete Podcast, Show Ignored Podcasts. View switch `ViewMode` = `Audiobooks` | `Podcasts`.
- Periodicals: `enable_periodicals`; stored with books.
- Librivox: `https://librivox.org/api/feed` (search/import of public-domain books) **(inferred usage)**.
- Transcription: bundled `whisper-cli` (whisper.cpp). Models downloaded from Hugging Face (`ggml-org`, VAD model `ggml-silero-v5.1.2.bin`). ffmpeg first converts to WAV. Output formats via `transcribe.formats`. Transcript viewer window, "Has_Transcripts" status counter. Settings block `transcribe{}` (see section 8).
- Annotations: `/annotations/lastpositions` populates `position_ms` and an `annotations` object (`records[]` with `type: audible.last_heard`, `startPosition`).
- Cover poster export (`CreatePoster`): grid of covers rendered to one image.

---

## 6. Data model and on-disk layout

### 6.1 Directories (`directories.json`, `Directories` enum)

```json
{"META": "~/Library/OpenAudible", "APP": "<app>/Contents/Resources/app",
 "TMP": "~/Library/OpenAudible/tmp", "BASE": "/Volumes/Mac/OpenAudible",
 "#": "Modify with care..."}
```

- `META`: prefs directory. Override with env `OPENAUDIBLE_HOME`. Linux honors `XDG_DATA_HOME`. "Portable mode" keeps everything next to the app.
- Files in META: `settings.json`, `directories.json`, `libraries.json`, `credentials.json`, `license.json`, `status.json`, `commands.json`, `windows.json`, `keys.json`, `.lock`, `tmp/log.txt`.
- Warnings when BASE is on a cloud-synced or network drive (Dropbox, OneDrive, Google Drive, iCloud `com~apple~CloudDocs`, smb/nfs/cifs).

### 6.2 Library root (one per `libraries.json` entry)

```
{library_path}/
  books.json             # array of Book records (518 in the sample)
  books_backup.json      # previous save, used for recovery (BACKUP_USED_*)
  aax/   {filename}.AAX | .aaxc
  art/   {filename}.jpg  # 500px covers
  thumb/ {filename}.jpg
  books/ {filename}.m4b | .mp3 | .m4a | .pdf
  podcasts/
```

Also seen: `books_before_reorganize.json`, `books_damaged.json`, `saved_books.json`, `reorganize_log.txt`, `stats.json`.

### 6.3 Book record (`books.json`, field frequency over 518 records)

All values are strings except `seconds` (int), `chapters` (array), `files` (array), `annotations` (object).

| Field | Count | Example / notes |
|---|---|---|
| key | 518 | Primary key. Usually `product_id`; for imported books a 27-char base64 hash |
| title, title_short | 518 / 515 | |
| filename | 518 | Base name used for every file of the book |
| duration, seconds | 518 | `"12:14:00"`, `44040` |
| release_date, purchase_date | 518 | `yyyy-MM-dd` |
| files | 518 | `[{path, kind, type}]`, path relative to its typed directory |
| chapters | 516 | `[{start_offset_ms, length_ms, title, start_offset_sec}]` |
| author, narrated_by, publisher | ~510 | comma-separated names |
| description, summary | 514 / 507 | summary is HTML |
| genre | 513 | `"History:Americas"` |
| language | 507 | `"english"` |
| asin, product_id | 507 | `B00D7MLV1U`, `BK_TCCO_000026` |
| rating_average, rating_count | 506 | |
| info_link, author_link, series_link | 506 / 438 / 49 | |
| image_url | 506 | `https://m.media-amazon.com/images/I/<id>._SL500_.jpg` |
| download_link | 506 | see 3.2 / 3.3 |
| user_id | 506 | owning Audible account (redacted) |
| ayce | 506 | `"true"` / `"false"` |
| region | 506 | `"US"` |
| abridged | 474 | |
| copyright | 397 | |
| read_status | 224 | `Unread`, `Reading`, `Finished`, `Want_To_Read`, `Did_Not_Finish`, `None` |
| ignored | 115 | `"true"` |
| pdf_url | 85 | CloudFront PDF URL |
| finished | 74 | |
| series_name, series_sequence | 49 / 19 | |
| annotations, position_ms | 4 | |

Example record (trimmed, identifiers redacted):

```json
{
 "key": "BK_TCCO_000026", "asin": "B00D7MLV1U", "product_id": "BK_TCCO_000026",
 "title": "American Religious History", "title_short": "American Religious History",
 "filename": "American Religious History",
 "author": "Patrick N. Allitt, The Great Courses", "narrated_by": "Patrick N. Allitt",
 "publisher": "The Great Courses", "genre": "History:Americas", "language": "english",
 "duration": "12:14:00", "seconds": 44040,
 "release_date": "2013-07-08", "purchase_date": "2023-09-06",
 "series_name": "The Great Courses: Christianity",
 "series_link": "/series/The-Great-Courses-Christianity-Audiobook/B00DMMXI5W",
 "rating_average": "4.613577023498695", "rating_count": "383",
 "info_link": "https://www.audible.com/pd/B00D7MLV1U",
 "image_url": "https://m.media-amazon.com/images/I/41YSxtbB4VL._SL500_.jpg",
 "pdf_url": "https://d2fahduf2624mg.cloudfront.net/post_purchase_docs/BK_TCCO_000026/.../bk_tcco_000026.pdf",
 "download_link": "https://cds.audible.com/download?asin=B00D7MLV1U&cust_id=<redacted>&codec=LC_64_22050_stereo&source=audible_iPhone&type=AUDI&encryptParams=<redacted>",
 "ayce": "true", "region": "US", "user_id": "<redacted>", "read_status": "Unread",
 "chapters": [{"start_offset_ms": 0, "length_ms": 135090, "title": "Opening Credits", "start_offset_sec": 0}],
 "files": [{"path": "American Religious History.jpg", "kind": "image", "type": "ART"}]
}
```

`files[].type` values: `AAX`, `M4B`, `M4A`, `MP3`, `PDF`, `ART`, `THUMB`, `TRANSCRIPT`, `ZIP`. `files[].kind`: `audio`, `image`, `pdf`, `other`, `txt`, `json`, `cue`, `zip`, `dir`. Sample distribution: ART 512, M4B 374, AAX 193, PDF 47, MP3 8.

`BookElement` enum (the full set of storable fields) also includes: `full_title`, `podcast`, `podcast_parent`, `parent_asin`, `periodical`, `episode_id`, `season_number`, `network`, `notes`, `locked`, `directory_type`, `sub_genre`, `order_number`, `cust_id`, `codec`, `source`, `info_link_error`, `title_id`.

### 6.4 Book state machine (`BookState`, computed by `DetermineBookStatus`)

`STATE_READY_TO_DOWNLOAD` → `STATE_IN_DOWNLOAD_QUEUE` → `STATE_DOWNLOADING` → (`STATE_DOWNLOAD_ERROR` | `STATE_UNABLE_TO_DOWNLOAD`) → `STATE_READY_TO_CONVERT` → `STATE_IN_CONVERT_QUEUE` → `STATE_CONVERTING` → `STATE_CONVERTED_OK` | `STATE_CONVERT_ERROR` | `STATE_UNABLE_TO_CONVERT`. Others: `STATE_LOCAL_AUDIO_FILE`, `STATE_NO_AUDIO_FILE`, `STATE_NOT_A_PURCHASE`, `STATE_ACCOUNT_MISMATCH`, `STATE_IN_TRANSCRIBE_QUEUE`, `STATE_TRANSCRIBING`, `STATE_AUDIOBOOK_DIRECTORY[_ERROR]`, `STATE_PODCAST_DIRECTORY[_ERROR]`.

### 6.5 File naming (`filenaming.*`)

- Default: flat, `{title}.{ext}`, `filename` = sanitized title, typed directory per extension (`aax/`, `books/`, `art/`, `thumb/`).
- Custom templates (library field `naming_format`, `strategy`). Built-in samples (`SampleStrategies`):
  - `{title}.{ext}`
  - `{title} [{id}].{ext}`
  - `{title} [{id}]/{title}.{ext}`
  - `{author_first}/{title}/{title}.{ext}`
  - `{author_first}/{series_name}/{title}/{title}.{ext}`
  - `{genre}/{author_first}/{series_name}/{title}/{title}.{ext}`
  - `{series_name}/{title}.{ext}`
  - `{title_short_libation} [{id}]/{title_libation} [{id}].{ext}` (Libation-compatible)
- Macro grammar: `\{(\w+)(?::([^}]+))?\}`, any BookElement name, optional format (`{release_date:yyyy}`). Suffixes `_first` (first of a list) and `_unique`. Extra macros `id`, `ext`, `title_libation`, `title_short_libation`.
- Validation: path must end with `.{ext}`, `{ext}` only once; no `//`, `..`, tabs, double spaces, leading/trailing spaces; Windows reserved names (CON, PRN, AUX, NUL, COM1-9, LPT1-9); segment max 250 chars; total length vs measured filesystem limit; collisions resolved with variations or error "cannot give '...' a unique path".
- `one_book_per_directory`, `similar_unicode_names` options. "Reorganize" moves existing files to the new template and logs to `reorganize_log.txt`.

### 6.6 Libraries (`libraries.json`)

Array `libraries[]`, one marked `current: true`. Fields: `library_path`, `books_path`, `podcasts_path`, `aax_path`, `naming_format`, `strategy`, `accounts`, `one_book_per_directory`, `similar_unicode_names`, `enable_podcasts`, `enable_periodicals`, `enable_annotations`, `enable_rescan_meta_updates`, `split_*` (see 4.4), `web_enabled`, `web_path`, `web_page_name`, `web_page_prefix`, `web_page_copy_media`, `web_page_auto_build`. Commands: Open, New, Copy, Move, Delete, Migrate library; Merge from a remote OpenAudible over HTTP (`ApiLibraryMerge` uses `/api/books/{id}`, `/admin/api/books/{id}/files`, Basic auth).

### 6.7 Automation protocol (`status.json`, `commands.json`)

`status.json` is rewritten while running:

```json
{"command_file": "<META>/commands.json", "version": "5.0.1", "quit": false, "last_cmd": 0,
 "commands": ["Quit","Export_Web_Page","Sync_Quick","Sync_Full","Download_All","Convert_All","Refresh_Files","Cancel_All_Jobs"],
 "queues": {}, "status": { "<LibraryStat>": "<value>" }}
```

An external tool writes a command list to `commands.json`; the app polls and executes it **(inferred polling)**. Sample status values: Books 403, Hours 3798, M4B_Files 374, AAX_Files 193, MP3_Files 8, M4A_Files 0, PDFs 47/78, Ignored 115, To_Download 144, To_Convert 0, AYCE 207, Podcasts 0, Missing_Links 0, Connected Yes, License Valid.

### 6.8 License (`license.json`, shape only)

`{license_hash, license_data{reference, license, expires, created, account_max, name, account_list[], state, source, email}}`. Purchase at `https://openaudible.org/purchase`. Demo mode limits conversion and transcription to the bundled "Welcome to OpenAudible" book.

---

## 7. UI features

### 7.1 Main window

- Top: search field (filters title/author/narrator and other text columns; `BookFilter` kinds `text`, `status`, `elem`), view toggle Audiobooks/Podcasts, settings cog.
- Library status panel (`LibraryStat` enum, each clickable to filter): `Books`, `Hours`, `AAX_Files`, `M4B_Files`, `M4A_Files`, `MP3_Files`, `PDFs`, `Podcasts`, `AYCE`, `Ignored`, `To_Download`, `To_Convert`, `Downloading`, `Converting`, `Missing_Links`, `Duplicates`, `Has_Transcripts`, `Connected`, `License`.
- Book table columns (`BookTableColumn`, user-selectable via "Table Settings"): File (status icon), Title, Author, Narrated By, Duration, Purchase Date, Release Date, Rating, Rating Count, Genre, Series Name, Series Sequence, Series Link, Notes, Product ID, ASIN, Key, Filename, Read Status, Finished, Abridged, Locked, AYCE, Language, User ID, Directory Type, Debug. Sortable (`BookTableComparator`).
- Cover grid view (`CoverGrid`), book info panel with cover and summary, job status panel with mini progress bars, console/log window, hints bar (`HintManager`).
- Get Info dialog tabs: Details, Tags (editable, "Auto Fill" from ASIN/ISBN), Chapters (read-only), Files, Image (replace cover, Google image search link), Annotations, Text.
- Drag and drop of audio files into the window (`FileDropTarget`) imports them.

### 7.2 Menu commands (`Command` enum)

File/Library: Connect, Manage_Accounts, Sync_Quick, Sync_Full, Open_Library, New_Library, Copy_Library, Move_Library, Delete_Library, Migrate_Library, Manage_Libraries, Library_Settings, Import_Books, Import_URL, Import_Directory, Refresh_Files, Preferences, Quit.
Book actions: Download, Download_All, Convert, Convert_MP3, Convert_M4B, Convert_All, Get_PDF, Play, Reveal, Show_MP3/M4A/AAX/M4B/PDF, View_Online, Get_Info, Rename_Book, Ignore_Book, Unignore_Book, Delete_Book, Split_Selected_Books, Split_By_Chapter, Join_Audio_Files, Transcribe, View_Transcript, Try_Transcribe, Cancel_Job, Cancel_All_Jobs, Show_Job_Status.
Export: Export_Web_Page, Export_Book_List, Export_Excel (.xlsx via POI), Export_CSV, Export_JSON, Export_Repeat, Export_Cover_Art_Poster, Book_Report.
Help: Help (`https://openaudible.org/documentation`), AI_Help, Diagnostics, Send_Bug_Report, Check_For_Update, About, License, Purchase, Upgrade, Status.

### 7.3 Built-in player (`desktop.swt.manager.player`, `org.openaudible.player`)

ffmpeg decodes to PCM piped into Java Sound (`ProcessToBuffer`, `AudioRingBuffer`). Mini and full player views; skip ±5/15/30 s, previous/next chapter, speed (`player_speed`), volume (`player_volume`), chapter list, position indicator. Live transcript display when a transcript exists (`TextChunker`, `WhisperProcessStreaming`).

### 7.4 Web export (static)

`BuildWebPage` writes to the web directory: `index.html` (stats), `compact.html` (sortable table), `gallery.html` (covers in 3 sizes), `player.html` (Plyr-based player, chapter list, resume via localStorage, speed), `assets/`, plus generated `audiobooks.js`:

```js
window.librarySettings = {libraryName, generatedTimestamp, generatedDate, basePath, totalHours,
  totalMilliseconds, thumbnailSize: 200, averageRating, count, darkMode, version,
  theme: "default|brutalist|warm|terminal|minimal", showThemeSelector};
window.audiobooks = [ <Book JSON with chapters and files> ];
```

Options: copy media into the web dir (`web_page_copy_media`) or reference originals with relative/absolute paths; include MP3 (`webPageIncludeMP3`); auto rebuild (`autoWebPage`, `web_page_auto_build`).

### 7.5 Embedded web server (`OAWebServer`, Javalin)

- OpenAudible routes: `/ping`, `/api/books`, `/api/books/{id}`, `/api/books/{id}/chapters[/flat]`, `/api/books/{id}/cover`, `/api/books/{id}/files/{name}`, `/api/library`, `/api/library/export`, `/audiobooks.js`, `/audiobooks-config.js`.
- Admin: `/admin` (`admin.html`), `/admin/api/status|version|diagnostics|commands|command/{name}|books/{id}/{action}|books/{id}/files|books/{id}/file|import|debugAction`, `/admin/openapi.json`, `/admin/swagger`.
- Audiobookshelf-compatible API (package `webserver.abs`; mobile ABS clients can connect **(inferred purpose)**): `/login`, `/logout`, `/auth/refresh`, `/status`, `/healthcheck`, `/api/authorize`, `/api/me`, `/api/libraries[/{id}[/items|/search|/series|/authors|/filterdata|/personalized]]`, `/api/items/{id}[/cover|/play[/{episodeId}]|/file/{ino}[/download]]`, `/api/session/{id}[/sync|/close]`, `/api/session/local[-all]`, `/public/session/{id}/track/{index}`, `/api/me/progress[...]`, `/api/me/progress/batch/update`, `/api/me/bookmarks`, `/api/me/item/{id}/bookmark[/{time}]`, `/socket.io`.
- Auth: JWT (`JwtUtil`), users in settings `webUsers[]` with hashed passwords (`PasswordHash`); per-user progress and bookmarks (`ProgressStore`, `BookmarkStore`).
- Settings: `webServerEnabled`, `webServerHost`, `webServerPort`.

### 7.6 Other UI

Themes (`themes.json`, palette dialog), 10 UI languages (de, en, es, fi, fr, it, ja, pt, ru, zh) in `org/openaudible/languages/i18n_*.properties` (1143 keys in the base file), font choice, accessibility mode, sound effects (`download_done.wav`, `convert_done.wav`, `error.wav`), version check against `https://openaudible.org`.

---

## 8. Settings

### 8.1 `settings.json` (global, with values seen on this machine)

| Key | Value seen | Meaning |
|---|---|---|
| autoConvert | true | convert after download |
| autoDownload | false | queue new books for download |
| autoPDF | true | download companion PDFs |
| autoDeleteAAX | false | delete AAX after conversion |
| autoWebPage | false | rebuild web export when books change |
| webPageIncludeMP3 | true | |
| autoConnect | false | quick sync at startup |
| autoRefreshHours | 0 | scheduled sync interval ("Auto Sync Every") |
| autoShowProgress | true | |
| format | "M4B" | output format: M4B, MP3 (M4A deprecated) |
| mp3Quality | "" | e.g. `cbr_64k`, `vbr_<n>` (format from string recipes) |
| concurrentConversions | 3 | |
| concurrentDownloads | 3 | |
| player_enabled, player_volume, player_speed | true, 0.75, 1.0 | |
| browseFileCmd, browseWebCmd, playFileCmd, transcribeCmd | "" | helper application command lines |
| browser | "" | internal/external browser |
| language, theme, fontName, fontSize, accessibility, soundEffects | | UI |
| viewMode | "" | Audiobooks/Podcasts |
| disableVersionCheck, lastVersion, uid | false, "5.0.1", <id> | |
| html, expert, recommendPrompt, disableWelcomeFile | | misc |
| webServerEnabled, webServerHost, webServerPort, webUsers[] | false, "", 0, [] | |
| transcribe{} | | `modelDir, model, enginePath, formats, format, wordTimings, overwrite, language, translate, threads, gpu, vad, vadModel, bookPrompt, suppressNonSpeech, extraArgs` |

### 8.2 Per-library settings

See 6.6. UI tabs in Library Settings: General, Paths (with macro "Insert field" combo), Split, Web, Features (podcasts, periodicals, annotations, included titles).

### 8.3 `windows.json`

Window geometry per dialog (`WindowPrefs`).

---

## 9. Bundled binaries and runtime

| Item | Details |
|---|---|
| `bin/mac/ffmpeg` | Universal (x86_64 + arm64). FFmpeg 8.0, custom minimal static build (`OAINFO=ffmpeg_vers_8.0,compiled_20260921,builder_github.com/openaudible/ffmpeg-build`). `ffmpeg -L` reports LGPL (no `--enable-gpl`). Enabled: demuxers `aa, mov, mp3, aac, ac3, eac3, truehd, ogg, wav, concat, ffmetadata, image2, mjpeg, apng`; muxers `mp4, mov, ipod, mp3, ogg, opus, wav, ffmetadata, image2, mjpeg, apng`; encoders `aac, libmp3lame, libopus, ac3, png, mjpeg, pcm_*`; filters `atempo, aresample, atrim, aformat, scale, ...`; protocols `file, pipe, concat, concatf`. Supports `-activation_bytes`, `-audible_key`, `-audible_iv`, `-audible_fixed_key`, `-aa_fixed_key`. No separate ffprobe binary ships; `FFProbe` drives the same executable with a `-probe` style invocation **(inferred: custom flag)** and JSON output (`format`, `streams`, `tags`). |
| `bin/mac/whisper-cli` | Universal. whisper.cpp CLI by Georgi Gerganov (MIT). Variants referenced for other OSes: `whisper-cli-avx2`, `whisper-cli-vulkan`. |
| JRE | `jre.bundle`, Java 21.0.9 |
| Launcher | install4j (`i4jlauncher.config`, `.install4j/`) |
| Sample media | `webapp/sample/books/Welcome to OpenAudible.m4b` (9 chapters, 9:04), `org/openaudible/player/demo.mp3` |

---

## Rebuild notes (gaps and risks)

1. Activation bytes for AAX come from openaudible.org's key server, keyed by the paid license. A clean-room rebuild must source them differently or rely on AAXC only.
2. The login scrapes Amazon HTML and posts an XXTEA-encrypted fingerprint. Amazon changes this flow often; the internal/external browser methods are the robust fallback.
3. App version strings (`3.56.2`, `35602678`, iOS `15.0.0`) are hard-coded identity values for the iOS Audible app.
4. Personal-use account limits and demo restrictions are product rules, not technical requirements.
