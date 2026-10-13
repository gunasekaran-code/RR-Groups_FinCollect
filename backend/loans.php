<?php
// Entry point → LoanActionController. Loan operations that are decisions
// rather than edits: quoting an early settlement, and taking it.
//   GET  /backend/loans.php?action=settlement_quote&loan_id=...
//   POST /backend/loans.php?action=settle                          (admin)
require_once __DIR__ . '/bootstrap.php';
send_cors();

(new LoanActionController())->handle();
