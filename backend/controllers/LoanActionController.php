<?php
/**
 * Loan operations that are decisions rather than edits.
 *
 *   GET  /backend/loans.php?action=settlement_quote&loan_id=...
 *        → the full breakdown of what it would cost to close the loan today
 *
 *   POST /backend/loans.php?action=settle                          (admin)
 *        { loan_id, amount?, reason?, payment_method?, collection_date?, notes? }
 *
 * Closing a loan early used to mean working the figure out by hand and editing
 * rows until the balance reached zero. The arithmetic is in `LoanSettlement`
 * now and it happens in one request, so the receipt, the schedule and the
 * loan's own totals cannot end up telling three different stories.
 *
 * Who may do what follows the line the funds draw: an agent collects money in,
 * an admin gives money away. A settlement waives the interest a borrower would
 * otherwise have paid, so settling is an admin's decision — but an agent can
 * read the quote, because the question is usually asked at the customer's door.
 */
class LoanActionController extends Controller
{
    public function handle(): void
    {
        $claims = $this->requireAuth();
        $role   = strtolower(trim($claims['role'] ?? ''));
        $action = (string)($_GET['action'] ?? '');
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if ($role !== 'admin' && $role !== 'agent') {
            json_error('Only admins or agents can act on a loan', 403);
        }

        if ($action === 'settlement_quote') {
            if ($method !== 'GET') json_error('Method not allowed', 405);
            $loanId = trim((string)($_GET['loan_id'] ?? ''));
            if ($loanId === '') json_error('Which loan?', 400);
            json_out(LoanSettlement::quote($loanId));
            return;
        }

        if ($action === 'settle') {
            if ($method !== 'POST') json_error('Method not allowed', 405);
            if ($role !== 'admin') {
                json_error('Only an admin can close a loan early', 403);
            }
            json_out(LoanSettlement::settle($this->body(), $claims));
            return;
        }

        json_error("Unknown action: $action", 404);
    }
}
