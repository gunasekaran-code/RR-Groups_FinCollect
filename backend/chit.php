<?php
// Entry point → ChitActionController. Chit operations that are transactions
// rather than CRUD: recording a contribution, rebuilding a draw sheet.
//   POST /backend/chit.php?action=collect
//   POST /backend/chit.php?action=generate_schedule
//   GET  /backend/chit.php?action=auctions&group_id=...
//   POST /backend/chit.php?action=record_auction
//   POST /backend/chit.php?action=settle_auction   (admin)
//   POST /backend/chit.php?action=reverse_payout   (admin)
//   POST /backend/chit.php?action=delete_auction   (admin)
require_once __DIR__ . '/bootstrap.php';
send_cors();

(new ChitActionController())->handle();
