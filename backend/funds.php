<?php
// Entry point → FundActionController. Fund operations that are transactions
// rather than CRUD: recording a deposit, closing a scheme, paying the customer.
//   GET  /backend/funds.php?action=sheet&fund_id=...
//   POST /backend/funds.php?action=collect
//   POST /backend/funds.php?action=close
//   POST /backend/funds.php?action=payout          (admin)
//   POST /backend/funds.php?action=reverse_payout  (admin)
require_once __DIR__ . '/bootstrap.php';
send_cors();

(new FundActionController())->handle();
