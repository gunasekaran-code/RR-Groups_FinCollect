<?php
// Chit groups with role enforcement:
//   - Read:   any authenticated user (customers see the groups they belong to).
//   - Create/Delete: admin only.
//   - Update: admin (any field) or agent (collection fields only — when an agent
//             records a member's monthly contribution the group's running totals
//             and status are updated).
//   Customers can never write chit groups.
//
// This controller also serves ?table=chit_schedules, because a group and its
// draw sheet are edited together and carry the same permissions.

class ChitGroupController extends ResourceController
{
    public function handle(): void
    {
        $claims = $this->requireAuth();
        $role   = strtolower(trim($claims['role'] ?? ''));
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if ($method === 'POST' || $method === 'DELETE') {
            if ($role !== 'admin' && $role !== 'agent') {
                json_error('Only admins or agents can create or delete chit groups', 403);
            }
        } elseif ($method === 'PATCH' || $method === 'PUT') {
            if ($role !== 'admin' && $role !== 'agent') {
                json_error('Not allowed', 403);
            }
        }

        // Who a group belongs to is an admin's decision. Without this an agent
        // could assign any group — including one they cannot currently see —
        // to themselves through rest.php.
        if (($method === 'PATCH' || $method === 'PUT' || $method === 'POST') && $role === 'agent') {
            $b = $this->body();
            $rows = ($b !== [] && array_keys($b) === range(0, count($b) - 1)) ? $b : [$b];
            foreach ($rows as $r) {
                if (is_array($r) && array_key_exists('assigned_agent', $r)) {
                    json_error('Only admins can assign a chit group to an agent', 403);
                }
            }
        }

        // An agent sees the groups assigned to them, and the draw sheets of
        // those groups — not every group in the business.
        if ($method === 'GET') {
            ChitScope::applyRead($this->model::table(), $role, $claims['sub'] ?? null);
        } else {
            $this->stampAgentName();
        }

        parent::handle();
    }

    /**
     * Fill `agent_name` from `assigned_agent`.
     *
     * Done here rather than in the browser so the stored name cannot be
     * whatever the sender typed, and so it is refreshed on every write instead
     * of drifting after the agent is renamed.
     */
    private function stampAgentName(): void
    {
        if ($this->model::table() !== 'chit_groups') return;

        $body = $this->body();
        if ($body === []) return;

        $isList = array_keys($body) === range(0, count($body) - 1);
        $rows   = $isList ? $body : [$body];
        $touched = false;

        foreach ($rows as $i => $row) {
            if (!is_array($row) || !array_key_exists('assigned_agent', $row)) continue;
            $agentId = $row['assigned_agent'] ?: null;
            $name = null;
            if ($agentId) {
                $p = Profile::findPublic((string)$agentId);
                $name = $p['full_name'] ?? null;
            }
            $rows[$i]['assigned_agent'] = $agentId;
            $rows[$i]['agent_name'] = $name;
            $touched = true;
        }

        if ($touched) set_json_body($isList ? $rows : $rows[0]);
    }

    /**
     * A saved group gets its draw sheet, and every member gets a passbook
     * built from it, before the response goes back.
     *
     * Creating the group used to leave the browser to work out the scheme,
     * insert thirty chit_schedules rows and hope none of them failed. The
     * schedule is generated here now (ChitPassbookService::schedulesFor), so a
     * group created from anywhere — this screen, the agent app, an import — has
     * the same sheet, and its members' passbooks exist immediately.
     *
     * Only a group with no sheet is generated for: once draws exist an admin
     * may have overridden dates or amounts on them, and those are not to be
     * silently rewritten. Rebuilding on purpose is chit.php?action=generate_schedule.
     */
    protected function afterWrite(string $method, array $rows): void
    {
        $isGroupWrite = $this->model::table() === 'chit_groups';

        $ids = [];
        foreach ($rows as $row) {
            $id = $row['group_id'] ?? ($isGroupWrite ? ($row['id'] ?? null) : null);
            if ($id) $ids[] = $id;
        }

        $build = $isGroupWrite && $method !== 'DELETE';
        foreach (array_unique($ids) as $groupId) {
            // The sheet is built even when the group has no members yet: the
            // draws belong to the group, and the members inherit them.
            if ($build) ChitPassbookService::schedulesFor((string)$groupId, null, true);
            // A schedule write is a rebuild in progress (delete, then insert),
            // so generating there would race the rows about to arrive.
            ChitPassbookService::syncGroup((string)$groupId, $build);
        }
    }
}
