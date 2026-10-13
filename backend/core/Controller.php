<?php
// Base controller: request body + JWT auth guards.

abstract class Controller
{
    protected function body(): array
    {
        return read_json_body();
    }

    /** Returns JWT claims or exits 401. */
    protected function requireAuth(): array
    {
        $token = bearer_token();
        if (!$token) {
            json_error('Missing authorization token', 401);
        }
        $claims = Jwt::decode($token);
        if (!$claims) {
            json_error('Invalid or expired token', 401);
        }
        if (!empty($claims['sub'])) {
            $p = Profile::firstRaw(' WHERE id = ?', [$claims['sub']]);
            if ($p && !empty($p['role'])) {
                $claims['role'] = strtolower(trim($p['role']));
            }
            self::assertStillAllowed($p);
        }
        $claims['role'] = strtolower(trim($claims['role'] ?? ''));
        return $claims;
    }

    /**
     * Refuse a token belonging to an account that has since been shut off.
     *
     * Sign-in checks `status`, so an inactive account cannot get a token. It
     * could keep using one it already had: tokens last seven days, so
     * switching somebody to Inactive in User Management left them working
     * normally for up to a week. The row is already being read here for the
     * role, so checking it costs nothing.
     *
     * A profile that has disappeared or been soft-deleted is the same case —
     * the account is gone, and a token is not a second opinion.
     */
    private static function assertStillAllowed(?array $p): void
    {
        if (!$p) {
            json_error('This account no longer exists', 401);
        }
        if (strtolower(trim((string)($p['status'] ?? 'active'))) === 'inactive') {
            json_error('Your account is inactive. Please contact the administrator.', 403);
        }
        if (!empty($p['delflag'])) {
            json_error('This account no longer exists', 401);
        }
    }

    /** Attempts auth but returns null instead of dying if no/invalid token. */
    protected function tryAuth(): ?array
    {
        $token = bearer_token();
        if (!$token) {
            return null;
        }
        $claims = Jwt::decode($token);
        if (!$claims) {
            return null;
        }
        if (!empty($claims['sub'])) {
            $p = Profile::firstRaw(' WHERE id = ?', [$claims['sub']]);
            if ($p && !empty($p['role'])) {
                $claims['role'] = strtolower(trim($p['role']));
            }
            // "Try" means the caller tolerates there being nobody signed in —
            // it does not mean a shut-off account gets in through the side
            // door. An inactive or deleted account is nobody.
            if (!$p
                || strtolower(trim((string)($p['status'] ?? 'active'))) === 'inactive'
                || !empty($p['delflag'])) {
                return null;
            }
        }
        $claims['role'] = strtolower(trim($claims['role'] ?? ''));
        return $claims;
    }

    /** Requires an authenticated admin, or exits 401/403. */
    protected function requireAdmin(): array
    {
        $claims = $this->requireAuth();
        if (($claims['role'] ?? '') !== 'admin') {
            json_error('Admin access required', 403);
        }
        return $claims;
    }
}
