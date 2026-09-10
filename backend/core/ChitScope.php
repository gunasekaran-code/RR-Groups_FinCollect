<?php
/**
 * Chit-specific helpers on top of AgentScope.
 *
 * Chit groups were the first module to get an `assigned_agent` and the first
 * to be scoped, so the rule was written here. It turned out to be the same
 * rule loans and funds needed — a record naming its agent, and child tables
 * reached through it — so the rule itself now lives in AgentScope and this
 * class keeps only what is genuinely about chits: the ownership question the
 * chit.php action endpoints have to ask before acting on a group.
 */
class ChitScope
{
    /** Group ids assigned to one agent. */
    public static function groupIdsForAgent(string $agentId): array
    {
        if ($agentId === '') return [];
        try {
            $stmt = Database::pdo()->prepare(
                'SELECT `id` FROM `chit_groups` WHERE `assigned_agent` = ? AND `delflag` = 0'
            );
            $stmt->execute([$agentId]);
            return $stmt->fetchAll(PDO::FETCH_COLUMN, 0) ?: [];
        } catch (\Throwable $e) {
            // Before the column exists, scoping cannot be applied. Failing
            // closed is the safe direction.
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

    /** True when this agent is the one the group is assigned to. */
    public static function agentOwnsGroup(string $agentId, string $groupId): bool
    {
        if ($agentId === '' || $groupId === '') return false;
        try {
            $stmt = Database::pdo()->prepare(
                'SELECT 1 FROM `chit_groups` WHERE `id` = ? AND `assigned_agent` = ? AND `delflag` = 0 LIMIT 1'
            );
            $stmt->execute([$groupId, $agentId]);
            return (bool)$stmt->fetchColumn();
        } catch (\Throwable $e) {
            return false;
        }
    }
}
