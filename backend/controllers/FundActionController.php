<?php
/**
 * Fund operations that are transactions, not CRUD.
 *
 *   GET  /backend/funds.php?action=sheet&fund_id=...
 *        → { fund, payouts, payout }   — payout is what one would hand over today
 *
 *   POST /backend/funds.php?action=collect
 *        { fund_id, amount, payment_method, payment_date, notes }
 *
 *   POST /backend/funds.php?action=close        (admin; agents may close in full)
 *        { fund_id, units?, payment_method?, payout_date?, notes? }
 *
 *   POST /backend/funds.php?action=payout       (admin)
 *        { fund_id, payment_method, payout_date, notes }
 *
 *   POST /backend/funds.php?action=reverse_payout   (admin)
 *        { payout_id }
 *
 * Recording a collection used to be two writes issued by the browser — the
 * passbook row and the fund's own running total — which could and did drift
 * apart. Paying a customer out was a third, written into the deposits table.
 * The rules live on the server now, one request each.
 *
 * Who may do what follows the chit rule, for the same reason: an agent collects
 * money in, an admin hands money out.
 */
class FundActionController extends Controller
{
    public function handle(): void
    {
        $claims = $this->requireAuth();
        $role   = strtolower(trim($claims['role'] ?? ''));
        $action = $_GET['action'] ?? '';
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if ($role !== 'admin' && $role !== 'agent') {
            json_error('Only admins or agents can act on a fund', 403);
        }

        if ($action === 'sheet') {
            if ($method !== 'GET') json_error('Method not allowed', 405);
            $fundId = trim((string)($_GET['fund_id'] ?? ''));
            if ($fundId === '') json_error('Which fund?', 400);
            $this->assertAgentOwns($role, $claims, $fundId);
            json_out(FundService::sheet($fundId));
            return;
        }

        if ($method !== 'POST') json_error('Method not allowed', 405);

        $body = $this->body();

        // Handing money over, and taking it back, is an admin decision — the
        // same line chit payouts draw. A partial closure pays the closed units
        // out in the same breath, so it lands on the same side of that line.
        $isPartialClose = $action === 'close' && $this->closesPartially($body);
        if ((in_array($action, ['payout', 'reverse_payout'], true) || $isPartialClose)
            && $role !== 'admin') {
            json_error('Only admins can pay out or reverse a fund payout', 403);
        }

        $this->assertAgentOwns($role, $claims, $this->targetFundId($action, $body));

        switch ($action) {
            case 'collect':
                json_out(FundService::collect($body, $claims));
                break;

            case 'close':
                json_out(FundService::close($body, $claims));
                break;

            case 'payout':
                json_out(FundService::payout($body, $claims));
                break;

            case 'reverse_payout':
                json_out(FundService::reverse($body, $claims));
                break;

            default:
                json_error("Unknown fund action: $action", 404);
        }
    }

    /** True when the request closes fewer units than the fund holds. */
    private function closesPartially(array $body): bool
    {
        if (!array_key_exists('units', $body)) return false;
        $fundId = trim((string)($body['fund_id'] ?? ''));
        if ($fundId === '') return false;
        $stmt = Database::pdo()->prepare('SELECT `units` FROM `funds` WHERE `id` = ? LIMIT 1');
        $stmt->execute([$fundId]);
        $held = $stmt->fetchColumn();
        if ($held === false) return false;
        return round((float)$body['units'], 2) < round((float)$held, 2) - 0.001;
    }

    /**
     * The fund an action is about.
     *
     * `reverse_payout` names a payout rather than a fund, so it is resolved
     * back — checking only a fund_id the request happens to carry would let an
     * agent reverse someone else's payout by simply not sending one.
     */
    private function targetFundId(string $action, array $body): string
    {
        if ($action === 'reverse_payout') {
            $payoutId = trim((string)($body['payout_id'] ?? ''));
            if ($payoutId === '') return '';
            $stmt = Database::pdo()->prepare('SELECT `fund_id` FROM `fund_payouts` WHERE `id` = ? LIMIT 1');
            $stmt->execute([$payoutId]);
            return (string)($stmt->fetchColumn() ?: '');
        }
        return trim((string)($body['fund_id'] ?? ''));
    }

    /** Agents are confined to their own funds; admins are not. */
    private function assertAgentOwns(string $role, array $claims, string $fundId): void
    {
        if ($role !== 'agent') return;
        // An unresolvable fund is left to the service, which reports what is
        // actually missing far more usefully than a 403 would.
        if ($fundId === '') return;

        $stmt = Database::pdo()->prepare(
            'SELECT 1 FROM `funds` WHERE `id` = ? AND `assigned_agent` = ? AND `delflag` = 0 LIMIT 1'
        );
        $stmt->execute([$fundId, (string)($claims['sub'] ?? '')]);
        if (!$stmt->fetchColumn()) {
            json_error('That fund is not assigned to you', 403);
        }
    }
}
