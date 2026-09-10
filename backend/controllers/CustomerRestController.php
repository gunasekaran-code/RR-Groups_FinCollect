<?php
// Customers reached through rest.php?table=customers.
//   - Read:   any authenticated user (frontend scopes rows per role).
//   - Update: admin (any field) or agent (GPS location + KYC document images —
//             the "Visit" button pins location, and agents capture documents in
//             the field; they still can't rename or reassign a customer).
//   - Delete: admin only, and it is a SOFT delete — the row is flagged
//             delflag = 1 rather than removed, because loans, collections,
//             funds and chit membership all reference it. Reads filter
//             delflag = 0 here, in one place, so none of the ~14 screens
//             that list customers can forget to exclude deleted ones.
//   Full create/update with a linked login account goes through customers.php
//   (CustomerController), so POST here is admin-only as a safety net.
//   Customers can never write customer records.

class CustomerRestController extends ResourceController
{
    /**
     * The only customer columns an agent may write.
     *
     * An agent works in the field: the Visit button pins a customer's location,
     * and KYC documents are photographed at the door. Everything that
     * identifies the customer — their name, Aadhaar and PAN numbers, and above
     * all which agent they belong to — stays with an admin. The rule was
     * written down at the top of this file long before it was enforced, so an
     * agent could in fact reassign a customer to themselves through rest.php.
     */
    private const AGENT_WRITABLE = [
        'latitude', 'longitude',
        'photo_url', 'aadhaar_front_url', 'aadhaar_back_url', 'pan_url', 'signature_url',
    ];

    public function handle(): void
    {
        $claims = $this->requireAuth();
        ensure_sequential_codes();
        $role   = strtolower(trim($claims['role'] ?? ''));
        if (!$role && !empty($claims['sub'])) {
            $p = Profile::firstRaw(' WHERE id = ?', [$claims['sub']]);
            if ($p) $role = strtolower(trim($p['role'] ?? ''));
        }
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if (in_array($method, ['POST', 'PATCH', 'PUT', 'DELETE'], true)) {
            if ($role === 'customer') {
                json_error('Customers cannot modify customer records', 403);
            }
            if ($method === 'DELETE' && $role !== 'admin') {
                json_error('Only admins can delete customers', 403);
            }
            // Creating a customer with its linked login belongs to
            // customers.php; POST here is the admin-only safety net.
            if ($method === 'POST' && $role !== 'admin') {
                json_error('Only admins can create customers', 403);
            }
        }

        if ($method === 'PATCH' || $method === 'PUT') {
            $b = $this->body();

            if ($role === 'agent') {
                $refused = array_values(array_diff(array_keys($b), self::AGENT_WRITABLE));
                if ($refused) {
                    json_error(
                        'Agents can only update a customer\'s location and KYC documents. Refused: '
                        . implode(', ', $refused),
                        403
                    );
                }
            }

            if (array_key_exists('assigned_agent', $b)) {
                [$where, $binds] = QueryParser::where(Customer::columns());
                if ($where !== '') {
                    $agentId = $b['assigned_agent'] ?: null;
                    $agentName = null;
                    if ($agentId) {
                        $prof = Profile::findPublic($agentId);
                        $agentName = $prof['full_name'] ?? null;
                    }
                    // Sync assigned_agent to all loans belonging to the customer
                    $customers = Customer::select($where, $binds);
                    foreach ($customers as $cust) {
                        if (!empty($cust['id'])) {
                            Loan::updateWhere(['assigned_agent' => $agentId, 'agent_name' => $agentName], ' WHERE customer_id = ?', [$cust['id']]);
                        }
                    }
                }
            }
        }

        // Reads and deletes are handled generically by ResourceController:
        // it filters delflag = 0 for every table that has the column, and
        // turns DELETE into a flag update. Keeping a second copy of that rule
        // here is how the two drift apart.
        parent::handle();
    }
}
