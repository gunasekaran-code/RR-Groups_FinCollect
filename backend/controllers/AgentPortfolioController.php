<?php
/**
 * An agent's book of customers — admin only.
 *
 *   GET  /backend/agents.php?action=portfolio&agent_id=<id>[&date=YYYY-MM-DD]
 *     → { agent, as_of, summary, customers: [ … ], unlinked_loans: [ … ] }
 *
 *   POST /backend/agents.php?action=attach_loan
 *     { loan_id, customer_id } → the reattached loan
 *
 * Admin only, and deliberately so: this is every customer an agent handles
 * together with what each still owes and whether they have paid today. Letting
 * an agent open it would show them another agent's book; letting a customer
 * open it would show them their neighbours' debts.
 */
class AgentPortfolioController extends Controller
{
    public function handle(): void
    {
        $this->requireAdmin();

        $action = $_GET['action'] ?? 'portfolio';
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        switch ($action) {
            case 'portfolio':
                if ($method !== 'GET') json_error('Method not allowed', 405);
                $this->portfolio();
                return;

            case 'attach_loan':
                if ($method !== 'POST') json_error('Method not allowed', 405);
                $this->attachLoan();
                return;

            default:
                json_error("Unknown agent action: $action", 404);
        }
    }

    private function portfolio(): void
    {
        $agentId = trim((string)($_GET['agent_id'] ?? ''));
        if ($agentId === '') json_error('Which agent?', 400);

        $date = $_GET['date'] ?? null;
        if (is_string($date) && $date !== '') {
            $ts = strtotime($date);
            if ($ts === false) json_error('That date could not be read', 400);
            $date = date('Y-m-d', $ts);
        } else {
            $date = null;
        }

        // Loan statuses are time-based, so an instalment can fall overdue with
        // nothing having been written. Reconcile before reporting, or the book
        // shows yesterday's picture.
        try {
            Overdue::recompute();
        } catch (\Throwable $e) {
            error_log('AgentPortfolio: overdue recompute warning: ' . $e->getMessage());
        }

        json_out(AgentPortfolio::forAgent($agentId, $date));
    }

    /**
     * Put a loan whose customer went missing back on somebody's book.
     *
     * The automatic repair (relink_orphan_records) only acts where the stored
     * name matches exactly one live customer; two people with the same name are
     * left for a human, and this is that human's way in.
     */
    private function attachLoan(): void
    {
        $body       = $this->body();
        $loanId     = trim((string)($body['loan_id'] ?? ''));
        $customerId = trim((string)($body['customer_id'] ?? ''));
        if ($loanId === '' || $customerId === '') {
            json_error('Both a loan and a customer are needed', 400);
        }

        json_out(AgentPortfolio::attachLoan($loanId, $customerId));
    }
}
