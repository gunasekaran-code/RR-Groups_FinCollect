<?php
// Entry point → AgentPortfolioController. One agent's customers and whether
// each of them has paid — computed on the server, admin only.
//   GET /backend/agents.php?action=portfolio&agent_id=<id>
require_once __DIR__ . '/bootstrap.php';
send_cors();

(new AgentPortfolioController())->handle();
