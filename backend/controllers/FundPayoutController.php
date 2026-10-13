<?php
// Fund payouts, read-only over rest.php.
//
// The Funds list needs to know which funds have already been paid out, so it
// can stop offering a Payout button for money that has gone. Writing one is a
// transaction — a cash_out row and the payout record together — so it lives in
// funds.php and this endpoint refuses to create, amend or remove anything.
//
//   Read: a customer sees only their own; an agent sees the payouts on their
//         funds plus any they handed over themselves.

class FundPayoutController extends ResourceController
{
    public function handle(): void
    {
        $claims = $this->requireAuth();
        $role   = strtolower(trim($claims['role'] ?? ''));
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if ($method !== 'GET') {
            json_error('Payouts are recorded through funds.php, not directly', 405);
        }

        AgentScope::apply($this->model::table(), $role, $claims['sub'] ?? null);

        parent::handle();
    }
}
