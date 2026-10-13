<?php
/**
 * Chit-specific helpers on top of AgentScope.
 *
 * A chit group has no agent of its own. It is visible to whoever handles one
 * of its members' customers — a link that already exists, because a customer
 * names their agent when they are created and a chit member names their
 * customer. The read rule lives in AgentScope; this class keeps the same
 * question in the form the chit.php action endpoints need to ask it.
 */
class ChitScope
{
    /** The chit groups holding at least one of this agent's customers. */
    public static function groupIdsForAgent(string $agentId): array
    {
        if ($agentId === '') return [];
        try {
            $stmt = Database::pdo()->prepare(
                'SELECT DISTINCT m.`group_id` FROM `chit_members` m
                   JOIN `customers` c ON c.`id` = m.`customer_id`
                  WHERE c.`assigned_agent` = ? AND m.`delflag` = 0 AND c.`delflag` = 0'
            );
            $stmt->execute([$agentId]);
            return $stmt->fetchAll(PDO::FETCH_COLUMN, 0) ?: [];
        } catch (\Throwable $e) {
            // Failing closed is the safe direction.
            return [];
        }
    }

    /**
     * Apply the agent's scope to a read of $table.
     *
     * Kept as the name the chit controllers call; the rule is AgentScope's.
     */
    public static function applyRead(string $table, string $role, ?string $userId): void
    {
        AgentScope::apply($table, $role, $userId);
    }

    /**
     * True when this agent handles a customer inside the group.
     *
     * The action endpoints ask this before collecting, generating a schedule or
     * touching an auction. It is the same question the read scope answers, so
     * an agent can never act on a group they cannot see.
     */
    public static function agentOwnsGroup(string $agentId, string $groupId): bool
    {
        if ($agentId === '' || $groupId === '') return false;
        try {
            $stmt = Database::pdo()->prepare(
                'SELECT 1 FROM `chit_members` m
                   JOIN `customers` c ON c.`id` = m.`customer_id`
                  WHERE m.`group_id` = ? AND c.`assigned_agent` = ?
                    AND m.`delflag` = 0 AND c.`delflag` = 0 LIMIT 1'
            );
            $stmt->execute([$groupId, $agentId]);
            return (bool)$stmt->fetchColumn();
        } catch (\Throwable $e) {
            return false;
        }
    }
}
