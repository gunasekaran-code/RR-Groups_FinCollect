<?php
// Funds CRUD with role enforcement:
//   - Read:   admin sees every fund; an agent sees only the funds assigned to
//             them (AgentScope); a customer sees only their own.
//   - Create/Delete: admin or agent.
//   - Update: admin (any field) or agent (collections only — collected_amount/status).
//   Customers can never write funds.

class FundController extends ResourceController
{
    public function handle(): void
    {
        $claims = $this->requireAuth();
        $role   = strtolower(trim($claims['role'] ?? ''));
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if ($method === 'POST' || $method === 'DELETE') {
            if ($role !== 'admin' && $role !== 'agent') {
                json_error('Only admins or agents can create or delete funds', 403);
            }
        } elseif ($method === 'PATCH' || $method === 'PUT') {
            if ($role !== 'admin' && $role !== 'agent') {
                json_error('Not allowed', 403);
            }
        }

        // An agent may only ever assign a fund to themselves — the same rule
        // loans have always had. The form hides the dropdown for them, but that
        // is cosmetic; this is what actually stops a fund being handed to
        // somebody else through rest.php.
        if ($role === 'agent' && in_array($method, ['POST', 'PATCH', 'PUT'], true)) {
            $this->forceOwnAgent($method, $claims);
        }

        // Applied to writes as well as reads: without it an agent could PATCH
        // or DELETE, by id, a fund they are not allowed to see.
        if ($method !== 'POST') {
            AgentScope::apply($this->model::table(), $role, $claims['sub'] ?? null);
        }

        parent::handle();
    }

    /**
     * Pin `assigned_agent` to the authenticated agent.
     *
     * On create the agent always owns the fund. On update the fields are only
     * rewritten when the client actually sent them, so the collection sync —
     * which PATCHes collected_amount and status — is not mistaken for a
     * re-assignment attempt.
     */
    private function forceOwnAgent(string $method, array $claims): void
    {
        $agentId = $claims['sub'] ?? null;
        if (!$agentId) return;

        $profile   = Profile::findPublic($agentId);
        $agentName = $profile['full_name'] ?? null;

        $body   = $this->body();
        $isList = $body !== [] && array_keys($body) === range(0, count($body) - 1);
        $rows   = $isList ? $body : [$body];

        $changed = false;
        foreach ($rows as &$row) {
            if (!is_array($row)) continue;
            $touchesAgent = array_key_exists('assigned_agent', $row) || array_key_exists('agent_name', $row);
            if ($method !== 'POST' && !$touchesAgent) continue;

            if (($row['assigned_agent'] ?? null) !== $agentId) {
                $row['assigned_agent'] = $agentId;
                $changed = true;
            }
            if (($row['agent_name'] ?? null) !== $agentName) {
                $row['agent_name'] = $agentName;
                $changed = true;
            }
        }
        unset($row);

        if ($changed) {
            set_json_body($isList ? $rows : $rows[0]);
        }
    }
}
