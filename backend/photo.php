<?php
/**
 * Entry point → one stored image, as an image.
 *
 *   GET /backend/photo.php?table=customers&id=<uuid>[&col=photo_url]
 *
 * The images in this system are kept in the database as base64 data URLs,
 * which is convenient for storage and ruinous for lists. A customer's avatar
 * is about 25 KB; a hundred and eighty of them travelling inside the JSON of
 * `rest.php?table=customers` came to 3.7 MB, and 99% of that list was
 * photographs of faces that the table draws at 36 pixels across.
 *
 * So the list stops carrying them and they are fetched here instead, one
 * request per picture. That is not merely a smaller total — it is a better
 * shape:
 *
 *   - the table can paint as soon as the names arrive, instead of waiting
 *     for every face to come down the wire first;
 *   - the browser only asks for the avatars actually scrolled into view;
 *   - an image request is cacheable, and this one says so, so the second
 *     visit spends nothing on pictures that have not changed.
 *
 * Auth is the ordinary Bearer JWT, read through `bearer_token()`. The
 * frontend fetches these with the Authorization header like any other call
 * rather than putting them in an `<img src>`, which keeps the token out of
 * access logs, browser history and `Referer`.
 */
require_once __DIR__ . '/bootstrap.php';
send_cors();

$token  = bearer_token();
$claims = $token ? Jwt::decode($token) : null;
if (!$claims) {
    json_error('Missing or invalid token', 401);
}
$role = $claims['role'] ?? '';

/**
 * What may be served, named explicitly.
 *
 * An allow-list rather than "any table, any column": this endpoint turns a
 * caller-supplied name into a column read, and the one thing it must never
 * do is become a way to read arbitrary columns of arbitrary tables one
 * request at a time.
 */
const PHOTO_SOURCES = [
    'customers' => [
        'model'   => 'Customer',
        'columns' => ['photo_url', 'aadhaar_front_url', 'aadhaar_back_url', 'pan_url', 'signature_url'],
    ],
    'collections' => [
        'model'   => 'Collection',
        'columns' => ['proof_url', 'signature_url'],
    ],
    // A login's own picture. Only the avatar: the KYC columns on `profiles`
    // are not images and are nobody else's business.
    'profiles' => [
        'model'   => 'Profile',
        'columns' => ['avatar_url'],
    ],
];
$table = (string)($_GET['table'] ?? 'customers');
$id    = (string)($_GET['id'] ?? '');
$col   = (string)($_GET['col'] ?? 'photo_url');

if (!isset(PHOTO_SOURCES[$table])) {
    json_error("No images are served from '$table'", 404);
}
if (!in_array($col, PHOTO_SOURCES[$table]['columns'], true)) {
    json_error("'$col' is not an image column of '$table'", 404);
}
if ($id === '') {
    json_error('id is required', 400);
}

$model = PHOTO_SOURCES[$table]['model'];
$rows  = $model::select(' WHERE id = ?', [$id], '', ' LIMIT 1', "`id`, `$col`" . ($table === 'customers' ? '' : ', `customer_id`'));
$row   = $rows[0] ?? null;
if (!$row) {
    json_error('Not found', 404);
}

// A customer may only look at their own pictures. Admin and agent may look at
// anyone's, which is what the customers table and the receipt view need.
if ($role === 'customer') {
    // A profile avatar is owned by the login it belongs to, which the token
    // already names — no need to go through `customer_id` for it. That also
    // keeps an agent's photograph private: their row has no customer_id, so
    // the comparison below would have let it through on a null match.
    if ($table === 'profiles') {
        if (($row['id'] ?? null) !== ($claims['sub'] ?? '')) {
            json_error('Not allowed to view this image', 403);
        }
    } else {
        $me   = Profile::findPublic($claims['sub'] ?? '');
        $mine = $me['customer_id'] ?? null;
        $owner = $table === 'customers' ? ($row['id'] ?? null) : ($row['customer_id'] ?? null);
        if (!$mine || $mine !== $owner) {
            json_error('Not allowed to view this image', 403);
        }
    }
}

$stored = (string)($row[$col] ?? '');
if ($stored === '') {
    // Nothing uploaded — which is not an error. This first returned 404, on
    // the reasoning that the browser would cache the absence and the avatar
    // would fall back to initials. Both of those were true, and it was still
    // wrong: 404 is a failure status, so every customer who has not had their
    // photograph taken printed a red "Failed to load resource" in the console.
    // Thirty of thirty-two customers, describing something entirely normal.
    //
    // 204 says the same thing — there is no picture here — without claiming
    // anything went wrong, and is still cacheable.
    http_response_code(204);
    header('Cache-Control: private, max-age=300');
    exit;
}

/**
 * Turn what is stored back into bytes.
 *
 * Almost everything here is a `data:image/jpeg;base64,...` written by the
 * uploader, but rows predating it may hold a bare base64 string or a plain
 * http URL, and neither should 500.
 */
$type = 'image/jpeg';
$bytes = null;

if (preg_match('#^data:([-\w.+/]+);base64,(.*)$#s', $stored, $m)) {
    $type  = $m[1];
    $bytes = base64_decode($m[2], true);
} elseif (preg_match('#^https?://#i', $stored)) {
    // An externally hosted picture: send the browser there instead of
    // fetching it on the server's behalf.
    header('Location: ' . $stored, true, 302);
    exit;
} else {
    $bytes = base64_decode($stored, true);
}

if ($bytes === false || $bytes === null || $bytes === '') {
    json_error('The stored image could not be decoded', 422);
}

// The content is its own version: if the picture has not changed, the ETag
// has not changed, and the browser is told to keep the copy it has. A
// revalidation costs one small 304 instead of 25 KB.
$etag = '"' . md5($stored) . '"';
header('Content-Type: ' . $type);
header('Cache-Control: private, max-age=86400, must-revalidate');
header('ETag: ' . $etag);

$sent = $_SERVER['HTTP_IF_NONE_MATCH'] ?? '';
if ($sent !== '' && trim($sent) === $etag) {
    http_response_code(304);
    exit;
}

header('Content-Length: ' . strlen($bytes));
echo $bytes;
