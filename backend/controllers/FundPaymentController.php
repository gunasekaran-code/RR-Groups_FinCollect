<?php
// Fund passbook entries with role enforcement:
//   - Read:   a customer sees only their own entries; an agent sees the
//             entries on their funds plus any they collected themselves.
//   - Create: admin or agent (recording a collection).
//   - Update/Delete: admin only (corrections).
//   Customers can never write passbook entries.

class FundPaymentController extends ResourceController
{
    public function handle(): void
    {
        $claims = $this->requireAuth();
        $role   = strtolower(trim($claims['role'] ?? ''));
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if ($method === 'POST' || $method === 'PATCH' || $method === 'PUT' || $method === 'DELETE') {
            if ($role !== 'admin' && $role !== 'agent') {
                json_error('Only admins or agents can manage passbook entries', 403);
            }
        }

        // Like a loan collection, a passbook entry belongs both to the fund it
        // pays into and to the agent still holding that cash at handover.
        if ($method === 'GET') {
            AgentScope::apply($this->model::table(), $role, $claims['sub'] ?? null);
        }

        parent::handle();
    }

    /**
     * A fund's running total is the sum of its deposits, so writing one has to
     * re-derive it.
     *
     * Nothing did. Deleting a deposit left `funds.collected_amount` at the old
     * figure — the passbook lost the row and the fund still claimed the money,
     * and a fund one deposit short of its target stayed `matured` with nothing
     * to collect. The Account Book can now delete these rows directly, which
     * made a stale total reachable from a second screen.
     */
    protected function afterWrite(string $method, array $rows): void
    {
        $ids = [];
        foreach ($rows as $row) {
            if (!empty($row['fund_id'])) $ids[$row['fund_id']] = $row['fund_id'];
        }
        foreach ($ids as $id) {
            try {
                FundService::recalc(Database::pdo(), (string)$id);
            } catch (\Throwable $e) {
                error_log('FundPaymentController::afterWrite recalc failed: ' . $e->getMessage());
            }
        }
    }
}
