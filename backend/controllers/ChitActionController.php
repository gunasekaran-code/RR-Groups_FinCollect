<?php
/**
 * Chit actions that are transactions, not CRUD.
 *
 *   POST /backend/chit.php?action=collect
 *        { group_id, member_id, amount, payment_method, payment_date, notes }
 *        → { payment, passbook, member, group }
 *
 *   POST /backend/chit.php?action=generate_schedule
 *        { group_id }
 *        → the rebuilt chit_schedules rows
 *
 * Both used to be sequences of writes issued by the browser. Recording a
 * collection took six round trips, allocated the draw in JavaScript, and left a
 * cash-book receipt behind with no payment against it if the tab closed midway.
 * The rules now live on the server, in one request each.
 */
class ChitActionController extends Controller
{
    public function handle(): void
    {
        $claims = $this->requireAuth();
        $role   = strtolower(trim($claims['role'] ?? ''));
        $action = $_GET['action'] ?? '';
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if ($role !== 'admin' && $role !== 'agent') {
            json_error('Only admins or agents can act on a chit group', 403);
        }

        // Reading the auction sheet is a GET; everything else moves data.
        if ($action === 'auctions') {
            if ($method !== 'GET') json_error('Method not allowed', 405);
            $groupId = trim((string)($_GET['group_id'] ?? ''));
            if ($groupId === '') json_error('Which group?', 400);
            $this->assertAgentOwns($role, $claims, $groupId);
            json_out(ChitAuctionService::forGroup($groupId));
            return;
        }

        if ($method !== 'POST') {
            json_error('Method not allowed', 405);
        }

        // Paying a prize out, and unpaying one, is money leaving and returning
        // to the safe. An agent records who won; an admin hands over the cash.
        if (in_array($action, ['settle_auction', 'reverse_payout', 'delete_auction'], true)
            && $role !== 'admin') {
            json_error('Only admins can settle or reverse a chit payout', 403);
        }

        // Every action below names the group it works on, directly or through
        // the member it collects from. An agent may only act on their own.
        $this->assertAgentOwns($role, $claims, $this->targetGroupId($action));

        switch ($action) {
            case 'collect':
                json_out(ChitPassbookService::collect($this->body(), $claims));
                break;

            case 'generate_schedule':
                $groupId = trim((string)($this->body()['group_id'] ?? ''));
                if ($groupId === '') json_error('Which group?', 400);
                json_out(ChitPassbookService::regenerateSchedule($groupId));
                break;

            case 'record_auction':
                json_out(ChitAuctionService::record($this->body(), $claims));
                break;

            case 'settle_auction':
                json_out(ChitAuctionService::settle($this->body(), $claims));
                break;

            case 'reverse_payout':
                json_out(ChitAuctionService::reverse($this->body(), $claims));
                break;

            case 'delete_auction':
                json_out(ChitAuctionService::remove($this->body(), $claims));
                break;

            default:
                json_error("Unknown chit action: $action", 404);
        }
    }

    /**
     * The group an action is about.
     *
     * `collect` names a member and `settle_auction` an auction, so both are
     * resolved back to their group — checking only the group_id a request
     * happens to carry would let an agent act on someone else's member by
     * simply not sending one.
     */
    private function targetGroupId(string $action): string
    {
        $b = $this->body();

        if ($action === 'collect') {
            $memberId = trim((string)($b['member_id'] ?? ''));
            if ($memberId === '') return '';
            $stmt = Database::pdo()->prepare('SELECT `group_id` FROM `chit_members` WHERE `id` = ? LIMIT 1');
            $stmt->execute([$memberId]);
            return (string)($stmt->fetchColumn() ?: '');
        }

        if (in_array($action, ['settle_auction', 'reverse_payout', 'delete_auction'], true)) {
            $auctionId = trim((string)($b['auction_id'] ?? ''));
            if ($auctionId === '') return '';
            $stmt = Database::pdo()->prepare('SELECT `group_id` FROM `chit_auctions` WHERE `id` = ? LIMIT 1');
            $stmt->execute([$auctionId]);
            return (string)($stmt->fetchColumn() ?: '');
        }

        return trim((string)($b['group_id'] ?? ''));
    }

    /** Agents are confined to their own groups; admins are not. */
    private function assertAgentOwns(string $role, array $claims, string $groupId): void
    {
        if ($role !== 'agent') return;
        // An unresolvable group is left to the service, which reports the
        // missing member or auction far more usefully than a 403 would.
        if ($groupId === '') return;
        if (!ChitScope::agentOwnsGroup((string)($claims['sub'] ?? ''), $groupId)) {
            json_error('That chit group is not assigned to you', 403);
        }
    }
}
